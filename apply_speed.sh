#!/bin/bash
# Apply NATSSH SSH speed limit from /root/natssh/speed.conf (survives reboot)
CONF=/root/natssh/speed.conf
[ -f "$CONF" ] || exit 0
source "$CONF"
IFACE=${IFACE:-eth0}
[ -z "$UP" ] && [ -z "$DOWN" ] && exit 0

# cleanup
tc qdisc del dev $IFACE root 2>/dev/null
tc qdisc del dev $IFACE ingress 2>/dev/null
ip link set dev ifb0 down 2>/dev/null
ip link del ifb0 2>/dev/null

if [ -n "$UP" ]; then
    tc qdisc add dev $IFACE root handle 1: htb default 30
    tc class add dev $IFACE parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
    tc class add dev $IFACE parent 1:1 classid 1:10 htb rate $UP ceil $UP prio 1 burst 32k
    tc class add dev $IFACE parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit prio 2
    tc qdisc add dev $IFACE parent 1:10 handle 10: fq_codel
    tc qdisc add dev $IFACE parent 1:30 handle 30: fq_codel
    tc filter add dev $IFACE parent 1: protocol ip prio 1 u32 match ip sport 22 0xffff flowid 1:10 2>/dev/null
    tc filter add dev $IFACE parent 1: protocol ip prio 1 u32 match ip dport 22 0xffff flowid 1:10 2>/dev/null
fi
if [ -n "$DOWN" ]; then
    modprobe ifb 2>/dev/null
    ip link show ifb0 >/dev/null 2>&1 || ip link add ifb0 type ifb 2>/dev/null
    ip link set dev ifb0 up 2>/dev/null
    tc qdisc add dev $IFACE ingress handle ffff:
    tc filter add dev $IFACE parent ffff: protocol ip prio 1 u32 match ip dport 22 0xffff action mirred egress redirect dev ifb0 2>/dev/null
    tc qdisc add dev ifb0 root handle 1: htb default 30
    tc class add dev ifb0 parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
    tc class add dev ifb0 parent 1:1 classid 1:10 htb rate $DOWN ceil $DOWN prio 1 burst 32k
    tc class add dev ifb0 parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit prio 2
    tc qdisc add dev ifb0 parent 1:10 handle 10: fq_codel
    tc qdisc add dev ifb0 parent 1:30 handle 30: fq_codel
    tc filter add dev ifb0 parent 1: protocol ip prio 1 u32 match ip sport 22 0xffff flowid 1:10 2>/dev/null
fi
