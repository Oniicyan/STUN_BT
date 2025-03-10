# 从 Lucky 自定义命令中传递参数
IFNAME=$6	# 指定接口，默认留空；仅在多 WAN 时需要；拨号接口的格式为 "pppoe-wancm"
APPADDR=$4	# BT 应用程序的 IPv4 地址；BT 应用运行在路由器上时，请正确区分所用的地址
APPPORT=$5	# BT 应用程序的监听端口，HTTP 改包要求 5 位数端口

WANADDR=$1
WANPORT=$2
LANPORT=    # Lucky 不传递穿透通道本地端口，留空
L4PROTO=$3  # Lucky 不传递传输层协议，手动输入并传递
OWNADDR=    # Lucky 不传递穿透通道本地地址，留空

OWNNAME=$(echo stun_bt_$APPADDR:$APPPORT$([ $IFNAME ] && echo @$IFNAME) | sed 's/[[:punct:]]/_/g')
RELEASE=$(grep ^ID= /etc/os-release | awk -F '=' '{print$2}' | tr -d \")
STUNIFO=/tmp/$OWNNAME.info

# 判断 TCP 或 UDP 的穿透是否启用
# 清理穿透信息中没有运行的协议
# Lucky 下不支持，需要手动删除 /tmp/$OWNNAME.info 或重启网关
touch $STUNIFO

# 若公网端口未发生变化，则退出脚本
OLDPORT=$(grep $L4PROTO $STUNIFO | awk -F ':| ' '{print$3}')
if [ $WANPORT = "$OLDPORT" ]; then
	logger -st stun_bt The external port $WANPORT/$L4PROTO$([ $IFNAME ] && echo @$IFNAME) has not changed.
	nft list table ip STUN 2>&1 | grep $(printf '0x%x' $WANPORT) >/dev/null && exit 0
fi

# 更新保存穿透信息
sed '/'$L4PROTO'/d' -i $STUNIFO
echo $L4PROTO $WANADDR:$WANPORT '->' $([ $LANPORT ] && echo $OWNADDR:$LANPORT '->') $APPADDR:$APPPORT $(date +%s) >>$STUNIFO
echo $(date) $L4PROTO $WANADDR:$WANPORT '->' $([ $LANPORT ] && echo $OWNADDR:$LANPORT '->') $APPADDR:$APPPORT >>/tmp/$OWNNAME.log

# 防止脚本同时操作 nftables 导致冲突
[ $L4PROTO = udp ] && sleep 1 && \
[ $(($(date +%s) - $(grep tcp $STUNIFO | awk '{print$NF}'))) -lt 3 ] && sleep 3

# 初始化 nftables
nft add table ip STUN
nft add chain ip STUN BTTR { type filter hook postrouting priority filter \; }
nft flush chain ip STUN BTTR
WANTCP=$(grep tcp $STUNIFO | awk -F ':| ' '{print$3}')
WANUDP=$(grep udp $STUNIFO | awk -F ':| ' '{print$3}')
[ $IFNAME ] && OIFNAME='oifname '$IFNAME''

# HTTP Tracker
STRAPP=0x706f72743d$(printf $APPPORT | xxd -p)
STRTCP=0x3d$(printf 30$(printf "$WANTCP" | xxd -p) | tail -c 10)
STRUDP=0x3d$(printf 30$(printf "$WANUDP" | xxd -p) | tail -c 10)
if [ $WANTCP ] && [ $WANUDP ]; then
	SETSTR='numgen inc mod 2 map { 0 : '$STRTCP', 1 : '$STRUDP' }'
elif [ $WANTCP ]; then
	SETSTR=$STRTCP
elif [ $WANUDP ]; then
	SETSTR=$STRUDP
fi
nft add set ip STUN BTTR_HTTP "{ type ipv4_addr . inet_service; flags dynamic; timeout 1h; }"
nft add chain ip STUN BTTR_HTTP
nft insert rule ip STUN BTTR ip daddr . tcp dport @BTTR_HTTP goto BTTR_HTTP
nft add rule ip STUN BTTR meta l4proto tcp @th,160,112 0x474554202f616e6e6f756e63653f add @BTTR_HTTP { ip daddr . tcp dport } goto BTTR_HTTP
for HANDLE in $(nft -a list chain ip STUN BTTR_HTTP | grep \"$OWNNAME\" | awk '{print$NF}'); do
	nft delete rule ip STUN BTTR_HTTP handle $HANDLE
done
for OFFSET in $(seq 928 16 1216); do
	nft insert rule ip STUN BTTR_HTTP $OIFNAME ip saddr $APPADDR @th,$OFFSET,80 $STRAPP @th,$(($OFFSET+32)),48 set $SETSTR update @BTTR_HTTP { ip daddr . tcp dport } counter accept comment "$OWNNAME"
done

# UDP Tracker
if [ $WANTCP ] && [ $WANUDP ]; then
	SETNUM='numgen inc mod 2 map { 0 : '$WANTCP', 1 : '$WANUDP' }'
elif [ $WANTCP ]; then
	SETNUM=$WANTCP
elif [ $WANUDP ]; then
	SETNUM=$WANUDP
fi
nft add set ip STUN BTTR_UDP "{ type ipv4_addr . inet_service; flags dynamic; timeout 1h; }"
nft add chain ip STUN BTTR_UDP
nft insert rule ip STUN BTTR ip daddr . udp dport @BTTR_UDP goto BTTR_UDP
nft add rule ip STUN BTTR meta l4proto udp @th,64,64 0x41727101980 @th,128,32 0 add @BTTR_UDP { ip daddr . udp dport } goto BTTR_UDP
nft delete rule ip STUN BTTR_UDP handle $(nft -a list chain ip STUN BTTR_UDP 2>/dev/null | grep \"$OWNNAME\" | awk '{print$NF}') 2>/dev/null
nft insert rule ip STUN BTTR_UDP $OIFNAME ip saddr $APPADDR @th,128,32 1 @th,832,16 $APPPORT @th,832,16 set $SETNUM update @BTTR_UDP { ip daddr . udp dport } counter accept comment "$OWNNAME"

# Tracker 流量需绕过软件加速
# 仅检测 OpenWrt firewall4 的软件加速，其他加速请自行解决
CTMARK=0x$(echo $APPADDR | awk -F . '{print$NF}')$APPPORT
if uci show firewall 2>&1 | grep "flow_offloading='1'" >/dev/null; then
	if ! nft list chain ip STUN BTTR_NOFT 2>&1 | grep $OWNNAME >/dev/null; then
		nft add chain ip STUN BTTR_NOFT { type filter hook forward priority filter - 5 \; }
		for HANDLE in $(nft -a list chain ip STUN BTTR_NOFT 2>/dev/null | grep \"$OWNNAME\" | awk '{print$NF}'); do
			nft delete rule ip STUN BTTR_NOFT handle $HANDLE
		done
		nft add rule ip STUN BTTR_NOFT $OIFNAME ct mark $CTMARK accept
		nft add rule ip STUN BTTR_NOFT $OIFNAME ip saddr $APPADDR ip daddr . tcp dport @BTTR_HTTP counter ct mark set $CTMARK comment "$OWNNAME"
		nft add rule ip STUN BTTR_NOFT $OIFNAME ip saddr $APPADDR ip daddr . udp dport @BTTR_UDP counter ct mark set $CTMARK comment "$OWNNAME"
	fi
	if ! nft list chain inet fw4 forward | grep ${OWNNAME}_noft >/dev/null; then
		cat >/tmp/${OWNNAME}_noft.sh <<EOF
nft insert rule inet fw4 forward $OIFNAME ip saddr $APPADDR tcp flags { syn, ack } accept comment "${OWNNAME}_noft"
nft insert rule inet fw4 forward $OIFNAME ct mark $CTMARK counter accept comment "${OWNNAME}_noft"
EOF
		uci set firewall.${OWNNAME}_noft=include
		uci set firewall.${OWNNAME}_noft.path=/tmp/${OWNNAME}_noft.sh
		uci commit firewall
		fw4 -q reload >/dev/null
	fi
else
	nft delete chain ip STUN BTTR_NOFT 2>/dev/null
	rm /tmp/*_noft.sh 2>/dev/null
	for SECTION in $(uci show firewall | grep _noft= | awk -F = '{print$1}'); do
		uci -q delete $SECTION
		uci commit firewall
	done
	nft list chain inet fw4 forward | grep _noft >/dev/null && fw4 -q reload >/dev/null
fi

logger -st stun_bt $WANADDR:$WANPORT/$L4PROTO$([ $IFNAME ] && echo @$IFNAME) to $APPADDR:$APPPORT
