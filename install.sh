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
  "") ;;
  *) echo "用法: bash status.sh [s|c|u|start|stop|restart|status|log]"; exit 1 ;;
esac

say() { printf '%s\n' "$*"; }
# 确认框：回车算 y，只有明确 n/no 才算否
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
  for URL in "$TARBALL" "$MIRROR"; do
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
  ask "选 1-7: " PICK
  case "$PICK" in
    1) ROLE=server ;;
    2) ROLE=client ;;
    3) ROLE=uninstall ;;
    4) ROLE=manage; ACTION=start ;;
    5) ROLE=manage; ACTION=stop ;;
    6) ROLE=manage; ACTION=restart ;;
    7) ROLE=manage; ACTION=status ;;
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
  find_src
  install_files

  askdefault "面板监听端口（只给本机 nginx 用）" "8080" HTTP_PORT
  case "$HTTP_PORT" in *[!0-9]*|"") say "端口要是数字"; exit 1;; esac
  askdefault "探针上报端口" "35601" TCP_PORT
  case "$TCP_PORT" in *[!0-9]*|"") say "端口要是数字"; exit 1;; esac
  ask "域名（没有就回车，跳过 nginx/证书）: " DOMAIN
  if [ -n "$DOMAIN" ]; then
    ask "这个域名用 IPv4 还是 IPv6？(4/6) [4]: " IPVER
    [ -n "$IPVER" ] || IPVER=4
    case "$IPVER" in 4|6) ;; *) say "只支持 4 或 6"; exit 1;; esac
    ask "证书邮箱（不签 HTTPS 就回车）: " EMAIL
  fi

  cat > "$PREFIX/server.json" <<JSON
{
  "token": "",
  "users": [],
  "bind": "127.0.0.1",
  "tcp_port": $TCP_PORT,
  "http_port": $HTTP_PORT,
  "web_root": "$WEBROOT",
  "stale_seconds": 30
}
JSON
  chmod 600 "$PREFIX/server.json"

  svc deploy/zstat-server.service zstat-server
  say "面板已启动（127.0.0.1:$HTTP_PORT，探针端口 $TCP_PORT）"

  if [ -n "$DOMAIN" ]; then
    if ! command -v nginx >/dev/null; then
      say "装 nginx…"
      (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx && mark_installed nginx) || say "nginx 装失败，请手动装"
    fi
    if command -v nginx >/dev/null; then
      if [ "$IPVER" = "6" ]; then LISTEN='    listen [::]:80 ipv6only=on;'; else LISTEN='    listen 80;'; fi
      cat > /etc/nginx/sites-available/zstat <<NGINX
server {
$LISTEN
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:$HTTP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX
      mkdir -p /etc/nginx/sites-enabled
      ln -sf /etc/nginx/sites-available/zstat /etc/nginx/sites-enabled/zstat
      nginx -t && systemctl reload nginx && say "nginx 已配好：http://$DOMAIN"

      if [ -n "$EMAIL" ]; then
        MYIP=$(python3 - "${IPVER:-4}" <<'PY2'
import socket, sys
ver = sys.argv[1]
try:
    if ver == "6":
        s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); s.settimeout(3)
        s.connect(("2606:4700:4700::1111", 80))
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
        s.connect(("1.1.1.1", 80))
    print(s.getsockname()[0]); s.close()
except OSError:
    print("")
PY2
)
        DOMIP=$(python3 - "$DOMAIN" "${IPVER:-4}" <<'PY2'
import socket, sys
name, ver = sys.argv[1], sys.argv[2]
try:
    if ver == "6":
        infos = socket.getaddrinfo(name, None, socket.AF_INET6)
        print(infos[0][4][0] if infos else "")
    else:
        print(socket.gethostbyname(name))
except OSError:
    print("")
PY2
)
        case "$MYIP" in
          10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|"")
            say "$DOMAIN 解析到：${DOMIP:-解析不到}（本机在 NAT 后面，跳过 IP 比对）"; MYIP="" ;;
          *) say "本机公网 IP：$MYIP　$DOMAIN 解析到：${DOMIP:-解析不到}" ;;
        esac
        if [ -z "$DOMIP" ]; then
          say "！！域名解析不到，签名一定失败；先做解析，再跑：certbot --nginx -d $DOMAIN --agree-tos -m $EMAIL --redirect"
          SKIP_CERT=1
        elif [ -n "$MYIP" ] && [ "$DOMIP" != "$MYIP" ]; then
          say "！！$DOMAIN 现在指向 $DOMIP，不是这台机器（$MYIP）。"
          ask "还是要试吗？(y/N): " GO
          [ "$GO" = "y" ] || SKIP_CERT=1
        fi
        if [ -z "$SKIP_CERT" ]; then
          if ! command -v certbot >/dev/null; then
            say "装 certbot…"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx \
            && mark_installed certbot && mark_installed python3-certbot-nginx || say "certbot 装失败"
          fi
          if command -v certbot >/dev/null; then
            if certbot --nginx -d "$DOMAIN" --agree-tos -m "$EMAIL" --redirect -n; then
              say "证书已签。验证续期链路…"
              certbot renew --dry-run 2>&1 | tail -3 || say "dry-run 没过，留意 certbot.timer"
              systemctl list-timers certbot.timer --no-pager 2>/dev/null | head -3
            else
              say "证书申请失败，站点仍在 http；排错后再跑：certbot --nginx -d $DOMAIN"
            fi
          fi
        fi
      else
        say "没给邮箱，跳过 HTTPS；以后可以跑：certbot --nginx -d $DOMAIN"
      fi
    fi
  else
    say "没给域名：只在本机 $HTTP_PORT 提供，请自己用 nginx 反代到 $WEBROOT"
  fi

  say ""
  say "下一步：给每台机器建账号"
  say "  sh $PREFIX/user.sh add hk1"
  say "  sh $PREFIX/user.sh list"
fi

# ---------------- 探针 ----------------
if [ "$ROLE" = "client" ]; then
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

  cat > "$PREFIX/agent.json" <<JSON
{
  "server": "$CSERVER",
  "port": $TCP_PORT,
  "user": "$CUSER",
  "password": "$CPASS",
  "name": "$CNAME",
  "location": "$CLOC",
  "expire": "$CEXP",
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

# ---------------- manage ----------------
if [ "$ROLE" = "manage" ]; then
  manage
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

  # 4) 程序目录：直接删
  if [ -d "$PREFIX" ]; then
    rm -rf "$PREFIX"
    say "已删除 $PREFIX"
  fi
  say "卸载完成。"
fi
