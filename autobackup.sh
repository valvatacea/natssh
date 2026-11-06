#!/bin/bash
# Auto-backup konfigurasi NATSSH (tanpa akun/password)
DIR="/root/natssh"
TS=$(date +%Y%m%d_%H%M%S)
OUT="/root/natssh_config_${TS}.tar.gz"
LIST=""
[ -f "$DIR/ip.conf" ] && LIST="$LIST ip.conf"
[ -f "$DIR/host.conf" ] && LIST="$LIST host.conf"
[ -f "$DIR/port.conf" ] && LIST="$LIST port.conf"
[ -f "$DIR/hide_ip.conf" ] && LIST="$LIST hide_ip.conf"
[ -f "$DIR/suspend_minutes.conf" ] && LIST="$LIST suspend_minutes.conf"
[ -d "$DIR/limits" ] && LIST="$LIST limits"
[ -d "$DIR/banners" ] && LIST="$LIST banners"
[ -f /etc/issue.net ] && cp /etc/issue.net "$DIR/issue.net.bak" && LIST="$LIST issue.net.bak"
[ -f /etc/systemd/system/natssh-ws.service ] && cp /etc/systemd/system/natssh-ws.service "$DIR/natssh-ws.service.bak" && LIST="$LIST natssh-ws.service.bak"
cd "$DIR" && tar -czf "$OUT" $LIST >/dev/null 2>&1
# bersihkan backup lama > 7 hari
find /root -maxdepth 1 -name 'natssh_config_*.tar.gz' -mtime +7 -delete 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-backup: $OUT" >> /root/natssh/autobackup.log
