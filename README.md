# zstat · 自己写的探针

一个能跑的最小可用版：**面板收数据 + 探针上报 + 网页展示**，全部 Python 3 标准库，不装第三方包。

## 长什么样

- 面板（服务端）：一个 TCP 端口收上报，一个 HTTP 端口给网页和 API
- 探针（被控机）：读 `/proc` 拿 CPU/内存/硬盘/网卡/开机时长，每 5 秒上报一次
- 网页：状态胶囊、到期倒计时（30 天内变红）、CPU/RAM/硬盘细进度条，手机自动变卡片

## 目录

```
server.py                面板：TCP 收上报 + HTTP 出数据 + 静态网页
agent.py                 探针：采集本机状态并上报
web/                     前端（index.html / style.css / app.js）
deploy/*.service         systemd 单元
install.sh               一键安装（server / agent 两种）
server.json              面板配置（token、两个端口）
agent.json               探针配置（面板地址、token、节点名）
run/stats.json           面板自动写出的最新状态（原子替换）
```

## 装法

面板那台：

```sh
tar xf zstat.tar.gz && cd zstat
sh install.sh server
# 会打印 token 和网页地址；token 要抄给每台探针
```

每台被控机：

```sh
tar xf zstat.tar.gz && cd zstat
sh install.sh agent
vi /opt/zstat/agent.json     # 填 server(面板IP) / token / name / location / expire
systemctl restart zstat-agent
journalctl -u zstat-agent -f # 看它有没有上报失败
```

## 认证

每台探针一个账号（`server.json` 里的 `users`），用 `user.sh add <名字>` 生成。
没配 `users` 时才回退到旧的共享 token 方式（`token` 字段）。

## 离线判定

`stale_seconds`（默认 30）秒内没收到某台的上报，服务端就把它的 `online4/online6` 置 false，
前端显示「离线」——不会出现机器已经挂了、网页还显示运行中的情况。超时会附 `age`（秒）。

## 对外暴露

- 面板 HTTP 默认 `8080`，TCP 默认 `35601`
- 只给网页看的话，用 nginx 反代 8080 就行，不用暴露 35601
- 探针和面板之间的认证只有一个共享 token，够用但不适合公网裸奔；**建议 35601 只对探针的 IP 开放**（`iptables` 或云防火墙）

## 排错

| 现象 | 检查 |
|---|---|
| 网页空白、表里没节点 | 面板 `journalctl -u zstat-server`；探针 `journalctl -u zstat-agent` |
| 探针日志「上报失败」 | 面板 IP/端口对不对；防火墙有没有放 35601 |
| 网页显示离线 | token 不对，或探针超过 30 秒没上报 |
| 端口被占 | 改 `server.json` 的 `tcp_port`/`http_port`，`systemctl restart zstat-server` |

## 和旧版的关系

`ServerStatus-Hotaru` 的数据格式和服务端不兼容，是**另起一套**：
老的 `status.sh` / `sergate` / vue 前端都不再需要。要迁移就一台一台把探针换过来，网页同时开着对比，稳了再停旧的。

## 已知没做的

- 历史曲线（现在只有最新一帧）
- 报警（超过阈值发消息）
- 多用户/登录（面板目前是公开的）
- IPv6-only 探测（只判断有没有 v6 出口，不测 v6 可达性）
