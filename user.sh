#!/bin/sh
# 账号管理（写 server.json 的 users，改完自动重启面板）
#   sh user.sh add <用户名> [密码]     不给密码就随机生成
#   sh user.sh list
#   sh user.sh del <用户名>
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$DIR/server.json"
CMD="$1"
NAME="$2"
PASS="$3"

[ -f "$CONF" ] || { echo "找不到 $CONF"; exit 1; }

case "$CMD" in
  add)
    [ -n "$NAME" ] || { echo "用法: sh user.sh add <用户名> [密码]"; exit 1; }
    [ -n "$PASS" ] || PASS=$(head -c 9 /dev/urandom | base64 | tr -d '/+=' | head -c 12)
    python3 - "$CONF" "$NAME" "$PASS" <<'PY'
import json, sys
path, name, pw = sys.argv[1:4]
d = json.load(open(path))
users = d.setdefault("users", [])
users = [u for u in users if u.get("user") != name]
users.append({"user": name, "password": pw, "name": name})
d["users"] = users
json.dump(d, open(path, "w"), ensure_ascii=False, indent=1)
print("已添加账号：", name)
print("密码：", pw)
print("探针那边填：账号 %s / 密码 %s" % (name, pw))
PY
    systemctl restart zstat-server 2>/dev/null || true
    ;;
  list)
    python3 - "$CONF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
us = d.get("users") or []
print("共 %d 个账号" % len(us))
for u in us:
    print("  %-12s %s" % (u.get("user"), u.get("password")))
if not us:
    print("（空。用 sh user.sh add <用户名> 添加）")
PY
    ;;
  del)
    [ -n "$NAME" ] || { echo "用法: sh user.sh del <用户名>"; exit 1; }
    python3 - "$CONF" "$NAME" <<'PY'
import json, sys
path, name = sys.argv[1:3]
d = json.load(open(path))
before = len(d.get("users") or [])
d["users"] = [u for u in d.get("users", []) if u.get("user") != name]
json.dump(d, open(path, "w"), ensure_ascii=False, indent=1)
print("删了 %d 个" % (before - len(d["users"])))
PY
    systemctl restart zstat-server 2>/dev/null || true
    ;;
  *)
    echo "用法: sh user.sh add <用户名> [密码] | list | del <用户名>"
    ;;
esac
