#!/bin/bash
# Rotasi banner promo otomatis (cron tiap 1 menit)
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCHED="$DIR/promo_schedule.conf"
TARGETS="$DIR/promo_targets.conf"
BACKUP="$DIR/banners/.default_backup"
LOG="$DIR/promo.log"
NOW=$(date +%s)

[ -f "$SCHED" ] || exit 0

# cari promo enabled dalam rentang
active_slot=""
while IFS='|' read -r slot start end interval enabled; do
    [ -z "$slot" ] && continue
    [ "$enabled" = "1" ] || continue
    [ "$NOW" -ge "$start" ] && [ "$NOW" -le "$end" ] || continue
    active_slot="$slot"; active_start="$start"; active_end="$end"; active_interval="$interval"
    break
done < "$SCHED"

# restore jika tidak ada promo aktif dan backup ada
if [ -z "$active_slot" ]; then
    if [ -f "$BACKUP" ] && [ -f /etc/issue.net ]; then
        if ! cmp -s "$BACKUP" /etc/issue.net; then
            cp "$BACKUP" /etc/issue.net
            echo "$(date '+%F %T') PROMO RESTORE default" >> "$LOG"
        fi
    fi
    exit 0
fi

# pastikan banner promo aktif (backup dulu banner saat ini)
if [ -f "/etc/issue.net" ]; then
    cp /etc/issue.net "$BACKUP"
fi
if [ -f "$DIR/banners/$active_slot.txt" ]; then
    cp "$DIR/banners/$active_slot.txt" /etc/issue.net
fi

# disconnect target sesuai interval (sederhana: setiap run disconnect)
if [ -f "$TARGETS" ]; then
    while read -r u; do
        [ -z "$u" ] && continue
        n=$(ps -eo user:40=,comm= | awk -v u="$u" '$2=="sshd" && $1==u' | wc -l)
        if [ "$n" -gt 0 ]; then
            loginctl terminate-user "$u" 2>/dev/null
            pkill -KILL -u "$u" 2>/dev/null
            echo "$(date '+%F %T') PROMO DISCONNECT $u ($n sesi) slot=$active_slot" >> "$LOG"
        fi
    done < "$TARGETS"
fi

echo "$(date '+%F %T') PROMO ACTIVE slot=$active_slot" >> "$LOG"
