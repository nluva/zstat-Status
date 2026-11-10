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

PREFIX="${ZSTAT_PREFIX:-/usr/local/ServerStatus}"
WEBROOT="$PREFIX/web"
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
ROLE="$1"
case "$ROLE" in
  s|S|server|Server) ROLE=server ;;
  c|C|client|Client) ROLE=client ;;
  "") ;;
  *) echo "用法: bash status.sh [s|c]"; exit 1 ;;
esac

say() { printf '%s\n' "$*"; }
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
  say "从 GitHub 下载源码包…"
  if command -v curl >/dev/null; then
    curl -fsSL "$TARBALL" -o "$TMP/src.tar.gz"
  elif command -v wget >/dev/null; then
    wget -q "$TARBALL" -O "$TMP/src.tar.gz"
  else
    say "缺 curl/wget"; exit 1
  fi
  tar xzf "$TMP/src.tar.gz" -C "$TMP"
  SRC=$(ls -d "$TMP"/zstat-Status-* 2>/dev/null | head -1)
  [ -n "$SRC" ] && [ -f "$SRC/server.py" ] || { say "源码包解压失败"; exit 1; }
}

if [ -z "$ROLE" ]; then
  say "装什么？"
  say "  1) 面板 server（收所有探针的数据 + 网页）"
  say "  2) 探针 client（把这台机器上报给面板）"
  ask "选 1 或 2: " PICK
  [ "$PICK" = "1" ] && ROLE=server || ROLE=client
fi

find_src

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
  sed "s#/opt/zstat#$PREFIX#g" "$SRC/$1" > "/etc/systemd/system/$2"
  systemctl daemon-reload
  systemctl enable --now "$2"
}

# ---------------- 面板 ----------------
if [ "$ROLE" = "server" ]; then
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
      (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx) || say "nginx 装失败，请手动装"
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
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx || say "certbot 装失败"
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
