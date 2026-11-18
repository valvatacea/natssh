#!/bin/bash
# Generate nginx geo config for CDN labeling from cache files.
# Baca cf_ips.cache dan cfront_ips.cache, tulis ke cdn_geo.conf.
# Digunakan oleh nginx directive geo untuk mengisi header X-CDN.

DIR=/root/natssh/config
CF_CACHE="$DIR/cf_ips.cache"
CFRONT_CACHE="$DIR/cfront_ips.cache"
CDN_GEO="$DIR/cdn_geo.conf"

{
    if [ -f "$CF_CACHE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo "$ip    \"Cloudflare\";"
        done < "$CF_CACHE"
    fi
    if [ -f "$CFRONT_CACHE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo "$ip    \"CloudFront\";"
        done < "$CFRONT_CACHE"
    fi
} > "$CDN_GEO"

echo "cdn_geo.conf diperbarui: $(wc -l < "$CDN_GEO") entri"
