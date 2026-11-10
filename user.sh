#!/bin/sh
# 账号管理（写 server.json 的 users，改完自动重启面板）
#   sh user.sh add <用户名> [密码] [周期] [到期日]   周期 m/y，到期日 YYYY-MM-DD
#   sh user.sh renew <用户名> [m|y]                 续期：月付 +30 天、年付 +365 天（都退一天）
#   sh user.sh list
#   sh user.sh del <用户名>
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$DIR/server.json"
CMD="$1"
NAME="$2"
PASS="$3"
CYCLE="$4"
EXPIRE="$5"

[ -f "$CONF" ] || { echo "找不到 $CONF"; exit 1; }

case "$CMD" in
  add)
    [ -n "$NAME" ] || { echo "用法: sh user.sh add <用户名> [密码]"; exit 1; }
    [ -n "$PASS" ] || PASS=$(head -c 9 /dev/urandom | base64 | tr -d '/+=' | head -c 12)
    python3 - "$CONF" "$NAME" "$PASS" "$CYCLE" "$EXPIRE" <<'PY'
import json, sys
path, name, pw = sys.argv[1:4]
cycle = (sys.argv[4] if len(sys.argv) > 4 else "") or ""
expire = (sys.argv[5] if len(sys.argv) > 5 else "") or ""
d = json.load(open(path))
users = d.setdefault("users", [])
old = [u for u in users if u.get("user") == name]
users = [u for u in users if u.get("user") != name]
e = {"user": name, "password": pw, "name": name}
if old:
    e["expire"] = old[0].get("expire", "")
    e["cycle"] = old[0].get("cycle", "")
if expire.strip():
    e["expire"] = expire.strip()
if cycle.strip():
    e["cycle"] = "year" if cycle.strip().lower().startswith("y") else "month"
users.append(e)
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
for i, u in enumerate(us, 1):
    print("  %-2d %-12s %-14s %-11s %s" % (i, u.get("user"), u.get("password"),
          u.get("expire") or "-", "年付" if u.get("cycle") == "year" else ("月付" if u.get("cycle") == "month" else "")))
if not us:
    print("（空。用 sh user.sh add <用户名> 添加）")
PY
    ;;
  renew)
    [ -n "$NAME" ] || { echo "用法: sh user.sh renew <用户名> [m|y]"; exit 1; }
    python3 - "$CONF" "$NAME" "$PASS" <<'PY'
import json, sys, calendar, datetime
path, name, cycle = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
d = json.load(open(path))
users = d.get("users") or []
hit = [u for u in users if u.get("user") == name]
if not hit:
    print("没有这个账号：", name); sys.exit(1)
u = hit[0]
cyc = (cycle or u.get("cycle") or "month").strip().lower()
cyc = "year" if cyc.startswith("y") else "month"
base = u.get("expire") or ""
try:
    st = datetime.date.fromisoformat(base)
except Exception:
    st = datetime.date.today()

# 规则：同一天的下一个月/下一年，再退一天
# 例：11-11 月付 → 12-10；再续 → 1-9；年付 11-11 → 次年 11-10
if cyc == "year":
    y = st.year + 1
    day = min(st.day, calendar.monthrange(y, st.month)[1])
    nxt = datetime.date(y, st.month, day) - datetime.timedelta(days=1)
else:
    m = st.month + 1
    y = st.year + (1 if m > 12 else 0)
    m = 1 if m > 12 else m
    day = min(st.day, calendar.monthrange(y, m)[1])
    nxt = datetime.date(y, m, day) - datetime.timedelta(days=1)

u["expire"] = nxt.isoformat()
u["cycle"] = cyc
json.dump(d, open(path, "w"), ensure_ascii=False, indent=1)
print("已续期 %s：%s → %s（%s）" % (name, base or "今天起", u["expire"], "年付" if cyc == "year" else "月付"))
PY
    systemctl restart zstat-server 2>/dev/null || true
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
