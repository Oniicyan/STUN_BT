# 介绍

Linux（特别是 OpenWrt，包括 WSL2）下通过 [NATMap](https://github.com/heiher/natmap) 进行内网穿透后，调用通知脚本对 BT 软件向 HTTP / UDP Tracker 汇报的端口进行修改

基于 BT 协议，利用 nftables 对数据包进行修改，不需要下载设备与 BT 软件的支持

支持在主路由及旁路由（包括 WSL2 旁路由）上运行，支持 TCP + UDP，支持多 WAN

需要安装 `xxd`

~~[NATMap 脚本使用教程](https://www.bilibili.com/read/cv35874617/)~~（内容已过时）

~~[Lucky 脚本使用教程](https://www.bilibili.com/read/cv35917659/)~~（内容已过时）

~~[详细说明](https://www.bilibili.com/read/cv34755793/)~~（内容已过时）

---

nftables 版本低于 1.0.1 时，需要把 `@ih` 改为 `@th`

对于 TCP，将偏移量 `+160`

对于 UDP，将偏移量 `+64`

Lucky 脚本使用 `@th`

# 准备工作

## 端口映射

本脚本不再自动配置端口映射，请手动操作

建议使用路由器的端口映射（或叫“**虚拟服务器**”），本文档示例使用 **OpenWrt**

### OpenWrt

![图片](https://github.com/user-attachments/assets/3378a39f-1056-4430-bcfe-8a5bd63d334f)

* `地址族限制`：`仅 IPv4`

  仅针对 IPv4 进行穿透，并非所有路由器都有此选项

* `协议`：`TCP UDP`

  根据实际修改，但一般选择 `TCP UDP` 即可

* `外部端口`：`61127`

  对应 **NATMap** 中的 **绑定端口** 或 **Lucky** 中的 **穿透通道本地端口**

* `内部 IP 地址`

  BT 应用程序的 IPv4 地址；BT 应用运行在路由器上时，请正确区分所用的地址

* `内部端口`：`61128`

  BT 应用程序的监听端口，HTTP 改包要求 5 位数端口

大多数情况下，外部端口与内部端口允许一致

**但在路由器上运行 BT 应用程序时，建议穿透端口与监听端口设为不同值**

---

**OpenWrt** 上配置端口映射时，`目标区域` 与 `内部 IP 地址` 留空则代表路由器自身

![图片](https://github.com/user-attachments/assets/37d19f6b-0a30-48a2-9bf7-2f07a0d339b8)

保存后如下

![图片](https://github.com/user-attachments/assets/d48b89ae-1af8-4b39-a654-3a52d0d9da9f)

---

### nftables / iptables

在需要指定网络接口，或需要在其他 Linux 发行版上配置端口映射时，可使用 `nft` 或 `iptables`

* nftables
  
```
# 创建 table 与 chain
nft add table ip STUN
nft add chain ip STUN DNAT { type nat hook prerouting priority dstnat \; }
# 转发至其他设备，使用 dnat
nft insert rule ip STUN DNAT iifname pppoe-wancm tcp dport 61127 counter dnat to 192.168.1.168:61128 comment stun_bt
# 转发至本设备，使用 redirect
nft insert rule ip STUN DNAT iifname pppoe-wancm tcp dport 61127 counter redirect to :61128 comment stun_bt
```

* iptables

```
# 转发至其他设备，使用 DNAT
iptables -t nat -I PREROUTING -i pppoe-wancm -p tcp --dport 61127 -m comment --comment stun_bt -j DNAT --to-destination 192.168.1.168:61128
# 转发至本设备，使用 REDIRECT
iptables -t nat -I PREROUTING -i pppoe-wancm -p tcp --dport 61127 -m comment --comment stun_bt -j REDIRECT --to-ports 61128
```

### 用户态转发

建议仅在无法对路由器配置端口映射时，才使用 Lucky 或其他用户态端口转发工具

使用用户态转发时，外部发起连接的源地址会变成网关的地址

## 安装软件

本脚本以 nftables 为核心

对于 OpenWrt，建议使用 22.03 及以上使用 firewall4 的固件

旧版 OpenWrt 固件也可手动安装 nftables，但不保证运行效果

对于其他 Linux 发行版，通常可自行安装 nftables

但需要注意，若 nftables 版本太旧，可能无法正常运行（OpenWrt 同样）

---

除 nftables 外，本脚本需要安装的软件仅为 `xxd`

在进行配置时，本文档使用 `curl` 下载脚本

穿透工具使用 `NATMap` 或 `Lucky`

### OpenWrt

```
# 可选替换国内软件源
# sed -i 's_downloads.openwrt.org_mirrors.tuna.tsinghua.edu.cn/openwrt_' /etc/opkg/distfeeds.conf
opkg update
opkg install xxd curl luci-app-natmap
```

### Debian
```
apt update
apt install xxd curl
```

NATMap 需手动安装，注意指令集架构

```
curl -Lo /usr/bin/natmap https://github.com/heiher/natmap/releases/download/20240813/natmap-linux-x86_64
chmod +x /usr/bin/natmap
```

---

Lucky 的安装方法请参照 [官网文档](https://lucky666.cn/docs/install)

# 配置方法

## NATMap

### 配置脚本

把脚本下载到本地，赋予执行权限并编辑变量

```
curl -Lso /usr/stun_bt_natmap.sh stun-bt.pages.dev/natmap
# 如下载失败，请使用国内镜像
# curl -Lso /usr/stun_bt_natmap.sh https://gitee.com/oniicyan/stun_bt/raw/master/stun_bt_natmap.sh
chmod +x /usr/stun_bt_natmap.sh
vi /usr/stun_bt_natmap.sh
```

```
# 以下变量需按要求填写
IFNAME=                # 指定接口，可留空；仅在多 WAN 时需要；拨号接口的格式为 "pppoe-wancm"
APPADDR=192.168.1.168  # BT 应用程序的 IPv4 地址；BT 应用运行在路由器上时，请正确区分所用的地址
APPPORT=61128          # BT 应用程序的监听端口，HTTP 改包要求 5 位数端口
```

### 配置 OpenWrt

仅示例 TCP，如需穿透 UDP 请自行修改

![图片](https://github.com/user-attachments/assets/e5a1cd17-8861-42c6-af31-5a53cf0ce8b7)

或可编辑配置文件 `vi /etc/config/natmap`

**注意实际的接口名称**

**如要屏蔽日志输出，需编辑配置文件**

```
config natmap
	option udp_mode '0'
	option family 'ipv4'
	option interval '25'
	option stun_server 'turn.cloudflare.com'
	option http_server 'qq.com'
	option port '61127'
	option notify_script '/usr/stun_bt_natmap.sh'
	option log_stdout '0'
	option log_stderr '0'
	option enable '1'
```

### 配置 Debian

TCP

`natmap -d -4 -k 25 -s turn.cloudflare.com -h qq.com -e "/usr/stun_bt_natmap.sh"`

UDP

`natmap -d -4 -k 25 -s turn.cloudflare.com -u -e "/usr/stun_bt_natmap.sh"`

注意请勿在 UDP 模式中指定 `-h` 参数，否则会影响一些清理操作

可添加自启动，具体方法因发行版而异

## Lucky

仅示例 TCP，如需穿透 UDP 请自行修改

![图片](https://github.com/user-attachments/assets/6b3b4f40-f89c-4371-ba6a-ccfbc4ffb6a5)

自定义脚本内容如下，请正确编辑变量内容

```
IFNAME=                # 指定接口，默认留空；仅在多 WAN 时需要；拨号接口的格式为 "pppoe-wancm"
APPADDR=192.168.1.168  # BT 应用程序的 IPv4 地址；BT 应用运行在路由器上时，请正确区分所用的地址
APPPORT=61128          # BT 应用程序的监听端口，HTTP 改包要求 5 位数端口
L4PROTO=tcp            # 小写字母 tcp 或 udp，对应上面的穿透类型

[ -e /usr/stun_bt_lucky.sh ] || curl -Lso /usr/stun_bt_lucky.sh https://gitee.com/oniicyan/stun_bt/raw/master/stun_bt_lucky.sh
sh /usr/stun_bt_lucky.sh ${ip} ${port} $L4PROT $APPADDR $APPPORT $IFNAME
```

默认使用国内镜像，脚本地址可改为 `stun-bt.pages.dev/lucky`
