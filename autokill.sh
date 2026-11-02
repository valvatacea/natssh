#!/bin/bash
MAX_LOGIN="${MAX_LOGIN:-5}" # batas perangkat; env MAX_LOGIN dari cron/installer (hitungan sesi/2)

LOG_FILE="/root/autokill.log"
MAX_LOG_SIZE=512000 # 500KB

# Memastikan ukuran log tidak membengkak
if [ -f "$LOG_FILE" ]; then
    FILE_SIZE=$(stat -c%s "$LOG_FILE")
    if [ "$FILE_SIZE" -gt "$MAX_LOG_SIZE" ]; then
        # Kosongkan file log jika sudah terlalu besar
        > "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Log dibersihkan secara otomatis (mencapai batas ukuran)." >> "$LOG_FILE"
    fi
fi

# ── REAPER: bunuh sesi sshd hantu (soket bridge mati, proses hidup) ──
"$(dirname "$(readlink -f "$0")")/reap.py" 2>/dev/null

# 1 sesi SSH tunnel = 1 proses user-owned ("sshd: user"); pasangan "[priv]" milik ROOT
# (terbuang oleh grep -v root) -> perangkat = count langsung, JANGAN dibagi 2
LIMITS_DIR="$(dirname "$(readlink -f "$0")")/limits"
ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
    if id "$user" &>/dev/null; then
        shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
        devices=$count
        # batas khusus per akun (limits/<user>, 1-20) menimpa global
        limit="$MAX_LOGIN"
        if [ -f "$LIMITS_DIR/$user" ]; then
            khusus=$(cat "$LIMITS_DIR/$user" 2>/dev/null)
            if [[ "$khusus" =~ ^[0-9]+$ ]] && [ "$khusus" -ge 1 ] && [ "$khusus" -le 20 ]; then
                limit="$khusus"
            fi
        fi
        if [ "$shell" == "/bin/false" ] && [ "$devices" -gt "$limit" ]; then
            pkill -u "$user" sshd
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang: $user ($devices perangkat, batas $limit)" >> "$LOG_FILE"
        fi
    fi
done
