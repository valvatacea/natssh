#!/bin/bash
# Apply NATSSH per-CDN (Cloudflare vs CloudFront) speed limit via iptables mark + tc fwmark.
CONF=/root/natssh/speed.conf
[ -f "$CONF" ] || exit 0
source "$CONF"
IFACE=${IFACE:-eth0}
MODE=${MODE:-cdn-split}

# refresh IP marks
/root/natssh/apply_cf_marks.sh >/dev/null 2>&1

# defaults
UP_CF=${UP_CF:-4mbit}
DOWN_CF=${DOWN_CF:-4mbit}
UP_CFRONT=${UP_CFRONT:-4mbit}
DOWN_CFRONT=${DOWN_CFRONT:-4mbit}

# cleanup
tc qdisc del dev $IFACE root 2>/dev/null
tc qdisc del dev $IFACE ingress 2>/dev/null
ip link set dev ifb0 down 2>/dev/null
ip link del ifb0 2>/dev/null

# egress: two classes
tc qdisc add dev $IFACE root handle 1: htb default 30
tc class add dev $IFACE parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
tc class add dev $IFACE parent 1:1 classid 1:10 htb rate $UP_CF ceil $UP_CF prio 1 burst 32k
tc class add dev $IFACE parent 1:1 classid 1:20 htb rate $UP_CFRONT ceil $UP_CFRONT prio 1 burst 32k
tc class add dev $IFACE parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit prio 2
tc qdisc add dev $IFACE parent 1:10 handle 10: fq_codel
tc qdisc add dev $IFACE parent 1:20 handle 20: fq_codel
tc qdisc add dev $IFACE parent 1:30 handle 30: fq_codel
tc filter add dev $IFACE parent 1: protocol ip prio 1 handle 1 fw flowid 1:10
tc filter add dev $IFACE parent 1: protocol ip prio 2 handle 2 fw flowid 1:20

# ingress: ifb with two classes
modprobe ifb 2>/dev/null
ip link show ifb0 >/dev/null 2>&1 || ip link add ifb0 type ifb 2>/dev/null
ip link set dev ifb0 up 2>/dev/null
tc qdisc add dev $IFACE ingress handle ffff:
tc filter add dev $IFACE parent ffff: protocol ip prio 1 handle 1 fw action mirred egress redirect dev ifb0 2>/dev/null
tc filter add dev $IFACE parent ffff: protocol ip prio 2 handle 2 fw action mirred egress redirect dev ifb0 2>/dev/null
tc qdisc add dev ifb0 root handle 1: htb default 30
tc class add dev ifb0 parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
tc class add dev ifb0 parent 1:1 classid 1:10 htb rate $DOWN_CF ceil $DOWN_CF prio 1 burst 32k
tc class add dev ifb0 parent 1:1 classid 1:20 htb rate $DOWN_CFRONT ceil $DOWN_CFRONT prio 1 burst 32k
tc class add dev ifb0 parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit prio 2
tc qdisc add dev ifb0 parent 1:10 handle 10: fq_codel
tc qdisc add dev ifb0 parent 1:20 handle 20: fq_codel
tc qdisc add dev ifb0 parent 1:30 handle 30: fq_codel
tc filter add dev ifb0 parent 1: protocol ip prio 1 handle 1 fw flowid 1:10
tc filter add dev ifb0 parent 1: protocol ip prio 2 handle 2 fw flowid 1:20
