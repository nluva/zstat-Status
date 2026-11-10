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

不带参数跑 `bash status.sh` 就是交互菜单：装面板 / 装探针 / 卸载 / 启动 / 停止 / 重启 / 看状态。

## 日常管理

```sh
bash status.sh status      # 看服务和状态（最近 5 行日志 + 网页端口）
bash status.sh start
bash status.sh stop
bash status.sh restart
bash status.sh log         # 最近 40 行日志
bash status.sh u           # 卸载（会问卸面板还是探针，再问要不要删数据）
```

`start/stop/restart` 会**把这台机器上装过的 zstat 服务都管一遍**（只装了探针就只管探针）。

卸载只问两句（**回车都是 y**）：

```sh
bash status.sh u
# 卸哪个？面板填 1，探针填 2，两个都卸填 3: 1
# 这个脚本还装过：certbot nginx
# 连它们一起卸载吗？ (Y/n):
```

**不用多问，卸面板就自动清这些**：停服务 → 删 systemd 单元 → 删 nginx 里的 zstat 站点 → 删证书 → 删 `/usr/local/ServerStatus`。

只有「要不要连 nginx / certbot 这些软件一起卸」需要你点头——因为那会影响这台机器上的其它站点。答 n 就只清 zstat 自己的东西。

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
