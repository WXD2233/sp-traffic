# SP Traffic

面向 Linux VPS 的可控下载带宽压测服务。它只从你明确配置的 HTTP/HTTPS 端点下载数据，内容直接写入 `/dev/null`，用于验证你自己的 VPS 网络吞吐、流量计费和链路稳定性。

> 仅可配置你拥有、运营商明确允许，或已获得所有者授权的测试端点。不要把本项目用于干扰第三方服务。持续不限速运行可能快速耗尽套餐流量并产生费用。

## 功能

- `sp` 中文交互菜单：状态、开始、暂停、继续、停止、清除、端点、并发/限速、日志、卸载
- systemd、OpenRC 与 SysV 兼容服务，SSH 断开后继续后台运行，并可随系统启动
- 自动尝试启用内核 BBR 拥塞控制与 `fq` 队列算法
- 支持 Debian、Ubuntu、RHEL、CentOS、Rocky、AlmaLinux、Fedora、Alpine、Arch、openSUSE 等常见发行版
- 每 30 秒根据 CPU、可用内存和磁盘空间调整并发，硬上限 16
- 下载内容不落盘；仅保存很小的配置、PID 和累计字节统计
- 失败重试、退避、连接/传输超时与可选总带宽上限
- 使用独立低权限用户 `sptraffic` 运行

## 一键安装

安装管理工具和服务（此时不会启动，因为还没有端点）：

```bash
curl -fsSL https://raw.githubusercontent.com/WXD2233/sp-traffic/main/install.sh | sudo bash
```

安装时直接配置一个经授权的测试端点并启动：

```bash
curl -fsSL https://raw.githubusercontent.com/WXD2233/sp-traffic/main/install.sh \
  | sudo bash -s -- --url https://your-authorized-host.example/large-test.bin
```

可选参数：

```text
--url URL          添加授权端点，可重复
--workers N        0=资源自适应，1-16=并发上限
--max-mbps N       总下载限速 Mbps，0=不限速
--no-bbr           不修改 BBR/FQ 配置
--no-start         安装后不启动
```

## 使用

```bash
sudo sp
```

也可以直接执行子命令：

```bash
sudo sp endpoints add https://your-authorized-host.example/large-test.bin
sudo sp start
sudo sp status
sudo sp pause
sudo sp resume
sudo sp stop
sudo sp clear
sudo sp uninstall
```

建议使用足够大的静态文件或专用测速端点。每个工作槽完成一次下载后至少等待 2 秒，小文件不会被用来制造高频请求。

## BBR 说明

安装器会加载 `tcp_bbr`，并写入：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

如果当前内核不支持 BBR，安装器只会给出警告，不会擅自升级内核或重启 VPS。多数现代发行版内核已内置 BBR；老内核需要由你按发行版升级后重启。卸载时会删除本项目创建的 sysctl/module 配置，并尽量恢复安装前的活动值。

## 资源策略

- 默认并发为 `CPU 核心数 × 2`
- 每个工作槽至少预留约 64 MiB 可用内存
- 可用磁盘少于 256 MiB 时最多 2 个工作槽，少于 64 MiB 时只运行 1 个
- 无论配置如何，并发硬上限为 16
- 传输数据始终写入 `/dev/null`，不会用大文件占满磁盘
- 服务使用较低调度优先级，并提高 OOM 回收倾向，以保护系统关键服务

## 本地验证

```bash
bash -n install.sh sp worker.sh
bash tests/test.sh
PYTHON_BIN=python3 bash tests/integration.sh
```

## 许可

MIT
