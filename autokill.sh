#!/bin/bash
MAX_LOGIN="${MAX_LOGIN:-5}" # batas perangkat global; env MAX_LOGIN disuntik cron; khusus per akun di limits/<user>

LOG_FILE="/root/autokill.log"
MAX_LOG_SIZE=512000 # 500KB
SUSPEND_DIR="/root/natssh/suspended"
mkdir -p "$SUSPEND_DIR"

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
ps -eo user:32=,comm= | awk '$2 ~ /sshd/ && $1 != "root" {print $1}' | sort | uniq -c | while read count user; do
    if id "$user" &>/dev/null; then
        shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
        devices=$count
        # batas khusus per akun (limits/<user>, angka >= 1 bebas) menimpa global
        limit="$MAX_LOGIN"
        if [ -f "$LIMITS_DIR/$user" ]; then
            khusus=$(cat "$LIMITS_DIR/$user" 2>/dev/null)
            if [ "$khusus" == "unlimited" ]; then
                continue   # TANPA BATAS — akun ini tak pernah ditendang
            fi
            if [[ "$khusus" =~ ^[0-9]+$ ]] && [ "$khusus" -ge 1 ]; then
                limit="$khusus"   # angka berapapun >= 1 (tak dibatasi 20)
            fi
        fi
        if [ "$shell" == "/bin/false" ] && [ "$devices" -gt "$limit" ]; then
            pkill -u "$user" sshd
            usermod -L "$user" 2>/dev/null
            echo $(( $(date +%s) + 900 )) > "$SUSPEND_DIR/$user"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang & suspend 15m: $user ($devices perangkat, batas $limit)" >> "$LOG_FILE"
        fi
    fi
done
