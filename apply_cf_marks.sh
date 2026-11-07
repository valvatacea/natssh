#!/bin/bash
# Fetch Cloudflare + CloudFront IP ranges and mark packets (CF=1, CFront=2) via iptables mangle.
# Run daily via cron; also called by apply_speed.sh.
set -e
IPT=iptables
# IPv4 only for tc/mark; IPv6 optional
CF_IPS=$(curl -fsSL https://www.cloudflare.com/ips-v4 2>/dev/null)
CFRONT_IPS=$(curl -fsSL https://ip-ranges.amazonaws.com/ip-ranges.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(p['ip_prefix'] for p in d['prefixes'] if p.get('service')=='CLOUDFRONT'))")

# flush old marks
$IPT -t mangle -F PREROUTING 2>/dev/null || true

# mark Cloudflare
for ip in $CF_IPS; do
    $IPT -t mangle -A PREROUTING -s $ip -j MARK --set-mark 1 2>/dev/null || true
done
# mark CloudFront
for ip in $CFRONT_IPS; do
    $IPT -t mangle -A PREROUTING -s $ip -j MARK --set-mark 2 2>/dev/null || true
done
echo "marks applied: CF=$(echo "$CF_IPS"|wc -w) CFRONT=$(echo "$CFRONT_IPS"|wc -w)"
