# 以下变量需按要求填写
IFNAME=			# 指定接口，可留空；仅在多 WAN 时需要；拨号接口的格式为 "pppoe-wancm"
GWLADDR=192.168.8.1	# 主路由 LAN 的 IPv4 地址
APPADDR=192.168.8.168	# 下载设备的 IPv4 地址，允许主路由或旁路由本身运行 BT 应用
APPPORT=12345		# BT 应用程序的监听端口，HTTP 改包要求 5 位数端口

WANADDR=$1
WANPORT=$2
LANPORT=$4
L4PROTO=$5
OWNADDR=$6

OWNNAME=$(echo $0 | awk -F / '{print$NF}' | awk -F . '{print$1}' | sed 's/[[:punct:]]/_/g')
RELEASE=$(grep ^ID= /etc/os-release | awk -F '=' '{print$2}' | tr -d \")
STUNIFO=/tmp/$OWNNAME.info
OLDPORT=$(grep $L4PROTO $STUNIFO 2>/dev/null | awk -F ':| ' '{print$6}')

# 判断 TCP 或 UDP 的穿透是否启用
# 清理穿透信息中没有运行的协议
touch $STUNIFO
case $RELEASE in
	openwrt)
		for SECTION in $(uci show natmap | grep $0 | awk -F . '{print$2}'); do
			if [ "$(uci -q get natmap.$SECTION.enable)" = 1 ]; then
				case $(uci get natmap.$SECTION.udp_mode) in
					0) SECTTCP=$SECTION ;;
					1) SECTUDP=$SECTION ;;
				esac
			fi
		done
		[ $(uci -q get natmap.$SECTTCP) ] || ( \
		DISPORT="$(grep tcp $STUNIFO | awk -F ':| ' '{print$6}') tcp"; sed -i '/'tcp'/d' $STUNIFO )
		[ $(uci -q get natmap.$SECTUDP) ] || ( \
		DISPORT="$(grep udp $STUNIFO | awk -F ':| ' '{print$6}') udp"; sed -i '/'udp'/d' $STUNIFO )
		;;
	*)
		ps aux | grep $0 | grep "\-h" || ( \
		DISPORT="$(grep tcp $STUNIFO | awk -F ':| ' '{print$6}') tcp"; sed -i '/'tcp'/d' $STUNIFO )
		ps aux | grep $0 | grep "\-u" || ( \
		DISPORT="$(grep udp $STUNIFO | awk -F ':| ' '{print$6}') udp"; sed -i '/'udp'/d' $STUNIFO )
		;;
esac

# 更新保存穿透信息
sed -i '/'$L4PROTO'/d' $STUNIFO 2>/dev/null
echo $L4PROTO $WANADDR:$WANPORT '->' $OWNADDR:$LANPORT '->' $APPADDR:$APPPORT $(date +%s) >>$STUNIFO
echo $(date) $L4PROTO $WANADDR:$WANPORT '->' $OWNADDR:$LANPORT '->' $APPADDR:$APPPORT >>/tmp/$OWNNAME.log

# 防止脚本同时操作 nftables 导致冲突
[ $L4PROTO = udp ] && sleep 1 && \
[ $(($(date +%s) - $(grep tcp $STUNIFO | awk '{print$NF}'))) -lt 3 ] && sleep 3

# 初始化 nftables
nft add table ip STUN
nft add chain ip STUN BTTR { type filter hook postrouting priority filter \; }
nft flush chain ip STUN BTTR
WANTCP=$(grep tcp $STUNIFO | awk -F ':| ' '{print$3}')
WANUDP=$(grep udp $STUNIFO | awk -F ':| ' '{print$3}')
if [ -n "$IFNAME" ]; then
	IIFNAME="iifname $IFNAME"
	OIFNAME="oifname $IFNAME"
fi

# HTTP Tracker
STRAPP=0x706f72743d$(printf $APPPORT | xxd -p)
STRTCP=0x3d$(printf 30$(printf "$WANTCP" | xxd -p) | tail -c 10)
STRUDP=0x3d$(printf 30$(printf "$WANUDP" | xxd -p) | tail -c 10)
if [ -n "$WANTCP" ] && [ -n "$WANUDP" ]; then
	SETSTR="numgen inc mod 2 map { 0 : $STRTCP, 1 : $STRUDP }"
elif [ -n "$WANTCP" ]; then
	SETSTR=$STRTCP
elif [ -n "$WANUDP" ]; then
	SETSTR=$STRUDP
