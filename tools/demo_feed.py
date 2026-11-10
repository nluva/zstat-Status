#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""演示数据：往面板灌几台假机器，用来看页面效果。

    python3 demo_feed.py <面板IP> <token>

按 Ctrl-C 停。真用的时候别跑它。
"""
import json
import random
import socket
import sys
import time

NODES = [
    ("Aliyun-HK", "Hong Kong", "2026-12-19", 89, 42),
    ("DMIT-LA", "Los Angeles", "2026-05-30", 21, 61),
    ("V.PS-SJ", "San Jose", "2027-04-11", 7, 33),
    ("Smarthost-LA", "Los Angeles", "2026-09-02", 55, 74),
    ("Sentris-SEA", "Seattle", "2027-01-11", 12, 26),
    ("CloudCone-LA", "Los Angeles", "2026-11-21", 4, 88),
]


def main():
    host = sys.argv[1]
    token = sys.argv[2] if len(sys.argv) > 2 else ""
    user = sys.argv[4] if len(sys.argv) > 4 else ""
    password = sys.argv[5] if len(sys.argv) > 5 else ""
    port = int(sys.argv[3]) if len(sys.argv) > 3 else 35601
    state = {n[0]: [n[3], n[4]] for n in NODES}
    up_days = {n[0]: random.randint(3, 200) for n in NODES}
    tick = 0
    while True:
        tick += 1
        for name, loc, exp, cpu, ram in NODES:
            s = state[name]
            s[0] = max(2, min(98, s[0] + random.uniform(-6, 6)))
            s[1] = max(8, min(95, s[1] + random.uniform(-3, 3)))
            offline = name == "CloudCone-LA" and tick % 12 > 8
            mem_total = 2 * 1024 ** 3
            hdd_total = 40 * 1024
            msg = {
                "token": token, "user": user, "password": password, "name": name, "location": loc, "type": exp,
                "region": loc.split("-")[-1],
                "uptime": f"{up_days[name]} 天",
                "uptime_seconds": up_days[name] * 86400,
                "load": round(random.uniform(0, 2.4), 2),
                "cpu": round(s[0], 1),
                "cpu_model": random.choice(["Intel Xeon E5-2678 v3", "AMD EPYC 7K62", "Intel Core i7-8700", "AMD Ryzen 9 5950X"]),
                "cpu_cores": random.choice([2, 4, 8, 12, 16]),
                "online4": not offline, "online6": random.random() > 0.4,
                "network_in": random.randint(10, 900) * 1024 ** 3,
                "network_out": random.randint(10, 900) * 1024 ** 3,
                "network_rx": random.randint(1, 900) * 1024,
                "network_tx": random.randint(1, 600) * 1024,
                "memory_total": mem_total,
                "memory_used": int(mem_total * s[1] / 100),
                "swap_total": 1024 ** 3, "swap_used": 0,
                "hdd_total": hdd_total, "hdd_used": int(hdd_total * random.uniform(8, 60) / 100),
            }
            try:
                sk = socket.create_connection((host, port), timeout=4)
                sk.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode())
                sk.close()
            except OSError as e:
                print("送不出去：", e)
        time.sleep(4)


if __name__ == "__main__":
    main()
