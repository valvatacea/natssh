#!/bin/bash
# Generate nginx geo config for CDN labeling from cache files.
# Baca cf_ips.cache dan cfront_ips.cache, tulis ke cdn_geo.conf.
# Digunakan oleh nginx directive geo untuk mengisi header X-CDN.
# Jika cache kosong/tidak ada, unduh IP range dari sumber resmi.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config"
CF_CACHE="$DIR/cf_ips.cache"
CFRONT_CACHE="$DIR/cfront_ips.cache"
CDN_GEO="$DIR/cdn_geo.conf"

# Unduh IP range Cloudflare jika cache kosong atau tidak ada
if [ ! -s "$CF_CACHE" ]; then
    echo "[*] Mengunduh IP range Cloudflare..."
    if curl -fsSL --connect-timeout 10 --max-time 30 "https://www.cloudflare.com/ips-v4" -o "$CF_CACHE.tmp" 2>/dev/null; then
        mv "$CF_CACHE.tmp" "$CF_CACHE"
        echo "cf_ips.cache diperbarui."
    else
        echo "Gagal unduh cf_ips.cache."
        rm -f "$CF_CACHE.tmp"
    fi
fi

# Unduh IP range CloudFront jika cache kosong atau tidak ada
if [ ! -s "$CFRONT_CACHE" ]; then
    echo "[*] Mengunduh IP range CloudFront..."
    if curl -fsSL --connect-timeout 10 --max-time 30 "https://ip-ranges.amazonaws.com/ip-ranges.json" -o "$CFRONT_CACHE.tmp" 2>/dev/null; then
        python3 -c "
import json
with open('$CFRONT_CACHE.tmp') as f:
    data = json.load(f)
ips = [e['ip_prefix'] for e in data.get('prefixes', []) if e.get('service') == 'CLOUDFRONT']
ips += [e['ipv6_prefix'] for e in data.get('ipv6_prefixes', []) if e.get('service') == 'CLOUDFRONT']
with open('$CFRONT_CACHE', 'w') as f:
    for ip in ips:
        f.write(ip + chr(10))
" && rm -f "$CFRONT_CACHE.tmp" && echo "cfront_ips.cache diperbarui." || {
        echo "Gagal unduh/proses cfront_ips.cache."
        rm -f "$CFRONT_CACHE.tmp"
    }
fi
fi

# Cek apakah ada setidaknya satu cache yang non-kosong
HAS_CONTENT=0
if [ -f "$CF_CACHE" ] && [ -s "$CF_CACHE" ]; then
    HAS_CONTENT=1
fi
if [ -f "$CFRONT_CACHE" ] && [ -s "$CFRONT_CACHE" ]; then
    HAS_CONTENT=1
fi

# Skip overwrite jika kedua cache kosong atau tidak ada
if [ "$HAS_CONTENT" -eq 0 ]; then
    echo "cdn_geo.conf tidak diperbarui: cache kosong atau tidak ada"
    exit 0
fi

{
    if [ -f "$CF_CACHE" ] && [ -s "$CF_CACHE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo "$ip    \"Cloudflare\";"
        done < "$CF_CACHE"
    fi
    if [ -f "$CFRONT_CACHE" ] && [ -s "$CFRONT_CACHE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo "$ip    \"CloudFront\";"
        done < "$CFRONT_CACHE"
    fi
} > "$CDN_GEO"

echo "cdn_geo.conf diperbarui: $(wc -l < "$CDN_GEO") entri"
