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
MIRROR="https://822229.xyz/dl/zstat-Status.tar.gz"

PREFIX="${ZSTAT_PREFIX:-/usr/local/ServerStatus}"
WEBROOT="$PREFIX/web"
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

say() { printf '%s\n' "$*"; }
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
askdefault() { printf '%s [%s]: ' "$1" "$2"; read -r "$3" || true; [ -n "$(eval echo \$$3)" ] || eval "$3='$2'"; }

command -v python3 >/dev/null || { say "缺 python3，先装：apt-get install -y python3"; exit 1; }

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
  say "要做什么？"
  say "  1) 装面板 server（收所有探针的数据 + 网页）"
  say "  2) 装探针 client（把这台机器上报给面板）"
  say "  3) 卸载"
  say "  4) 启动   5) 停止   6) 重启   7) 看状态"
  say "  8) 节点账号（看列表 / 加 / 删）"
  ask "选 1-7: " PICK
  case "$PICK" in
    1) ROLE=server ;;
    2) ROLE=client ;;
    3) ROLE=uninstall ;;
    4) ROLE=manage; ACTION=start ;;
    5) ROLE=manage; ACTION=stop ;;
    6) ROLE=manage; ACTION=restart ;;
    7) ROLE=manage; ACTION=status ;;
    8) ROLE=nodes ;;
    *) say "只认 1-7"; exit 1 ;;
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
  systemctl enable --now "$2"
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

  ask "监听方式：unix socket（推荐，不占端口，nginx 直接 proxy_pass 到文件）还是 TCP 端口？(u/t) [u]: " BINDMODE
  case "$BINDMODE" in
    t|T|tcp|TCP)
      askdefault "面板监听端口（只给本机 nginx 用）" "8080" HTTP_PORT
      case "$HTTP_PORT" in *[!0-9]*|"") say "端口要是数字"; exit 1;; esac
      BIND_ADDR="127.0.0.1" ;;
    *)
      HTTP_PORT=""
      BIND_ADDR="unix:$PREFIX/run/http.sock" ;;
  esac
  askdefault "探针上报端口" "35601" TCP_PORT
  case "$TCP_PORT" in *[!0-9]*|"") say "端口要是数字"; exit 1;; esac

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
  if [ -n "$HTTP_PORT" ]; then
    say "面板已启动（127.0.0.1:$HTTP_PORT，探针端口 $TCP_PORT）"
  else
    say "面板已启动（socket：$PREFIX/run/http.sock，探针端口 $TCP_PORT）"
  fi
  say ""
  if confirmn "要我帮你装/配 nginx 吗？（本机已有就只加一个 conf.d/zstat.conf，不动你现有站点）"; then
    if ! command -v nginx >/dev/null; then
      if confirm "本机没有 nginx，现在装一个？"; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx && mark_installed nginx || say "nginx 装失败"
      fi
    fi
    if command -v nginx >/dev/null; then
      ask "域名（可空，空就按端口/IP 访问）: " NDOMAIN
      if [ -n "$HTTP_PORT" ]; then PASSLINE="proxy_pass http://127.0.0.1:$HTTP_PORT;"; else PASSLINE="proxy_pass http://unix:$PREFIX/run/http.sock:;"; fi
      mkdir -p /etc/nginx/conf.d
      {
        echo "server {"
        echo "    listen 80;"
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
        systemctl reload nginx
        say "nginx 已配好：/etc/nginx/conf.d/zstat.conf${NDOMAIN:+　http://$NDOMAIN}"
        say "要 HTTPS：certbot --nginx -d $NDOMAIN"
      else
        rm -f /etc/nginx/conf.d/zstat.conf
        say "nginx -t 没过，我把 zstat.conf 删了，你的 nginx 没动："
        nginx -t 2>&1 | tail -3
      fi
    else
      say "没有 nginx，跳过。下面这段自己反代。"
    fi
  else
    say "好，不碰 nginx。下面这些你自己反代。"
  fi

  say ""
  say "静态目录：$WEBROOT"
  say ""
  say "  静态目录：$WEBROOT"
  if [ -n "$HTTP_PORT" ]; then say "  API 地址：127.0.0.1:$HTTP_PORT"; else say "  API 地址：unix:$PREFIX/run/http.sock"; fi
  say ""
  say "  （只反代静态目录也行：$WEBROOT 里会自动写 stats.json，前端读不到 /api 就改读它）"
  say ""
  say "  nginx 大概这么写："
  if [ -n "$HTTP_PORT" ]; then
    say "  # 静态文件 + API（TCP 端口）"
    say "  root $WEBROOT;"
    say "  location /api/ {"
    say "      proxy_pass http://127.0.0.1:$HTTP_PORT;"
    say "      proxy_set_header Host \$host;"
    say "  }"
    say "  location / { try_files \$uri \$uri/ /index.html; }"
  else
    say "  # 静态文件 + API（unix socket，不占端口）"
    say "  root $WEBROOT;"
    say "  location /api/ {"
    say "      proxy_pass http://unix:$PREFIX/run/http.sock:;"
    say "      proxy_set_header Host \$host;"
    say "  }"
    say "  location / { try_files \$uri \$uri/ /index.html; }"
    say ""
    say "  socket 文件权限是 666，nginx 能直接写；nginx 要是有 user 限制，确认 /run 目录可读。"
  fi
  say ""
  say "要 HTTPS 就自己跑：certbot --nginx -d 你的域名"
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
  case "$TCP_PORT" in *[!0-9]*|"") say "端口要是数字，用 35601"; exit 1;; esac
  ask "账号: " CUSER
  ask "密码: " CPASS
  ask "机房/位置（如 Hong Kong，可空）: " CLOC
  ask "到期日 YYYY-MM-DD（可空）: " CEXP
  CCYCLE=""
  if [ -n "$CEXP" ]; then
    ask "月付还是年付？(m/y) [m]: " CCYCLE
    case "$CCYCLE" in y|Y|year|年|年付) CCYCLE=year ;; *) CCYCLE=month ;; esac
  fi

  cat > "$PREFIX/agent.json" <<JSON
{
  "server": "$CSERVER",
  "port": $TCP_PORT,
  "user": "$CUSER",
  "password": "$CPASS",
  "name": "$CNAME",
  "location": "$CLOC",
  "expire": "$CEXP",
  "cycle": "$CCYCLE",
  "interval": 5
}
JSON
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
  ask "到期日 YYYY-MM-DD（可空）: " NEXP
  NCP=""
  if [ -n "$NEXP" ]; then
    ask "月付还是年付？(m/y) [m]: " NCP
  fi
  sh "$PREFIX/user.sh" add "$NNAME" "" "$NCP" "$NEXP" | sed -n '1,4p'
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
    ask "a 添加 / d 删除 / r 续期 / 回车返回: " NACT
    case "$NACT" in
      a|A) node_add ;;
      d|D) node_del ;;
      r|R) node_renew ;;
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

