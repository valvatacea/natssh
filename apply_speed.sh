#!/bin/bash
# Apply NATSSH per-CDN (Cloudflare vs CloudFront) speed limit via tc flower (by IP range).
CONF=/root/natssh/speed.conf
[ -f "$CONF" ] || exit 0
source "$CONF"
IFACE=${IFACE:-eth0}
UP_CF=${UP_CF:-4mbit}
DOWN_CF=${DOWN_CF:-4mbit}
UP_CFRONT=${UP_CFRONT:-4mbit}
DOWN_CFRONT=${DOWN_CFRONT:-4mbit}

# fetch IP ranges
CF_IPS=$(curl -fsSL https://www.cloudflare.com/ips-v4 2>/dev/null)
CFRONT_IPS=$(curl -fsSL https://ip-ranges.amazonaws.com/ip-ranges.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(p['ip_prefix'] for p in d['prefixes'] if p.get('service')=='CLOUDFRONT'))")

# cleanup
tc qdisc del dev $IFACE root 2>/dev/null
tc qdisc del dev $IFACE ingress 2>/dev/null
ip link set dev ifb0 down 2>/dev/null
ip link del ifb0 2>/dev/null

# egress qdisc
tc qdisc add dev $IFACE root handle 1: htb default 30 r2q 1000
tc class add dev $IFACE parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
tc class add dev $IFACE parent 1:1 classid 1:10 htb rate $UP_CF ceil $UP_CF prio 1 burst 32k
tc class add dev $IFACE parent 1:1 classid 1:20 htb rate $UP_CFRONT ceil $UP_CFRONT prio 1 burst 32k
tc class add dev $IFACE parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit prio 2
tc qdisc add dev $IFACE parent 1:10 handle 10: fq_codel
tc qdisc add dev $IFACE parent 1:20 handle 20: fq_codel
tc qdisc add dev $IFACE parent 1:30 handle 30: fq_codel

# egress filters by dst_ip (server -> CDN)
for ip in $CF_IPS; do
    tc filter add dev $IFACE protocol ip parent 1: flower dst_ip $ip action classid 1:10 2>/dev/null
done
for ip in $CFRONT_IPS; do
    tc filter add dev $IFACE protocol ip parent 1: flower dst_ip $ip action classid 1:20 2>/dev/null
done

# ifb device must exist before redirect
modprobe ifb 2>/dev/null
ip link show ifb0 >/dev/null 2>&1 || ip link add ifb0 type ifb 2>/dev/null
ip link set dev ifb0 up 2>/dev/null

# ingress qdisc + redirect
tc qdisc add dev $IFACE ingress handle ffff:
for ip in $CF_IPS; do
    tc filter add dev $IFACE parent ffff: protocol ip flower src_ip $ip action mirred egress redirect dev ifb0 2>/dev/null
done
for ip in $CFRONT_IPS; do
    tc filter add dev $IFACE parent ffff: protocol ip flower src_ip $ip action mirred egress redirect dev ifb0 2>/dev/null
done

# ifb qdisc
tc qdisc add dev ifb0 root handle 1: htb default 30 r2q 1000
tc class add dev ifb0 parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
tc class add dev ifb0 parent 1:1 classid 1:10 htb rate $DOWN_CF ceil $DOWN_CF prio 1 burst 32k
tc class add dev ifb0 parent 1:1 classid 1:20 htb rate $DOWN_CFRONT ceil $DOWN_CFRONT prio 1 burst 32k
tc class add dev ifb0 parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit prio 2
tc qdisc add dev ifb0 parent 1:10 handle 10: fq_codel
tc qdisc add dev ifb0 parent 1:20 handle 20: fq_codel
tc qdisc add dev ifb0 parent 1:30 handle 30: fq_codel

# ifb filters by src_ip (preserved after redirect)
for ip in $CF_IPS; do
    tc filter add dev ifb0 protocol ip parent 1: flower src_ip $ip action classid 1:10 2>/dev/null
done
for ip in $CFRONT_IPS; do
    tc filter add dev ifb0 protocol ip parent 1: flower src_ip $ip action classid 1:20 2>/dev/null
done
