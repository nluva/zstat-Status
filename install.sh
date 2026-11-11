#!/bin/sh
# zstat —— 一个不依赖任何第三方库的探针（面板 + 上报 + 网页）
#
#   bash status.sh          交互选择：面板 / 探针
#   bash status.sh s        装面板（可选 nginx + 证书，绑 80/443）
#   bash status.sh c        装探针（输入名称 / 账户 / 密码）
#
# 单独下载运行时（只有这个脚本），会自动去 GitHub 拉源码包。
set -e

REPO="nluva/zstat-Status"
BRANCH="main"
TARBALL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
MIRROR=""   # 不再用私人镜像；只从 GitHub 拉

PREFIX="${ZSTAT_PREFIX:-/usr/local/ServerStatus}"
# 安全阀：绝不往 / 或 /usr 这种地方动手
case "$PREFIX" in
  ""|"/"|"/usr"|"/etc"|"/var"|"/root"|"/home")
    echo "拒绝执行：PREFIX 指向 $PREFIX，太危险了"; exit 1 ;;
esac
case "$PREFIX" in
  /*) : ;;
  *) echo "拒绝执行：PREFIX 必须是绝对路径（现在是 $PREFIX）"; exit 1 ;;
esac
if [ -n "$ZSTAT_PREFIX" ]; then NGX_CONF="$PREFIX/etc/nginx/conf.d/zstat.conf"; else NGX_CONF="/etc/nginx/conf.d/zstat.conf"; fi
WEBROOT="$PREFIX/web"
[ "$WEBROOT" != "$PREFIX" ] || { echo "拒绝执行：web 目录不能等于安装目录"; exit 1; }
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
ROLE="$1"
ACTION=""
case "$ROLE" in
  s|S|server)    ROLE=server ;;
  c|C|client)    ROLE=client ;;
  u|U|rm|remove|uninstall|del) ROLE=uninstall ;;
  start|stop|restart|status|log|logs) ACTION="$ROLE"; ROLE=manage ;;
  n|node|nodes|account|accounts) ROLE=nodes ;;
  "") ;;
  *) echo "用法: bash status.sh [s|c|u|start|stop|restart|status|log]"; exit 1 ;;
esac

C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_0='\033[0m'
say()  { printf '%s\n' "$*"; }
info() { printf "${C_G}[信息]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[注意]${C_0} %s\n" "$*"; }
err()  { printf "${C_R}[错误]${C_0} %s\n" "$*"; }

check_sys() {
  if [ -f /etc/redhat-release ]; then PM=yum
  elif grep -qiE "debian|ubuntu" /etc/issue 2>/dev/null || grep -qiE "debian|ubuntu" /proc/version 2>/dev/null; then PM=apt
  elif command -v pacman >/dev/null 2>&1; then PM=pacman
  else PM=apt; fi
}
pkg_install() {   # pkg_install 包名...
  for p in "$@"; do
    case "$PM" in
      yum) yum -y install "$p" >/dev/null 2>&1 || return 1 ;;
      pacman) pacman -Sy --noconfirm "$p" >/dev/null 2>&1 || return 1 ;;
      *) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null 2>&1 || return 1 ;;
    esac
  done
}
# 确认框（默认 y）：回车算 y，只有明确 n/no 才算否
# 确认框（默认 N）：回车算 n，只有明确 y/yes 才算同意
confirmn() {
  printf '%s (y/N): ' "$1"
  read -r _ans || true
  case "$_ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

confirm() {
  printf '%s (Y/n): ' "$1"
  read -r _ans || true
  case "$_ans" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
}
ask() { printf '%s' "$1"; read -r "$2" || true; }
check_port() {  # check_port 值 说明
  case "$1" in
    *[!0-9]*|"") say "$2要是 1-65535 的数字"; exit 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { say "$2要在 1-65535 之间"; exit 1; }
}
askdefault() { printf '%s [%s]: ' "$1" "$2"; read -r "$3" || true; [ -n "$(eval echo \$$3)" ] || eval "$3='$2'"; }

command -v python3 >/dev/null || { say "缺 python3，先装：apt-get install -y python3"; exit 1; }
if [ -z "$ZSTAT_PREFIX" ] && [ "$(id -u)" != "0" ]; then
  say "要用 root 跑（装服务、写 /etc 都得 root）：sudo bash $0 ${1:-}"
  exit 1
fi

# ---------- 找到源码 ----------
# 1) 脚本旁边就有源码（压缩包解开后运行）
# 2) 否则从 GitHub 下载
find_src() {
  if [ -f "$SELF_DIR/server.py" ] && [ -d "$SELF_DIR/web" ]; then
    SRC="$SELF_DIR"
    return
  fi
  command -v tar >/dev/null || { say "缺 tar"; exit 1; }
  TMP=$(mktemp -d)
  trap '[ -n "$TMP" ] && rm -rf "$TMP"' EXIT
  for URL in "$MIRROR" "$TARBALL"; do
    [ -n "$URL" ] || continue
    say "下载源码包：$URL"
    if command -v curl >/dev/null; then
      curl -fsSL "$URL" -o "$TMP/src.tar.gz" || { say "  下载失败"; continue; }
    else
      wget -q "$URL" -O "$TMP/src.tar.gz" || { say "  下载失败"; continue; }
    fi
    rm -rf "$TMP"/x && mkdir -p "$TMP/x"
    tar xzf "$TMP/src.tar.gz" -C "$TMP/x" || { say "  解压失败"; continue; }
    SRC=$(ls -d "$TMP"/x/zstat-Status* 2>/dev/null | head -1)
    [ -n "$SRC" ] || SRC=$(find "$TMP/x" -maxdepth 2 -name server.py -printf '%h\n' 2>/dev/null | head -1)
    if [ -n "$SRC" ] && [ -f "$SRC/server.py" ] && [ -d "$SRC/web" ]; then
      return
    fi
    say "  这个包里缺 web/ 目录，换下一个源"
  done
  say "源码拿不到（GitHub 上的包可能不完整）。"
  say "手动办法：把 zstat-Status 整个目录传上来，进目录里跑 bash install.sh s"
  exit 1
}
if [ -z "$ROLE" ]; then
  check_sys
  st_server="未安装"; st_agent="未安装"
  if [ -f /etc/systemd/system/zstat-server.service ]; then
    st_server="已安装"
    systemctl is-active --quiet zstat-server && st_server="${st_server}，运行中" || st_server="${st_server}，已停止"
  fi
  if [ -f /etc/systemd/system/zstat-agent.service ]; then
    st_agent="已安装"
    systemctl is-active --quiet zstat-agent && st_agent="${st_agent}，运行中" || st_agent="${st_agent}，已停止"
  fi
  say ""
  say "zstat 探针面板　（系统：$PM）"
  say "  面板：$st_server"
  say "  探针：$st_agent"
  say ""
  say "要做什么？"
  say "  1) 装面板 server（收所有探针的数据 + 网页）"
  say "  2) 装探针 client（把这台机器上报给面板）"
  say "  3) 卸载"
  say "  4) 启动   5) 停止   6) 重启   7) 看状态"
  say "  8) 节点账号（看列表 / 加 / 删 / 续期 / 调顺序）"
  say "  9) 看面板日志   10) 看探针日志"
  ask "选 1-10: " PICK
  case "$PICK" in
    1) ROLE=server ;;
    2) ROLE=client ;;
    3) ROLE=uninstall ;;
    4) ROLE=manage; ACTION=start ;;
    5) ROLE=manage; ACTION=stop ;;
    6) ROLE=manage; ACTION=restart ;;
    7) ROLE=manage; ACTION=status ;;
    8) ROLE=nodes ;;
    9) ROLE=logs ;;
    10) ROLE=logs2 ;;
    *) say "只认 1-10"; exit 1 ;;
  esac
fi

# find_src 放到真正安装的时候再调（管理/卸载不需要源码）

# ---------- 服务管理 ----------
svc_list() {
  # 输出这台机器上已有的 zstat 服务（末尾 true：没有服务时不要让 set -e 退出）
  [ -f /etc/systemd/system/zstat-server.service ] && echo zstat-server
  [ -f /etc/systemd/system/zstat-agent.service ] && echo zstat-agent
  return 0
}

manage() {
  SVCS=$(svc_list)
  if [ -z "$SVCS" ]; then
    say "这台机器上没装 zstat 服务。先装：bash status.sh s 或 bash status.sh c"
    exit 0
  fi
  case "$ACTION" in
    start|stop|restart)
      for s in $SVCS; do
        systemctl "$ACTION" "$s" >/dev/null 2>&1 || true
        STATE=$(systemctl is-active "$s" 2>/dev/null || true)
        say "$s -> ${STATE:-未知}"
      done
      ;;
    status)
      for s in $SVCS; do
        say "---- $s ----"
        systemctl status "$s" --no-pager -n 5 2>&1 | head -12
      done
      say "网页端口：$(python3 - "$PREFIX/server.json" <<'PY2' 2>/dev/null || echo '?'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("http_port","?"))
PY2
)"
      ;;
    log|logs)
      for s in $SVCS; do
        say "---- $s（最近 40 行）----"
        journalctl -u "$s" -n 40 --no-pager 2>&1 | tail -40
      done
      ;;
  esac
  exit 0
}

mark_installed() {
  # 记录脚本自己装的软件包，卸载时才能"连它们一起删"
  mkdir -p "$PREFIX"
  printf '%s\n' "$1" >> "$PREFIX/.zstat-installed" 2>/dev/null || true
}

install_files() {
  mkdir -p "$PREFIX"
  cp "$SRC/server.py" "$SRC/agent.py" "$SRC/user.sh" "$PREFIX"/
  rm -rf "$WEBROOT"
  cp -r "$SRC/web" "$WEBROOT"
  chmod 755 "$PREFIX" "$WEBROOT"
  chmod -R a+rX "$WEBROOT"        # nginx(www-data) 要能读
  chmod +x "$PREFIX/user.sh"
}

svc() {   # svc 文件 名字
  if [ -n "$ZSTAT_PREFIX" ]; then
    say "（测试模式：跳过 systemctl，文件在 $PREFIX）"
    return
  fi
  sed "s#/opt/zstat#$PREFIX#g" "$SRC/$1" > "/etc/systemd/system/$2.service"
  [ -s "/etc/systemd/system/$2.service" ] || { say "写 systemd 单元失败：$SRC/$1 不存在？"; exit 1; }
  systemctl daemon-reload
  systemctl enable "$2" >/dev/null 2>&1 || true
  # 重装时必须 restart：enable --now 对已经在跑的单元不会重启，
  # 那样新写的配置/新代码都不会生效，看起来像"装了没用"。
  systemctl restart "$2"
}

# ---------------- 面板 ----------------
if [ "$ROLE" = "server" ]; then
  if [ -f /etc/systemd/system/zstat-server.service ]; then
    say "这台机器已经装了面板（zstat-server）。"
    [ -f "$PREFIX/server.json" ] && say "  现有配置：$PREFIX/server.json（账号不会丢）"
    if ! confirm "要覆盖重装吗？"; then
      say "取消。要卸载请跑：bash status.sh u"
      exit 0
    fi
  fi
  find_src
  install_files

  # 这台机器对外是 v4 还是 v6？后面的监听、nginx、证书都跟着它走
  ask "这台机器对外用 IPv4 还是 IPv6？(4/6) [4]: " FAM_ANS
  case "$FAM_ANS" in 6|v6|ipv6|V6) NGFAM=6 ;; *) NGFAM=4 ;; esac
  if [ "$NGFAM" = "6" ]; then DEF_BIND="::1"; else DEF_BIND="127.0.0.1"; fi
  # 选了 v6 但这台机器其实没有 v6 → 立刻退回 v4，别等 nginx 起不来
  if [ "$NGFAM" = "6" ] && ! python3 -c 'import socket; s=socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.bind(("::1", 0)); s.close()' >/dev/null 2>&1; then
    warn "这台机器没有可用的 IPv6 回环地址，改用 IPv4"
    NGFAM=4; DEF_BIND="127.0.0.1"
  fi

  ask "监听方式：unix socket（推荐，不占端口，nginx 直接 proxy_pass 到文件）还是 TCP 端口？(u/t) [u]: " BINDMODE
  case "$BINDMODE" in
    t|T|tcp|TCP)
      askdefault "面板监听端口（只给本机 nginx 用）" "8080" HTTP_PORT
      check_port "$HTTP_PORT" "面板端口"
      askdefault "监听地址（本机用 $DEF_BIND）" "$DEF_BIND" BIND_ADDR ;;
    *)
      HTTP_PORT=""
      BIND_ADDR="unix:$PREFIX/run/http.sock" ;;
  esac
  askdefault "探针上报端口" "35601" TCP_PORT
  check_port "$TCP_PORT" "探针上报端口"

  # 先把「要不要碰 nginx」问清楚，再动手装（跟上游一样问在前面）
  NGX_YES=0
  if confirmn "要我帮你装/配 nginx 吗？（本机已有就只加一个 conf.d/zstat.conf，不动你现有站点；选 N 只告诉你网站目录）"; then
    NGX_YES=1
  fi

  cat > "$PREFIX/server.json" <<JSON
{
  "token": "",
  "users": [],
  "bind": "$BIND_ADDR",
  "tcp_port": $TCP_PORT,
  "http_port": ${HTTP_PORT:-0},
  "web_root": "$WEBROOT",
  "stale_seconds": 30
}
JSON
  chmod 600 "$PREFIX/server.json"
  svc deploy/zstat-server.service zstat-server
  if [ -z "$ZSTAT_PREFIX" ]; then
    sleep 2
    if ! systemctl is-active --quiet zstat-server; then
      say "面板没起来。看错误：journalctl -u zstat-server -n 30"
      exit 1
    fi
  fi
  if [ -n "$HTTP_PORT" ]; then
    say "面板已启动（$BIND_ADDR:$HTTP_PORT，探针端口 $TCP_PORT）"
  else
    say "面板已启动（socket：$PREFIX/run/http.sock，探针端口 $TCP_PORT）"
  fi
  say ""
  if [ "$NGX_YES" = "1" ]; then
    if ! command -v nginx >/dev/null; then
      info "本机没有 nginx，装一个"
      case "$PM" in apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ;; esac
      pkg_install nginx && mark_installed nginx || warn "nginx 装失败"
    fi
    if command -v nginx >/dev/null; then
      ask "域名（可空，空就按端口/IP 访问）: " NDOMAIN
      if [ -n "$HTTP_PORT" ]; then PASSLINE="proxy_pass http://127.0.0.1:$HTTP_PORT;"; else PASSLINE="proxy_pass http://unix:$PREFIX/run/http.sock:;"; fi
      mkdir -p /etc/nginx/conf.d
      {
        echo "server {"
        if [ "$NGFAM" = "6" ]; then
          echo "    listen 80;"
          echo "    listen [::]:80;"
        else
          echo "    listen 80;"
        fi
        [ -n "$NDOMAIN" ] && echo "    server_name $NDOMAIN;"
        echo "    root $WEBROOT;"
        echo "    index index.html;"
        echo ""
        echo "    location /api/ {"
        echo "        $PASSLINE"
        echo "        proxy_set_header Host \$host;"
        echo "    }"
        echo ""
        echo "    location / { try_files \$uri \$uri/ /index.html; }"
        echo "}"
      } > /etc/nginx/conf.d/zstat.conf
      if nginx -t >/dev/null 2>&1; then
        # 重载要真的成功才算配好（nginx 没跑、端口被占都会失败）
        if ! systemctl is-active --quiet nginx; then systemctl start nginx >/dev/null 2>&1 || true; fi
        if systemctl reload nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
          say "nginx 已配好：/etc/nginx/conf.d/zstat.conf${NDOMAIN:+　http://$NDOMAIN（IPv$NGFAM）}"
        else
          warn "nginx 配置写好了，但重载/启动失败（端口被占？）"
          say "看错误：nginx -t；journalctl -u nginx -n 20"
          rm -f /etc/nginx/conf.d/zstat.conf
          say "已把我加的那个 conf 删掉，你原来的 nginx 没动"
        fi
        if [ -n "$NDOMAIN" ]; then
          if ! command -v certbot >/dev/null; then
            pkg_install certbot || true
          fi
          # nginx 插件缺了 certbot --nginx 会直接报错，补一下（各发行版包名不同，失败就算了）
          pkg_install python3-certbot-nginx || pkg_install certbot-nginx || true
          if command -v certbot >/dev/null; then
            ask "证书邮箱（可空，空就不填）: " CMAIL
            CEMAIL_ARGS="--register-unsafely-without-email"
            [ -n "$CMAIL" ] && CEMAIL_ARGS="-m $CMAIL"
            info "开始申请证书：$NDOMAIN"
            if certbot --nginx -d "$NDOMAIN" --agree-tos $CEMAIL_ARGS --redirect -n >/tmp/zstat-cert.log 2>&1; then
              mark_installed certbot
              mark_installed "domain=$NDOMAIN"
              say "HTTPS 好了：https://$NDOMAIN（会自动续期，certbot.timer 负责）"
              systemctl list-timers certbot.timer --no-pager >/dev/null 2>&1 || say "提示：没找到 certbot.timer，续期可能要手动加"
            else
              say "证书没签下来，原因（最后几行）："
              tail -5 /tmp/zstat-cert.log
              say "常见原因：域名没解析到这台机器 / 80 端口没放开"
            fi
          else
            say "没装上 certbot，HTTPS 先跳过；手动：certbot --nginx -d $NDOMAIN"
          fi
        fi
      else
        rm -f /etc/nginx/conf.d/zstat.conf
        say "nginx -t 没过，我把 zstat.conf 删了，你的 nginx 没动："
        nginx -t 2>&1 | tail -3
      fi
    else
      say "没有 nginx，跳过。下面这段自己反代。"
    fi
  else
    say "好，不碰 nginx。"
  fi

  say ""
  say "网站目录：$WEBROOT"
  say "探针端口：$TCP_PORT"
  say ""
  say "下一步：给每台机器建账号"
  say "  sh $PREFIX/user.sh add hk1"
  say "  sh $PREFIX/user.sh list"
fi

# ---------------- 探针 ----------------
if [ "$ROLE" = "client" ]; then
  if [ -f /etc/systemd/system/zstat-agent.service ]; then
    say "这台机器已经装了探针（zstat-agent）。"
    if [ -f "$PREFIX/agent.json" ]; then
      python3 - "$PREFIX/agent.json" <<'PY2' 2>/dev/null || true
import json,sys
d=json.load(open(sys.argv[1]))
host = d.get("server") or d.get("host") or d.get("panel") or "?"
print("  当前节点：%s → %s:%s" % (d.get("name","?"), host, d.get("port","?")))
PY2
    fi
    if ! confirm "要覆盖重装吗？"; then
      say "取消。要卸载请跑：bash status.sh u"
      exit 0
    fi
  fi
  find_src
  install_files

  ask "节点名称（面板上显示的名字，如 HK-1）: " CNAME
  ask "面板地址（域名或 IP）: " CSERVER
  askdefault "上报端口" "35601" TCP_PORT
  check_port "$TCP_PORT" "上报端口"
  ask "账号: " CUSER
  ask "密码: " CPASS
  ask "机房/位置（如 Hong Kong，可空）: " CLOC
  CCYCLE=""; CEXP=""   # 到期日/周期在面板的「节点账号」里管，这里不重复问
  A_SERVER="$CSERVER" A_PORT="$TCP_PORT" A_USER="$CUSER" A_PASS="$CPASS" \
  A_NAME="$CNAME" A_LOC="$CLOC" A_EXP="$CEXP" A_CYC="$CCYCLE" \
  python3 - "$PREFIX/agent.json" <<'PYJ'
import json, os, sys
cfg = {
    "server": os.environ["A_SERVER"],
    "port": int(os.environ["A_PORT"]),
    "user": os.environ["A_USER"],
    "password": os.environ["A_PASS"],
    "name": os.environ["A_NAME"],
    "location": os.environ["A_LOC"],
    "expire": os.environ["A_EXP"],
    "cycle": os.environ["A_CYC"],
    "interval": 5,
}
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=1)
os.replace(tmp, sys.argv[1])
PYJ
  chmod 600 "$PREFIX/agent.json"

  svc deploy/zstat-agent.service zstat-agent
  if [ -z "$ZSTAT_PREFIX" ]; then
    sleep 3
    systemctl is-active zstat-agent >/dev/null && say "探针已启动，正在上报到 $CSERVER" || say "探针没起来，看：journalctl -u zstat-agent -n 30"
  fi
fi

# ---------------- 节点账号 ----------------
node_list() {
  python3 - "$PREFIX/server.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
us = d.get("users") or []
if not us:
    print("（还没有节点账号）")
else:
    print("%-4s %-14s %-14s %-11s %s" % ("序号", "账号", "密码", "到期", "周期"))
    for i, u in enumerate(us, 1):
        print("%-4s %-14s %-14s %-11s %s" % (
            i, u.get("user", ""), u.get("password", ""),
            u.get("expire") or "-",
            "年付" if u.get("cycle") == "year" else ("月付" if u.get("cycle") == "month" else "-")))
PY
}

node_add() {
  ask "新节点账号（英文，如 hk2）: " NNAME
  [ -n "$NNAME" ] || { say "没填，算了"; return; }
  ask "到期日 YYYY-MM-DD（可空，空着就不写到到期时间）: " NEXP
  NCP=""
  if [ -n "$NEXP" ]; then
    case "$NEXP" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) say "日期格式不对（要 2026-12-01 这种），这次先不写到期日"; NEXP="" ;;
    esac
  fi
  if [ -n "$NEXP" ]; then
    ask "月付还是年付？(m/y) [m]: " NCP
    case "$NCP" in y|Y|year|年|年付) NCP=year ;; *) NCP=month ;; esac
  fi
  sh "$PREFIX/user.sh" add "$NNAME" "" "$NCP" "$NEXP" | sed -n '1,4p'
}

node_order() {
  NAMES=$(python3 - "$PREFIX/server.json" <<'PYO'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit
order = [str(x) for x in (d.get("order") or [])]
users = [str(u.get("user")) for u in (d.get("users") or []) if u.get("user")]
rank = {k: i for i, k in enumerate(order)}
users.sort(key=lambda u: (rank.get(u, len(rank)), u))
print(" ".join(users))
PYO
)
  [ -n "$NAMES" ] || { say "还没有节点账号"; return; }
  say ""
  say "当前顺序："
  i=0
  for n in $NAMES; do
    i=$((i+1))
    NINFO=$(python3 - "$PREFIX/server.json" "$n" <<'PYN'
import json, sys
d = json.load(open(sys.argv[1]))
for u in d.get("users") or []:
    if str(u.get("user")) == sys.argv[2]:
        print("%s  %s" % (u.get("name") or "", u.get("expire") or "-"))
        break
PYN
)
    say "  $i) $n    $NINFO"
  done
  ask "新的顺序（填序号，空格分隔，如 3 1 2；回车不改）: " NEWORD
  [ -n "$NEWORD" ] || { say "没改"; return; }
  python3 - "$PREFIX/server.json" "$NEWORD" "$NAMES" <<'PYS'
import json, os, sys
path, spec, names = sys.argv[1], sys.argv[2], sys.argv[3].split()
try:
    idx = [int(x) - 1 for x in spec.split()]
except ValueError:
    print("序号要填数字"); raise SystemExit(1)
order = []
for i in idx:
    if 0 <= i < len(names) and names[i] not in order:
        order.append(names[i])
for n in names:            # 没提到的保持在后
    if n not in order:
        order.append(n)
d = json.load(open(path))
d["order"] = order
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=1)
os.replace(tmp, path)
print("新顺序：" + " → ".join(order))
PYS
}

node_del() {
  ask "要删哪个序号: " NIDX
  NAME=$(python3 - "$PREFIX/server.json" "$NIDX" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
us = d.get("users") or []
try:
    i = int(sys.argv[2]) - 1
    print(us[i]["user"])
except Exception:
    print("")
PY2
)
  [ -n "$NAME" ] || { say "序号不对"; return; }
  if confirm "确定删除账号 $NAME 吗（那台探针会连不上）"; then
    sh "$PREFIX/user.sh" del "$NAME" >/dev/null 2>&1
    say "已删除 $NAME"
  fi
}

node_renew() {
  ask "要续期哪个序号: " NIDX
  NAME=$(python3 - "$PREFIX/server.json" "$NIDX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
us = d.get("users") or []
try:
    print(us[int(sys.argv[2]) - 1]["user"])
except Exception:
    print("")
PY
)
  [ -n "$NAME" ] || { say "序号不对"; return; }
  ask "月付还是年付？(m/y，回车沿用原来的): " CYC
  sh "$PREFIX/user.sh" renew "$NAME" "$CYC" | tail -2
}

nodes() {
  if [ ! -f "$PREFIX/server.json" ]; then
    say "这台机器上没装面板，没有节点账号可管。"
    return
  fi
  while :; do
    say ""
    say "---- 节点账号 ----"
    node_list
    say ""
    ask "a 添加 / d 删除 / r 续期 / o 调整顺序 / 回车返回: " NACT
    case "$NACT" in
      a|A) node_add ;;
      d|D) node_del ;;
      r|R) node_renew ;;
      o|O|order|顺序|排序) node_order ;;
      *) return ;;
    esac
  done
}

# ---------------- manage ----------------
if [ "$ROLE" = "manage" ]; then
  manage
fi

if [ "$ROLE" = "nodes" ]; then
  nodes
fi

if [ "$ROLE" = "logs" ] || [ "$ROLE" = "logs2" ]; then
  unit=zstat-server; [ "$ROLE" = "logs2" ] && unit=zstat-agent
  say "---- $unit 最近 50 行（Ctrl-C 退出跟踪）----"
  journalctl -u "$unit" -n 50 --no-pager 2>/dev/null || tail -n 50 /var/log/syslog 2>/dev/null || say "没有日志可看"
fi

# ---------------- uninstall ----------------
if [ "$ROLE" = "uninstall" ]; then
  HAVE_SERVER=0; HAVE_AGENT=0
  # 有单元文件、或者有对应配置文件，都算装过（防止有人手动删了 unit 就卸不掉）
  { [ -f /etc/systemd/system/zstat-server.service ] || [ -f "$PREFIX/server.json" ]; } && HAVE_SERVER=1 || true
  { [ -f /etc/systemd/system/zstat-agent.service ] || [ -f "$PREFIX/agent.json" ]; } && HAVE_AGENT=1 || true
  if [ "$HAVE_SERVER" = 0 ] && [ "$HAVE_AGENT" = 0 ] && [ ! -d "$PREFIX" ]; then
    say "这台机器上没找到 zstat，应该没装过。"
    exit 0
  fi

  ask "卸哪个？面板填 1，探针填 2，两个都卸填 3: " WHICH
  case "$WHICH" in 1|2|3) ;; *) say "只认 1、2、3"; exit 1 ;; esac

  # 只装了其中一个却选了另一个：别让它顺手把目录删了
  if [ "$WHICH" = "1" ] && [ "$HAVE_SERVER" = 0 ]; then
    say "这台机器上没装面板。"
    [ "$HAVE_AGENT" = 1 ] && say "（只装了探针，要卸载探针请选 2）"
    exit 0
  fi
  if [ "$WHICH" = "2" ] && [ "$HAVE_AGENT" = 0 ]; then
    say "这台机器上没装探针。"
    [ "$HAVE_SERVER" = 1 ] && say "（只装了面板，要卸载面板请选 1）"
    exit 0
  fi

  # 1) 停服务、删单元
  if [ "$WHICH" = "1" ] || [ "$WHICH" = "3" ]; then
    if [ "$HAVE_SERVER" = 1 ]; then
      systemctl disable --now zstat-server >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/zstat-server.service
      say "面板服务已停"
    fi
  fi
  if [ "$WHICH" = "2" ] || [ "$WHICH" = "3" ]; then
    if [ "$HAVE_AGENT" = 1 ]; then
      systemctl disable --now zstat-agent >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/zstat-agent.service
      say "探针服务已停"
    fi
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true

  # 2) nginx 站点 / 证书 / 目录：卸面板就一起清，不再多问
  if [ "$WHICH" = "1" ] || [ "$WHICH" = "3" ]; then
    if [ -f "$NGX_CONF" ] || [ -f /etc/nginx/sites-available/zstat ]; then
      rm -f "$NGX_CONF" /etc/nginx/sites-enabled/zstat /etc/nginx/sites-available/zstat
      if command -v nginx >/dev/null; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
      fi
      say "nginx 里 zstat 的站点配置已删"
    fi
    for d in $(grep '^domain=' "$PREFIX/.zstat-installed" 2>/dev/null | sed 's/^domain=//'); do
      if command -v certbot >/dev/null; then
        certbot delete --cert-name "$d" -n >/dev/null 2>&1 && say "证书 $d 已删" || say "证书 $d 没删掉"
      fi
    done
  fi

  # 3) 软件：只问这一句。卸探针时不碰这些——探针跟 nginx/certbot 没关系
  # 只有「这次真的卸了面板」才问软件；只卸探针（或选3但本来就只有探针）都不问
  if [ "$WHICH" = "2" ] || { [ "$WHICH" = "3" ] && [ "$HAVE_SERVER" = 0 ]; }; then
    PKGS=""
  else
  PKGS=""
  if [ -f "$PREFIX/.zstat-installed" ]; then
    PKGS=$(grep -v '^domain=' "$PREFIX/.zstat-installed" | sort -u | tr '\n' ' ')
  fi
  if [ -n "$PKGS" ]; then
    say ""
    say "这个脚本还装过：$PKGS"
    if confirm "连它们一起卸载吗？"; then
      for p in $PKGS; do
        if [ -n "$ZSTAT_PREFIX" ]; then
          say "（测试模式：不真的卸载 $p）"
        else
          case "$PM" in
            yum) yum -y remove "$p" >/dev/null 2>&1 || say "$p 卸载失败" ;;
            pacman) pacman -R --noconfirm "$p" >/dev/null 2>&1 || say "$p 卸载失败" ;;
            *) DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p" >/dev/null 2>&1 || say "$p 卸载失败" ;;
          esac
        fi
      done
      [ -z "$ZSTAT_PREFIX" ] && { apt-get autoremove -y >/dev/null 2>&1 || true; }
      say "软件已卸载"
    else
      say "软件保留（nginx / certbot 没动）"
    fi
  fi
  fi

  # 4) 程序目录：只卸面板时删；机器上还有别的角色就留着
  if [ "$WHICH" = "2" ]; then
    # 只卸探针：删掉探针配置，别的文件一个都不动
    rm -f "$PREFIX/agent.json"
    if [ -d "$PREFIX" ] && [ -n "$(ls -A "$PREFIX" 2>/dev/null)" ]; then
      say "探针已卸载（只删了 agent.json，$PREFIX 里别的文件没动）"
    else
      rm -rf "$PREFIX"
      say "已删除 $PREFIX"
    fi
  elif [ -f /etc/systemd/system/zstat-agent.service ]; then
    say "面板已卸载（$PREFIX 里还有探针在用的文件，没删）"
  elif [ -d "$PREFIX" ]; then
    rm -rf "$PREFIX"
    say "已删除 $PREFIX"
  fi
  say "卸载完成。"
fi
