#!/bin/bash
# Generate nginx geo config for CDN labeling from cache files.
# Baca cf_ips.cache dan cfront_ips.cache, tulis ke cdn_geo.conf.
# Digunakan oleh nginx directive geo untuk mengisi header X-CDN.
# Skip jika kedua cache kosong atau tidak ada.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config"
CF_CACHE="$DIR/cf_ips.cache"
CFRONT_CACHE="$DIR/cfront_ips.cache"
CDN_GEO="$DIR/cdn_geo.conf"

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
