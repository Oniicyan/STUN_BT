Linux（特别是 OpenWrt，包括 WSL2）下通过 [NATMap](https://github.com/heiher/natmap) 进行内网穿透后，调用通知脚本对 BT 软件向 HTTP / UDP Tracker 汇报的端口进行修改

基于 BT 协议，利用 nftables 对数据包进行修改，不需要下载设备与 BT 软件的支持

支持在主路由及旁路由（包括 WSL2 旁路由）上运行，支持 TCP + UDP，支持多 WAN（需自行修改脚本路径）

运行在主路由时通过 nftables 进行端口映射

运行在旁路由时通过 UPnP 请求映射规则，因此要求主路由开启 UPnP

需要安装 xxd，运行在旁路由时需要安装 miniupnpc

主路由 UPnP 开启安全模式时，需要安装 proxychains (proxychains-ng/proxychains4)，并在下载设备上启用代理服务器，推荐 [3proxy](https://3proxy.ru/) 或 [GOST](https://gost.run/)

　

nftables 版本低于 1.0.1 时，需要把 `@ih` 改为 `@th`

对于 TCP，将偏移量 `+160`

对于 UDP，将偏移量 `+64`

Lucky 脚本已适配 @th

　

[详细说明](https://www.bilibili.com/read/cv34755793/)

[Lucky 脚本使用教程](https://www.bilibili.com/read/cv35917659/)
