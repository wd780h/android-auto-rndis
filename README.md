# br77

实验模块，版本 v0.1.0。只把 USB 网络共享（`rndis` / `ncm`）固定成 `192.168.77.0/24`，网关 `192.168.77.1`。不建桥。Wi-Fi 热点仍由系统分配地址，本模块不启动、不修改热点。

只在一台 POCO F5（`23049PCD8G`，Android 15，SukiSU Ultra，arm64）上测过。那次测试里，电脑拿到 `192.168.77.11`，手机能 ping 通这台电脑，电脑查 `192.168.77.1` 的 DNS 能解析。IPv6 路由通告已经从 `rndis0` 发出，使用运营商的 `/64`；客户端是否拿到全球地址取决于它自己的 SLAAC。

`AUTO_USB=1` 时，电脑插上并完成枚举（UDC 为 `configured`，或 `android0` 为 `CONFIGURED`/`CONNECTED`）且当前功能里没有 `rndis`/`ncm`，脚本会调用 `svc usb setFunctions rndis`。仅充电时小米经常不把 `android0` 标成已连接，所以以 UDC 为准。这台手机上 adb 仍然留着。没插电脑时不会切。系统若把 `rndis0` 标成自己的网段，脚本会解开这次共享，再把 `192.168.77.1/24` 直接配在 `rndis0` 上。

Magisk、KernelSU、SukiSU 都可以装这个 zip。后两者会执行里面的 `service.sh`。

## 它实际做了什么

`PORTS=auto` 时只认已经 UP、名字像 `rndis*`、`usb*`、`ncm*` 的接口，取第一个。热点、`wlan*`、蜂窝口不会被改地址。

地址在 USB 网卡上，不在桥上。旧的 `br77` 桥如果还在，循环会删掉它。

壳脚本大约每 2 秒看一次出口。`192.168.77.0/24` 的 `MASQUERADE` 不绑定具体网卡，插在 `POSTROUTING` 第 1 条。策略路由 `pref 21000` 是 `iif <usb> lookup <当前出口的表>`，IPv4 和 IPv6 各一条。同一条 `192.168.77.0/24 dev <usb>` 会写进 `main`、`legacy_system`、`legacy_network`、`local_network` 和出口那张表。5G 从一张 `rmnet` 换到另一张时，下一轮会改到新表。没有默认路由时，客户端上不了网。

系统热点的 BPF 会在没有连接跟踪的情况下改地址，回包变成「网络不可达」。脚本只删除 USB 网卡上的 ingress tc filter，不扫蜂窝口，硬件卸载开关保持系统原样。系统若把 filter 装回来，下一轮再删。

防火墙被整机放开：IPv4 和 IPv6 的 `INPUT`、`FORWARD`、`OUTPUT` 策略设为 `ACCEPT`。另外给 USB 网卡双向 `FORWARD ACCEPT`，并做 TCP MSS `clamp-mss-to-pmtu`。这不只作用于 `192.168.77.0/24`。

`br77d` 是静态 arm64 程序。它回答 DHCP（租期 7 天），并大约每 3 秒发一次 IPv6 路由通告。转发在内核里完成。

## 安装

仓库里带有编好的 `br77d`（arm64）和模块包 `br77.zip`。重新打包：

```sh
zip -r br77.zip \
  META-INF module.prop service.sh customize.sh uninstall.sh \
  config.default br77-loop.sh br77d README.md LICENSE
```

在 Magisk、KernelSU 或 SukiSU 里选「安装模块」，选 `br77.zip`，然后重启。这不是系统刷机包。

如果以前手动放过 `/data/adb/service.d/br77.sh`，安装时会把它改名为 `br77.sh.bak`。

要自己编译守护进程：

```sh
./build.sh
```

需要能指定 `--target=aarch64-linux-android21` 的 clang。`br77d` 不链接 bionic，源码在 `src/br77d.c`。没有 arm32 和 x86 二进制。

## 配置

第一次开机把 `config.default` 复制到 `/data/adb/br77/config`。改这个副本再重启。`BRIDGE` 这一项已不再使用，运行时会被 USB 网卡名盖掉。

| 项 | 默认 | 作用 |
|---|---|---|
| `ADDR` | `192.168.77.1` | USB 网卡的 IPv4 地址 |
| `PREFIX` | `24` | 掩码。DHCP 只使用地址的最后一段 |
| `DHCP_START` / `DHCP_END` | `.10`–`.200` | 地址池 |
| `PORTS` | `auto` | `auto` 为自动识别 USB 网卡；写成接口名则只用这些 |
| `AUTO_USB` | `1` | 插上电脑后切到 `rndis` |
| `IPV6` | `1` | 把上游全球单播前缀通告给 USB 客户端 |

日志在 `/data/adb/br77/br77.log` 和 `/data/adb/br77/br77d.log`，只追加，不会自己截断。

系统 tether 的 `dnsmasq` 正在听、并且带有 `--listen-mark` 时，DHCP 把 DNS 下发成 `192.168.77.1`，进入 USB 网卡的 53 端口会被打上这个标记并转到 `127.0.0.1:53`。它没起来时（这台手机解开系统共享之后通常就是这样），DHCP 改发 `8.8.8.8`，53 端口也转到 `8.8.8.8`。已经拿到旧租约的设备要重新连接一次。

## IPv6

用的是运营商给的那个 `/64`，不是另起一段。Android 会把 USB 网卡的 `disable_ipv6` 写成 1，脚本每轮把它改回 0，否则没有链路本地地址，路由通告发不出去。USB 网卡自身关闭 `accept_ra` 和 `autoconf`，并清掉全球地址，避免把这段前缀占走。

通告只要求自动配置。回程要有一条该客户端全球地址的 `/128`，从 USB 网卡出去，并在出口上做邻居代理。脚本要在邻居表里看到非 `fe80` 地址后才装这些路由。第一次发包时邻居可能还没有。旧前缀上的 `/128` 不会自动删除。

## 已知限制

- 不会自动打开 Wi-Fi 热点，也不保证系统热点能开。这台手机上系统热点曾因 tethering 报错马上关掉，本模块不处理这件事。
- DHCP 按 `/24` 发地址，租期 7 天。租约写在 `/data/adb/br77/leases`，守护进程重启后仍把同一 MAC 发回原地址。解开系统对这块网卡的共享之后，系统 DHCP 不再和 `br77d` 抢 67 端口。
- 只有 arm64。
- 蜂窝路径上见过 MTU 1400，USB 网卡是 1500。已对经过这块网卡的 TCP SYN 做 MSS 钳制。
- 卸载会停进程，并删掉 `pref 21000`、`192.168.77.0/24` 的路由和伪装、USB 网卡上的转发和 53 端口规则，以及从这块网卡出去的 IPv6 `/128`。整机 `ACCEPT` 策略保持不动，因为脚本不知道安装前的值。
- `AUTO_USB=1` 会改变 USB 功能。只用 U 盘模式传文件时，把它设成 `0`。
- 巡检在那台 POCO F5 上大约占单核百分之几。数据包不进用户态程序。
- RNDIS 数据通道有时会断，而 `sys.usb.state` 仍显示 `rndis,adb`。载波连续 15 秒为 0 时，脚本会重新 `svc usb setFunctions rndis`，并有 20 秒冷却。载波正常时不会动 USB。
- 日志超过 256KB 时改名为 `br77.log.1`，只留一份旧日志。

## 许可

MIT，见 `LICENSE`。
