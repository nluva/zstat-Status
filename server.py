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


def load_conf():
    cfg = {"token": "", "users": [], "tcp_port": 35601, "http_port": 8080,
           "bind": "127.0.0.1", "web_root": os.path.join(BASE, "web"),
           "stale_seconds": 30}
    if os.path.exists(CONF):
        with open(CONF, encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


CONF_DATA = load_conf()
SERVERS = {}            # name -> 最新一条上报（dict）
LOCK = threading.Lock()
LAST_WRITE = [0.0]


def save_stats():
    """把内存里的状态落盘（原子替换，避免前端读到半截文件）。"""
    with LOCK:
        data = {"servers": list(SERVERS.values()), "updated": int(__import__("time").time())}
    tmp = STATS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, STATS)


def auth_ok(msg):
    """两种认证：配了 users 就按「用户名+密码」，否则用共享 token。"""
    users = CONF_DATA.get("users") or []
    if users:
        for u in users:
            if msg.get("user") == u.get("user") and msg.get("password") == u.get("password"):
                msg.setdefault("name", u.get("name") or msg.get("user"))
                return True
        return False
    tok = CONF_DATA.get("token") or ""
    return bool(tok) and msg.get("token") == tok


def merge(old, new):
    """新上报整体覆盖旧值；速率由 agent 自己按自己的采样间隔算好，这里不重算。"""
    new["_ts"] = time.time()
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
            payload = {k: v for k, v in msg.items() if k not in ("token", "user", "password")}
            with LOCK:
                SERVERS[name] = merge(SERVERS.get(name), payload)
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


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=CONF_DATA["web_root"], **kw)

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/api/servers", "/api/servers/"):
            now = time.time()
            stale = float(CONF_DATA.get("stale_seconds", 30))
            with LOCK:
                snap = []
                for s in SERVERS.values():
                    item = {k: v for k, v in s.items() if not k.startswith("_")}
                    if "online4" in s:
                        item["online4"] = bool(s["online4"])
                    if "online6" in s:
                        item["online6"] = bool(s["online6"])
                    item["age"] = int(now - s.get("_ts", 0))
                    # 超过 stale 秒没上报 → 判定离线，别让网页一直显示运行中
                    if item["age"] > stale:
                        item["online4"] = False
                        item["online6"] = False
                        item["stale"] = True
                    else:
                        item["stale"] = False
                    snap.append(item)
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


def start_http():
    srv = ThreadingHTTPServer((CONF_DATA.get("bind", "0.0.0.0"), CONF_DATA["http_port"]), Handler)
    srv.serve_forever()


async def main():
    wr = CONF_DATA.get("web_root")
    if wr and not os.path.isdir(wr):
        print(f"警告：web 目录不存在：{wr}（网页会 404）")
    threading.Thread(target=start_http, daemon=True).start()
    srv = await asyncio.start_server(handle, "0.0.0.0", CONF_DATA["tcp_port"])
    print(f"zstat server: tcp {CONF_DATA['tcp_port']} / http {CONF_DATA['http_port']}")
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