fi
nft add set ip STUN BTTR_HTTP "{ type ipv4_addr . inet_service; flags dynamic; timeout 1h; }"
nft add chain ip STUN BTTR_HTTP
nft insert rule ip STUN BTTR ip daddr . tcp dport @BTTR_HTTP goto BTTR_HTTP
nft add rule ip STUN BTTR meta l4proto tcp @ih,0,112 0x474554202f616e6e6f756e63653f add @BTTR_HTTP { ip daddr . tcp dport } goto BTTR_HTTP
for HANDLE in $(nft -a list chain ip STUN BTTR_HTTP | grep \"$OWNNAME\" | awk '{print$NF}'); do
	nft delete rule ip STUN BTTR_HTTP handle $HANDLE
done
for OFFSET in $(seq 768 16 1056); do
	nft insert rule ip STUN BTTR_HTTP $OIFNAME ip saddr $APPADDR @ih,$OFFSET,80 $STRAPP @ih,$(($OFFSET+32)),48 set $SETSTR update @BTTR_HTTP { ip daddr . tcp dport } counter accept comment "$OWNNAME"
done

# UDP Tracker
if [ -n "$WANTCP" ] && [ -n "$WANUDP" ]; then
	SETNUM="numgen inc mod 2 map { 0 : $WANTCP, 1 : $WANUDP }"
elif [ -n "$WANTCP" ]; then
	SETNUM=$WANTCP
elif [ -n "$WANUDP" ]; then
	SETNUM=$WANUDP
fi
nft add set ip STUN BTTR_UDP "{ type ipv4_addr . inet_service; flags dynamic; timeout 1h; }"
nft add chain ip STUN BTTR_UDP
nft insert rule ip STUN BTTR ip daddr . udp dport @BTTR_UDP goto BTTR_UDP
nft add rule ip STUN BTTR meta l4proto udp @ih,0,64 0x41727101980 @ih,64,32 0 add @BTTR_UDP { ip daddr . udp dport } goto BTTR_UDP
nft delete rule ip STUN BTTR_UDP handle $(nft -a list chain ip STUN BTTR_UDP 2>/dev/null | grep \"$OWNNAME\" | awk '{print$NF}') 2>/dev/null
nft insert rule ip STUN BTTR_UDP $OIFNAME ip saddr $APPADDR @ih,64,32 1 @ih,768,16 $APPPORT @ih,768,16 set $SETNUM update @BTTR_UDP { ip daddr . udp dport } counter accept comment "$OWNNAME"

# Tracker 流量需绕过软件加速
if uci show firewall 2>&1 | grep "flow_offloading='1'" >/dev/null; then
	CTMARK=$RANDOM
	nft add chain ip STUN BTTR_NOFT { type filter hook forward priority filter - 5 \; }
	nft delete rule ip STUN BTTR_NOFT handle $(nft -a list chain ip STUN BTTR_NOFT 2>/dev/null | grep \"$OWNNAME\" | grep '@BTTR_HTTP' | awk '{print$NF}') 2>/dev/null
	nft delete rule ip STUN BTTR_NOFT handle $(nft -a list chain ip STUN BTTR_NOFT 2>/dev/null | grep \"$OWNNAME\" | grep '@BTTR_UDP' | awk '{print$NF}') 2>/dev/null
	nft add rule ip STUN BTTR_NOFT $OIFNAME ip saddr $APPADDR ip daddr . tcp dport @BTTR_HTTP counter ct mark set $CTMARK comment "$OWNNAME"
	nft add rule ip STUN BTTR_NOFT $OIFNAME ip saddr $APPADDR ip daddr . udp dport @BTTR_UDP counter ct mark set $CTMARK comment "$OWNNAME"
cat >/tmp/${OWNNAME}_noft.sh <<EOF
uci show firewall 2>&1 | grep "flow_offloading='1'" >/dev/null || exit
nft insert rule inet fw4 forward $OIFNAME ip saddr $APPADDR tcp flags { syn, ack } accept comment "$OWNNAME"
nft insert rule inet fw4 forward ct mark $CTMARK counter accept comment "$OWNNAME"
EOF
	uci set firewall.${OWNNAME}_noft=include
	uci set firewall.${OWNNAME}_noft.path=/tmp/${OWNNAME}_noft.sh
	uci commit firewall
	fw4 -q reload
else
	nft delete chain ip STUN BTTR_NOFT 2>/dev/null
	rm /tmp/*_noft.sh 2>/dev/null
	for SECTION in $(uci show firewall | grep _noft= | awk -F = '{print$1}'); do
		uci -q delete $SECTION
		uci commit firewall
	done
fi

# 判断脚本运行的环境，选择 DNAT 方式
# 先排除需要 UPnP 的情况
DNAT=0
for LANADDR in $(ip -4 a show dev br-lan | grep inet | awk '{print$2}' | awk -F '/' '{print$1}'); do
	[ $DNAT = 1 ] && break
	[ "$LANADDR" = $GWLADDR ] && DNAT=1
done
for LANADDR in $(nslookup -type=A $HOSTNAME | grep Address | grep -v :53 | awk '{print$2}'); do
	[ $DNAT = 1 ] && break
	[ "$LANADDR" = $GWLADDR ] && DNAT=1
done
[ $APPADDR = $GWLADDR ] && DNAT=2

# 若未排除，则尝试直连 UPnP
if [ $DNAT = 0 ]; then
	[ -n "$OLDPORT" ] && upnpc -i -d $OLDPORT $L4PROTO
	[ -n "$DISPORT" ] && upnpc -i -d $DISPORT
	upnpc -i -e "STUN BT $L4PROTO $WANPORT->$LANPORT->$APPPORT" -a $APPADDR $APPPORT $LANPORT $L4PROTO | \
	grep $APPADDR | grep $APPPORT | grep $LANPORT | grep -v failed
	[ $? = 0 ] && DNAT=3
fi

# 直连失败，则尝试代理 UPnP
if [ $DNAT = 0 ]; then
	PROXYCONF=/tmp/proxychains.conf
	echo [ProxyList] >$PROXYCONF
	echo http $APPADDR 3128 >>$PROXYCONF
	[ -n "$OLDPORT" ] && proxychains -f $PROXYCONF upnpc -i -d $OLDPORT $L4PROTO
	[ -n "$DISPORT" ] && proxychains -f $PROXYCONF upnpc -i -d $DISPORT
	proxychains -f $PROXYCONF \
	upnpc -i -e "STUN BT $L4PROTO $WANPORT->$LANPORT->$APPPORT" -a $APPADDR $APPPORT $LANPORT $L4PROTO | \
	grep $APPADDR | grep $APPPORT | grep $LANPORT | grep -v failed
	[ $? = 0 ] && DNAT=3
fi

# 代理失败，则启用本机 UPnP
[ $DNAT = 0 ] && (upnpc -i -e "STUN BT $L4PROTO $WANPORT->$LANPORT" -a @ $LANPORT $LANPORT $L4PROTO; DNAT=4)

# 清理不需要的规则
if [ $DNAT = 3 ]; then
	nft delete rule ip STUN DNAT handle $(nft -a list chain ip STUN DNAT 2>/dev/null | grep \"$OWNNAME\" | grep tcp | awk '{print$NF}') 2>/dev/null
	nft delete rule ip STUN DNAT handle $(nft -a list chain ip STUN DNAT 2>/dev/null | grep \"$OWNNAME\" | grep udp | awk '{print$NF}') 2>/dev/null
fi
if [ $DNAT != 3 ]; then
	[ -z "$WANTCP" ] && \
	nft delete rule ip STUN DNAT handle $(nft -a list chain ip STUN DNAT 2>/dev/null | grep \"$OWNNAME\" | grep tcp | awk '{print$NF}') 2>/dev/null
	[ -z "$WANUDP" ] && \
	nft delete rule ip STUN DNAT handle $(nft -a list chain ip STUN DNAT 2>/dev/null | grep \"$OWNNAME\" | grep udp | awk '{print$NF}') 2>/dev/null
fi

# 初始化 DNAT
SETDNAT() {
	nft add chain ip STUN DNAT { type nat hook prerouting priority dstnat \; }
	nft delete rule ip STUN DNAT handle $(nft -a list chain ip STUN DNAT 2>/dev/null | grep \"$OWNNAME\" | grep $L4PROTO | awk '{print$NF}') 2>/dev/null
	if [ "$RELEASE" = "openwrt" ]; then
		uci -q delete firewall.stun_foo
		if uci show firewall | grep =redirect >/dev/null; then
			i=0
			for CONFIG in $(uci show firewall | grep =redirect | awk -F = '{print$1}'); do
				[ "$(uci -q get $CONFIG.enabled)" = 0 ] && let i++ && break
				[ "$(uci -q get $CONFIG.src)" != "wan" ] && let i++
			done
			[ $(uci show firewall | grep =redirect | wc -l) -gt $i ] && RULE=1
		fi
		if [ "$RULE" != 1 ]; then
			uci set firewall.stun_foo=redirect
			uci set firewall.stun_foo.name=stun_foo
			uci set firewall.stun_foo.src=wan
			uci set firewall.stun_foo.mark=$RANDOM
			RELOAD=1
		fi
		uci commit firewall
		[ "$RELOAD" = 1 ] && fw4 -q reload
	fi
}

# BT 应用运行在路由器下，使用 dnat
[ $DNAT = 1 ] || [ $DNAT = 4 ] && ( \
	SETDNAT
	nft insert rule ip STUN DNAT $IIFNAME $L4PROTO dport $LANPORT counter dnat ip to $APPADDR:$APPPORT comment "$OWNNAME"
)

# BT 应用运行在路由器上，使用 redirect
[ $DNAT = 2 ] && ( \
	SETDNAT
	nft insert rule ip STUN DNAT $IIFNAME $L4PROTO dport $LANPORT counter redirect to :$APPPORT comment "$OWNNAME"
)

case $DNAT in
	1) METHOD='nft dnat'
 	2) METHOD='nft redirect'
  	3) METHOD='UPnP dnat'
   	4) METHOD='UPnP redirect'
esac

echo -n nftables OK. $METHOD to $APPADDR:$APPPORT$([ -n "$IFNAME" ] && echo @$IFNAME)
