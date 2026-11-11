#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""zstat 探针：采集本机状态，定时上报给面板。

只用 /proc 和 os.statvfs，不依赖 psutil。
配置 agent.json：
  {"server":"面板域名或IP","port":35601,"user":"hk1","password":"***",
   "name":"HK-1","location":"Hong Kong","expire":"2026-05-30"}
"""
import json
import os
import socket
import time

BASE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(BASE, "agent.json")


def load_conf():
    if not os.path.exists(CONF):
        raise SystemExit(f"缺少配置文件：{CONF}（先跑 install.sh client，或手写一份）")
    with open(CONF, encoding="utf-8") as f:
        cfg = json.load(f)
    for k in ("server",):
        if not cfg.get(k):
            raise SystemExit(f"agent.json 里缺 {k}")
    if not cfg.get("user") and not cfg.get("token"):
        raise SystemExit("agent.json 里既没有 user/password 也没有 token")
    return cfg


def read_cpu():
    with open("/proc/stat") as f:
        parts = f.readline().split()[1:]
    nums = [int(x) for x in parts]
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
    total = sum(nums)
    return total, idle


def read_mem():
    d = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            d[k] = int(v.split()[0])          # kB
    total = d.get("MemTotal", 0)
    avail = d.get("MemAvailable", d.get("MemFree", 0))
    swap_total = d.get("SwapTotal", 0)
    swap_free = d.get("SwapFree", 0)
    return {
        "memory_total": total * 1024,
        "memory_used": (total - avail) * 1024,
        "swap_total": swap_total * 1024,
        "swap_used": (swap_total - swap_free) * 1024,
    }


def read_net():
    rx = tx = 0
    with open("/proc/net/dev") as f:
        for line in f.readlines()[2:]:
            name, data = line.split(":", 1)
            if name.strip() == "lo":
                continue
            cols = data.split()
            rx += int(cols[0])
            tx += int(cols[8])
    return rx, tx


DISK_FS = {"ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "vfat", "ntfs", "fuseblk"}


def read_disks():
    """所有真实块设备的挂载点（数据盘也要算进来），按容量从大到小。"""
    out, seen = [], set()
    try:
        with open("/proc/mounts") as f:
            lines = f.readlines()
    except OSError:
        lines = []
    for ln in lines:
        parts = ln.split()
        if len(parts) < 3:
            continue
        dev, mnt, fs = parts[0], parts[1], parts[2]
        if fs not in DISK_FS or not dev.startswith("/dev/"):
            continue
        if dev in seen:
            continue
        try:
            st = os.statvfs(mnt)
        except OSError:
            continue
        total = st.f_blocks * st.f_frsize
        if total < 256 * 1024 * 1024 or mnt.startswith("/boot"):  # 忽略 efi/boot 这类小分区
            continue
        free = st.f_bavail * st.f_frsize
        seen.add(dev)
        out.append({
            "mnt": mnt,
            "total": total // 1024 // 1024,
            "used": (total - free) // 1024 // 1024,
        })
    out.sort(key=lambda d: -d["total"])
    return out


def read_disk(path="/"):
    st = os.statvfs(path)
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    return {"hdd_total": total // 1024 // 1024, "hdd_used": (total - free) // 1024 // 1024}


def read_uptime():
    with open("/proc/uptime") as f:
        sec = float(f.read().split()[0])
    d, rem = divmod(int(sec), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    return sec, (f"{d} 天 {h} 小时" if d else f"{h} 小时 {m} 分")


def read_cpuinfo():
    """CPU 型号 + 逻辑核心数。"""
    model, cores = "", 0
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("processor"):
                    cores += 1
                elif line.startswith("model name") and not model:
                    model = line.split(":", 1)[1].strip()
    except OSError:
        pass
    if not cores:
        cores = os.cpu_count() or 0
    return model, cores


def read_load():
    with open("/proc/loadavg") as f:
        return float(f.read().split()[0])


def has_ipv4():
    """有默认路由就算有 v4，不往外发包。"""
    try:
        with open("/proc/net/route") as f:
            for line in f.readlines()[1:]:
                cols = line.split()
                if len(cols) > 3 and cols[1] == "00000000" and int(cols[3], 16) & 2:
                    return True
    except OSError:
        pass
    return False


def has_ipv6():
    """v6 默认路由存在且不是纯 loopback。"""
    try:
        with open("/proc/net/ipv6_route") as f:
            for line in f:
                cols = line.split()
                if len(cols) > 9 and cols[0] == "0" * 32 and cols[1] == "00" and cols[9] != "lo":
                    return True
    except OSError:
        pass
    return False


def main():
    cfg = load_conf()
    interval = float(cfg.get("interval", 5) or 5)
    if interval < 1:
        interval = 1
    prev_total, prev_idle = read_cpu()
    prev_rx, prev_tx = read_net()
    prev_t = time.time()
    model, cores = read_cpuinfo()      # 型号和核心数不会变，只读一次

    while True:
        time.sleep(interval)
        total, idle = read_cpu()
        dt = max(1e-6, time.time() - prev_t)
        cpu = 100.0 * (1 - (idle - prev_idle) / max(1, total - prev_total))
        prev_total, prev_idle, prev_t = total, idle, time.time()

        rx, tx = read_net()
        up_sec, up_txt = read_uptime()

        msg = {
            "user": cfg.get("user", ""),
            "password": cfg.get("password", ""),
            "token": cfg.get("token", ""),
            "name": cfg.get("name", socket.gethostname()),
            "location": cfg.get("location", ""),
            "region": cfg.get("region", ""),
            "type": cfg.get("expire", ""),
            "cycle": cfg.get("cycle", ""),
            "uptime": up_txt,
            "uptime_seconds": int(up_sec),
            "load": read_load(),
            "cpu": round(cpu, 1),
            "online4": has_ipv4(),
            "online6": has_ipv6(),
            "network_in": rx,
            "network_out": tx,
            "network_rx": max(0, int((rx - prev_rx) / dt)),
            "network_tx": max(0, int((tx - prev_tx) / dt)),
            "net_interval": int(dt),
        }
        prev_rx, prev_tx = rx, tx
        msg["cpu_model"] = model
        msg["cpu_cores"] = cores
        msg.update(read_mem())
        msg.update(read_disk())
        try:
            msg["disks"] = read_disks()     # 每块真实磁盘（数据盘也算）
        except Exception:
            msg["disks"] = []
        try:
            sock = socket.create_connection((cfg["server"], int(cfg.get("port", 35601))), timeout=5)
            sock.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode())
            sock.settimeout(3)
            reply = sock.recv(256)
            sock.close()
            try:
                if json.loads(reply.decode()).get("ok") is False:
                    print("认证失败：账号或密码不对（面板那边加一次账号再填）", flush=True)
                    time.sleep(min(60, interval * 6))
            except Exception:
                pass
        except OSError as e:
            print("上报失败：", e, flush=True)
            time.sleep(min(60, interval * 4))


if __name__ == "__main__":
    main()
