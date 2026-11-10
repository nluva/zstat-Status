# zstat

一个能自己跑起来的探针系统：**面板收数据 + 探针上报 + 网页展示**。
纯 Python 3 标准库，不装任何第三方包，不用 `docker`，不用数据库。

> 起因：原来那套 `ServerStatus-Hotaru` 的 `status.sh` 在新系统上装不动，网页也旧了。所以重写了一套，功能对齐常用的那几样，代码量小到能一口气读完。

## 快速安装

面板（选一台机器）：

```sh
wget -O status.sh https://raw.githubusercontent.com/nluva/zstat-Status/main/install.sh
bash status.sh s
```

探针（每台被监控的机器）：

```sh
wget -O status.sh https://raw.githubusercontent.com/nluva/zstat-Status/main/install.sh
bash status.sh c
```

不带参数跑 `bash status.sh` 就是交互菜单，问你要装面板还是探针。

## 面板装的时候会问什么

1. 面板监听端口（默认 `8080`，**只绑 127.0.0.1**，由 nginx 反代）
2. 探针上报端口（默认 `35601`）
3. **域名**（不填就只在本机提供，自己反代）
4. 域名用 **IPv4 还是 IPv6**（选 6 时 nginx 写 `listen [::]:80 ipv6only=on`）
5. 证书邮箱（填了就自动装 nginx、写 vhost、跑 `certbot --nginx` 签证书，签完自动 `renew --dry-run` 验一遍续期）

装完会打印下一步：给节点建账号。

```sh
sh /usr/local/ServerStatus/user.sh add hk1     # 生成随机密码并打印
sh /usr/local/ServerStatus/user.sh list        # 看所有账号
sh /usr/local/ServerStatus/user.sh del hk1     # 删
```

## 探针装的时候会问什么

节点名称 → 面板地址 → 上报端口 → **账号** → **密码** → 机房位置 → 到期日。
写进 `/usr/local/ServerStatus/agent.json`（600 权限），然后起 `zstat-agent`。

## 认证

每台探针一个**用户名 + 密码**（`server.json` 的 `users` 数组），不是全局共享 token。
没配 `users` 时才回退到 `token` 字段。

## 网页长什么样

- 一行一台机器，单行紧凑，1280 宽能看十几台
- 状态只有两个：**运行中** / **失联中**（超过 `stale_seconds` 没上报就算失联）
- 到期日期自动算天数，30 天内变红
- CPU / RAM / 硬盘是细进度条，**鼠标放上去**看细节：
  - CPU：核心数 + 型号（`4 核 · Intel Xeon E5-2678 v3`）
  - RAM：已用/总量 + SWAP 已用/总量
  - 硬盘：已用/总量
- 页面 **5 秒**自动刷新；手机上是卡片布局；跟随系统深色模式

## 目录结构

```
server.py                 面板：TCP 收上报 + HTTP 出 API + 静态网页
agent.py                  探针：读 /proc 采集并上报
web/                      前端（index.html / style.css / app.js）
user.sh                   账号管理
deploy/*.service          systemd 单元
tools/demo_feed.py        灌假数据看效果的演示脚本（正式别跑）
install.sh                安装脚本（就是 status.sh）
```

安装后统一在 `/usr/local/ServerStatus/`，systemd 单元是 `zstat-server` / `zstat-agent`。

## 常用命令

```sh
systemctl status zstat-server
systemctl restart zstat-agent
journalctl -u zstat-server -n 50
curl -s http://127.0.0.1:8080/api/servers | head -c 300
```

## 数据从哪来

探针每 5 秒发一行 JSON 到面板的 TCP 端口，面板按节点名存最新一份（内存里），
顺便原子写到 `run/stats.json`；网页读 `/api/servers`。

## 安全提醒

- `35601` 只靠账号密码，**没有失败次数限制**：正式用请用安全组/防火墙只放探针 IP
- 上报是明文 TCP：跨公网建议走内网或隧道
- 面板本身**没有登录**：要么只在内网，要么放 nginx 的 `auth_basic` 后面

## 已知没做

- 历史曲线、阈值报警、多用户登录
- 几百台规模（现在是全内存 + 一个 json，几十台没问题）
- 探针侧的 HTTPS 上报

## 和 ServerStatus-Hotaru 的关系

另起一套，数据格式不兼容。老的可以同时开着，确认新链路稳了再停。

## License

MIT
