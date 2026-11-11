#!/bin/bash
# Apply NATSSH per-CDN (Cloudflare vs CloudFront) speed limit via tc flower (by IP range).
# Modified: fetch only if internet available, skip if IPs unchanged.

CONF=/root/natssh/config/speed.conf
[ -f "$CONF" ] || exit 0
source "$CONF"
IFACE=${IFACE:-eth0}
UP_CF=${UP_CF:-1000mbit}
DOWN_CF=${DOWN_CF:-1000mbit}
UP_CFRONT=${UP_CFRONT:-1000mbit}
DOWN_CFRONT=${DOWN_CFRONT:-1000mbit}

CF_CACHE=/root/natssh/config/cf_ips.cache
CFRONT_CACHE=/root/natssh/config/cfront_ips.cache
TMP_CF=/root/natssh/.cf_ips.new
TMP_CFRONT=/root/natssh/.cfront_ips.new

# Cleanup temp files on exit
trap 'rm -f "$TMP_CF" "$TMP_CFRONT"' EXIT

# --- Check internet connectivity ---
INET_OK=0
if curl -fsSL --connect-timeout 5 --max-time 10 https://www.cloudflare.com/ips-v4 >/dev/null 2>&1; then
    INET_OK=1
fi

# --- Fetch CF IPs (only if internet available) ---
if [ "$INET_OK" -eq 1 ]; then
    curl -fsSL --connect-timeout 5 --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null > "$TMP_CF"
    [ -s "$TMP_CF" ] || rm -f "$TMP_CF"
fi

# --- Fetch CloudFront IPs (only if internet available) ---
if [ "$INET_OK" -eq 1 ]; then
    curl -fsSL --connect-timeout 5 --max-time 15 https://ip-ranges.amazonaws.com/ip-ranges.json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('\n'.join(p['ip_prefix'] for p in d['prefixes'] if p.get('service')=='CLOUDFRONT'))
except:
    pass
" > "$TMP_CFRONT" 2>/dev/null
    [ -s "$TMP_CFRONT" ] || rm -f "$TMP_CFRONT"
fi

# --- Determine if IPs changed ---
CF_CHANGED=0
CFRONT_CHANGED=0

if [ -f "$TMP_CF" ]; then
    if ! diff -q "$TMP_CF" "$CF_CACHE" >/dev/null 2>&1; then
        CF_CHANGED=1
    fi
fi

if [ -f "$TMP_CFRONT" ]; then
    if ! diff -q "$TMP_CFRONT" "$CFRONT_CACHE" >/dev/null 2>&1; then
        CFRONT_CHANGED=1
    fi
fi

# --- Check if tc is already configured (htb qdisc) ---
TC_CONFIGURED=0
if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q 'htb'; then
    TC_CONFIGURED=1
fi

# --- Skip conditions ---
# 1. No internet, no new data, tc already configured → skip
if [ "$INET_OK" -eq 0 ] && [ "$TC_CONFIGURED" -eq 1 ] && [ ! -f "$TMP_CF" ] && [ ! -f "$TMP_CFRONT" ]; then
    exit 0
fi

# 2. Internet available, IPs unchanged, tc already configured → skip
if [ "$INET_OK" -eq 1 ] && [ "$CF_CHANGED" -eq 0 ] && [ "$CFRONT_CHANGED" -eq 0 ] && [ "$TC_CONFIGURED" -eq 1 ] && [ ! -f "$TMP_CF" ] && [ ! -f "$TMP_CFRONT" ]; then
    exit 0
fi

# 3. No internet and no cache → nothing to do
if [ "$INET_OK" -eq 0 ] && [ ! -f "$CF_CACHE" ] && [ ! -f "$CFRONT_CACHE" ]; then
    exit 0
fi

# --- Update cache if new IPs fetched ---
[ -f "$TMP_CF" ] && mv "$TMP_CF" "$CF_CACHE"
[ -f "$TMP_CFRONT" ] && mv "$TMP_CFRONT" "$CFRONT_CACHE"

# --- Load IPs from cache ---
CF_IPS=$(cat "$CF_CACHE" 2>/dev/null)
CFRONT_IPS=$(cat "$CFRONT_CACHE" 2>/dev/null)

# --- Re-apply tc (rest of original script) ---
# cleanup ingress + ifb0 (root qdisc akan di-replace, tidak perlu del)
tc qdisc del dev $IFACE ingress 2>/dev/null
ip link set dev ifb0 down 2>/dev/null
ip link del ifb0 2>/dev/null

# egress qdisc (replace = atomik, tidak ada gap)
tc qdisc replace dev $IFACE root handle 1: htb default 30 r2q 1000
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
tc qdisc replace dev ifb0 root handle 1: htb default 30 r2q 1000
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