# ---------------- uninstall ----------------
if [ "$ROLE" = "uninstall" ]; then
  HAVE_SERVER=0; HAVE_AGENT=0
  [ -f /etc/systemd/system/zstat-server.service ] && HAVE_SERVER=1 || true
  [ -f /etc/systemd/system/zstat-agent.service ] && HAVE_AGENT=1 || true
  if [ "$HAVE_SERVER" = 0 ] && [ "$HAVE_AGENT" = 0 ] && [ ! -d "$PREFIX" ]; then
    say "这台机器上没找到 zstat，应该没装过。"
    exit 0
  fi

  ask "卸哪个？面板填 1，探针填 2，两个都卸填 3: " WHICH
  case "$WHICH" in 1|2|3) ;; *) say "只认 1、2、3"; exit 1 ;; esac

  # 1) 停服务、删单元
  if [ "$WHICH" = "1" ] || [ "$WHICH" = "3" ]; then
    if [ "$HAVE_SERVER" = 1 ]; then
      systemctl disable --now zstat-server >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/zstat-server.service
    fi
    say "面板服务已停"
  fi
  if [ "$WHICH" = "2" ] || [ "$WHICH" = "3" ]; then
    if [ "$HAVE_AGENT" = 1 ]; then
      systemctl disable --now zstat-agent >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/zstat-agent.service
    fi
    say "探针服务已停"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true

  # 2) nginx 站点 / 证书 / 目录：卸面板就一起清，不再多问
  if [ "$WHICH" = "1" ] || [ "$WHICH" = "3" ]; then
    if [ -f /etc/nginx/sites-available/zstat ]; then
      rm -f /etc/nginx/sites-enabled/zstat /etc/nginx/sites-available/zstat
      command -v nginx >/dev/null && { nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true; }
      say "nginx 里的 zstat 站点已删"
    fi
    for d in $(grep '^domain=' "$PREFIX/.zstat-installed" 2>/dev/null | sed 's/^domain=//'); do
      if command -v certbot >/dev/null; then
        certbot delete --cert-name "$d" -n >/dev/null 2>&1 && say "证书 $d 已删" || say "证书 $d 没删掉"
      fi
    done
  fi

  # 3) 软件：只问这一句
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
          DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p" >/dev/null 2>&1 || say "$p 卸载失败"
        fi
      done
      [ -z "$ZSTAT_PREFIX" ] && { apt-get autoremove -y >/dev/null 2>&1 || true; }
      say "软件已卸载"
    else
      say "软件保留（nginx / certbot 没动）"
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
