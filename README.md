# SP Traffic

面向 Linux VPS 的可控下载带宽压测服务。它只从你明确配置的 HTTP/HTTPS 端点下载数据，内容直接写入 `/dev/null`，用于验证你自己的 VPS 网络吞吐、流量计费和链路稳定性。

> 仅可配置你拥有、运营商明确允许，或已获得所有者授权的测试端点。不要把本项目用于干扰第三方服务。持续不限速运行可能快速耗尽套餐流量并产生费用。

## 功能

- `sp` 中文交互菜单：状态、开始、暂停、继续、停止、清除、端点、并发/限速、日志、卸载
- 内置 `https://sin-speed.hetzner.com/10GB.bin` 作为默认推荐端点
- systemd、OpenRC 与 SysV 兼容服务，SSH 断开后继续后台运行，并可随系统启动
- 自动探测并优先选择内核已有的 `bbrz`、`bbr3`、`bbr2`、`bbr`，不自动替换第三方内核
- 默认激进下载模式：最多 32 路自适应连接、更快失败重试和较大的 TCP 收发缓冲
- 支持 Debian、Ubuntu、RHEL、CentOS、Rocky、AlmaLinux、Fedora、Alpine、Arch、openSUSE 等常见发行版
- 每 30 秒根据 CPU、可用内存和磁盘空间调整并发，硬上限 32
- 下载内容不落盘；仅保存很小的配置、PID 和累计字节统计
- 可用磁盘低于 200 MiB 时立即终止传输并自动暂停，防止小磁盘 VPS 被日志或其他进程拖死
- 失败重试、退避、连接/传输超时与可选总带宽上限
- 使用独立低权限用户 `sptraffic` 运行

## 一键安装

安装管理工具和服务。安装器会写入默认端点，但不会在无人确认时自动启动：

```bash
curl -fsSL https://raw.githubusercontent.com/WXD2233/sp-traffic/main/install.sh | sudo bash
```

确认流量费用和测速服务使用规则后，手动启动：

```bash
sudo sp start
```

安装时直接配置一个经授权的测试端点并启动：

```bash
curl -fsSL https://raw.githubusercontent.com/WXD2233/sp-traffic/main/install.sh \
  | sudo bash -s -- --url https://your-authorized-host.example/large-test.bin
```

可选参数：

```text
--url URL          添加授权端点，可重复
--workers N        0=资源自适应，1-32=并发上限
--max-mbps N       总下载限速 Mbps，0=不限速
--balanced         使用均衡下载模式
--start            使用内置默认端点，安装后立即启动
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
sudo sp endpoints default
sudo sp start
sudo sp status
sudo sp pause
sudo sp resume
sudo sp stop
sudo sp clear
sudo sp uninstall
```

建议使用足够大的静态文件或专用测速端点。每个工作槽完成一次下载后至少等待 2 秒，小文件不会被用来制造高频请求。

默认的 Hetzner 新加坡 10GB 文件适合短时吞吐测试，不代表可以长期、无限循环占用第三方带宽。长期运行请改用你自己的另一台 VPS、对象存储或明确授权的端点。

## BBR 说明

安装器会尝试加载内核已有的 BBR 模块，并按 `bbrz → bbr3 → bbr2 → bbr` 的顺序选择系统实际提供的算法，同时写入：

```text
net.core.default_qdisc=fq
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_mtu_probing=1
```

如果当前内核不支持这些 BBR 变体，安装器会保留原拥塞控制，不会擅自安装未知内核或重启 VPS。具体是 BBRv1、BBRv2 还是 BBRv3，取决于 VPS 当前内核的实现。卸载时会删除本项目创建的 sysctl/module 配置，并尽量恢复安装前的拥塞控制、队列和缓冲值。

下载场景中，远端服务器才是主要 TCP 发送方，因此本机拥塞算法不能让远端“无视丢包”。激进模式主要通过多条并行连接、较大接收缓冲和更快失败重试，降低单连接丢包对总吞吐的影响。

## 资源策略

- 激进模式默认并发为 `CPU 核心数 × 4`，均衡模式为 `CPU 核心数 × 2`
- 激进模式每个工作槽至少预留约 32 MiB，均衡模式约 64 MiB
- 可用磁盘少于 256 MiB 时最多 2 个工作槽，少于 64 MiB 时只运行 1 个
- 可用磁盘低于 `MIN_FREE_DISK_MB`（默认 200 MiB）时，立即终止当前传输并自动暂停
- 释放空间后需手动运行 `sudo sp resume`；空间仍低于阈值时会拒绝启动或继续
- 无论配置如何，并发硬上限为 32
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
