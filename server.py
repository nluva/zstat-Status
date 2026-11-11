#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""zstat 服务端：收探针上报 + 供网页读数据。

一个进程干三件事：
  1. TCP 监听（默认 35601），每台被控机连上来，发一行 JSON，就更新它自己的状态；
  2. 把最新状态写成 stats.json（原子写），断电/重启不丢；
  3. HTTP（默认 8080）对外：/api/servers 给前端，其余当静态文件（web/ 目录）。

只用 Python 3 标准库，不装任何东西。
"""
import asyncio
import json
import socket
import time
import os
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(BASE, "server.json")
RUN = os.path.join(BASE, "run")
os.makedirs(RUN, exist_ok=True)
STATS = os.path.join(RUN, "stats.json")
WEBSTATS = os.path.join(BASE, "web", "stats.json")


def load_conf():
    cfg = {"token": "", "users": [], "tcp_port": 35601, "http_port": 8080,
           "bind": "127.0.0.1", "web_root": os.path.join(BASE, "web"),
           "stale_seconds": 30}
    if os.path.exists(CONF):
        with open(CONF, encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


CONF_DATA = load_conf()
CONF_MTIME = [os.path.getmtime(CONF) if os.path.exists(CONF) else 0]


def refresh_conf():
    """server.json 变了就重新读，不用重启服务（改账号后立即生效）。"""
    try:
        m = os.path.getmtime(CONF)
    except OSError:
        return
    if m == CONF_MTIME[0]:
        return
    try:
        fresh = load_conf()
    except Exception:
        return          # 文件正在被写（半截 JSON），下次再试
    CONF_DATA.update(fresh)
    CONF_MTIME[0] = m
SERVERS = {}            # name -> 最新一条上报（dict）
LOCK = threading.Lock()
LAST_WRITE = [0.0]


def snapshot():
    """给前端用的快照：算好 age / stale，别让静态文件版本显示成永远在线。"""
    now = time.time()
    stale = float(CONF_DATA.get("stale_seconds", 30))
    out = []
    with LOCK:
        for s in SERVERS.values():
            item = {k: v for k, v in s.items() if not k.startswith("_")}
            item["user"] = s.get("_user", item.get("user", ""))
            if "online4" in s:
                item["online4"] = bool(s["online4"])
            if "online6" in s:
                item["online6"] = bool(s["online6"])
            item["age"] = int(now - s.get("_ts", 0))
            if item["age"] > stale:
                item["online4"] = False
                item["online6"] = False
                item["stale"] = True
            else:
                item["stale"] = False
            out.append(item)

    order = [str(x).lower() for x in (CONF_DATA.get("order") or [])]
    if order:
        rank = {k: i for i, k in enumerate(order)}
        out.sort(key=lambda it: (rank.get(str(it.get("user") or "").lower(), len(rank)),
                                 str(it.get("name") or "")))
    return out


def save_stats():
    """把内存里的状态落盘（原子替换，避免前端读到半截文件）。"""
    data = {"servers": snapshot(), "updated": int(time.time())}
    for path in (STATS, WEBSTATS):
        try:
            tmp = "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, path)
        except OSError:
            pass


def auth_ok(msg):
    """两种认证：配了 users 就按「用户名+密码」，否则用共享 token。"""
    refresh_conf()
    users = CONF_DATA.get("users") or []
    if users:
        for u in users:
            if msg.get("user") == u.get("user") and msg.get("password") == u.get("password"):
                msg.setdefault("name", u.get("name") or msg.get("user"))
                return True
        return False
    tok = CONF_DATA.get("token") or ""
    return bool(tok) and msg.get("token") == tok


def apply_account(new):
    """账号里配了到期日/周期就以面板为准（这样在面板里续期才不会被探针覆盖）。"""
    refresh_conf()
    me = str(new.get("user") or "").lower()
    for u in CONF_DATA.get("users") or []:
        if str(u.get("user") or "").lower() == me or (u.get("name") and u.get("name") == new.get("name")):
            if u.get("expire"):
                new["type"] = u["expire"]
            if u.get("cycle"):
                new["cycle"] = u["cycle"]
            break
    return new


def merge(old, new):
    """新上报整体覆盖旧值；速率由 agent 自己按自己的采样间隔算好，这里不重算。"""
    new["_ts"] = time.time()
    apply_account(new)
    return new


async def handle(reader, writer):
    peer = writer.get_extra_info("peername")
    try:
        while True:
            try:
                line = await asyncio.wait_for(reader.readline(), timeout=120)
            except asyncio.TimeoutError:
                break
            if not line:
                break
            if len(line) > 65536:
                break
            try:
                msg = json.loads(line.decode("utf-8"))
            except Exception:
                continue
            if not auth_ok(msg):
                writer.write(b'{"ok":false,"error":"bad credential"}\n')
                await writer.drain()
                continue
            name = str(msg.get("name") or "").strip()
            if not name:
                continue
            # 用账号当 key：两台机器万一起了同名，也不会互相覆盖
            key = str(msg.get("user") or "").strip().lower() or name
            payload = {k: v for k, v in msg.items() if k not in ("token", "password")}
            payload["user"] = key      # 要留着，apply_account 靠它认人
            with LOCK:
                SERVERS[key] = merge(SERVERS.get(key), payload)
                SERVERS[key]["_user"] = key    # 排序用，key 就是账号
                cutoff = time.time() - 7 * 86400
                for k in [k for k, v in SERVERS.items() if v.get("_ts", 0) < cutoff]:
                    SERVERS.pop(k, None)
            now = time.time()
            if now - LAST_WRITE[0] >= 2.0:
                LAST_WRITE[0] = now
                save_stats()
            writer.write(b'{"ok":true}\n')
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def stats_writer():
    """每 5 秒写一次 stats.json：没有新上报时 age 也要继续涨，不然静态页面永远显示在线。"""
    while True:
        time.sleep(5)
        try:
            if SERVERS:
                save_stats()
        except Exception:
            pass


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=CONF_DATA["web_root"], **kw)

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/api/servers", "/api/servers/"):
            snap = snapshot()
            body = json.dumps(snap, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if path in ("/api/stats.json",):
            if os.path.exists(STATS):
                with open(STATS, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_error(404)
            return
        return super().do_GET()


class ThreadingHTTPServer6(ThreadingHTTPServer):
    """IPv6 版：bind 里带冒号（如 ::1 或 ::）时用这个。"""
    address_family = socket.AF_INET6


class UnixHTTPServer(ThreadingHTTPServer):
    """监听 unix socket：不用占端口，nginx 直接 proxy_pass 到 socket 文件。"""
    address_family = socket.AF_UNIX

    def server_bind(self):
        try:
            os.unlink(self.server_address)
        except OSError:
            pass
        self.socket.bind(self.server_address)
        try:
            os.chmod(self.server_address, 0o666)
        except OSError:
            pass
        self.server_name = str(self.server_address)
        self.server_port = 0


def start_http():
  try:
    bind = str(CONF_DATA.get("bind", "0.0.0.0"))
    if bind.startswith("unix:"):
        path = bind[5:]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        srv = UnixHTTPServer(path, Handler)
    else:
        cls = ThreadingHTTPServer6 if ":" in bind else ThreadingHTTPServer
        srv = cls((bind, CONF_DATA["http_port"]), Handler)
    srv.serve_forever()
  except Exception as e:
    print(f"HTTP 起不来（{CONF_DATA.get('bind')}）：{e}", flush=True)


async def main():
    wr = CONF_DATA.get("web_root")
    if wr and not os.path.isdir(wr):
        print(f"警告：web 目录不存在：{wr}（网页会 404）")
    threading.Thread(target=start_http, daemon=True).start()
    threading.Thread(target=stats_writer, daemon=True).start()
    port = CONF_DATA["tcp_port"]
    servers = []
    v4_ok = v6_ok = False
    # v4
    try:
        servers.append(await asyncio.start_server(handle, "0.0.0.0", port))
        v4_ok = True
    except OSError as e:
        print(f"v4 监听失败：{e}")
    # v6（单独一个 socket，V6ONLY=1，避免和 v4 抢同一个端口）
    try:
        s6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s6.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s6.bind(("::", port))
        s6.listen(128)
        servers.append(await asyncio.start_server(handle, sock=s6))
        v6_ok = True
    except OSError as e:
        print(f"v6 监听跳过：{e}")
    if not servers:
        print("端口一个都没监听上，退出")
        return
    print(f"zstat server: tcp {port}（v4 {'✓' if v4_ok else '✗'} / v6 {'✓' if v6_ok else '✗'}）http {CONF_DATA['http_port'] or 'unix'}")
    await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    asyncio.run(main())
