#!/bin/bash
# Semua timestamp log autokill pakai WIB (GMT+7)
export TZ=Asia/Jakarta
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Muat konfigurasi terpusat dari config/.env (jika ada)
if [ -f "$(dirname "$(readlink -f "$0")")/config/.env" ]; then
    set -a
    . "$(dirname "$(readlink -f "$0")")/config/.env"
    set +a
fi

MAX_LOGIN="${MAX_LOGIN:-5}" # batas perangkat global; env MAX_LOGIN disuntik cron; khusus per akun di limits/<user>
if ! [[ "$MAX_LOGIN" =~ ^[0-9]+$ ]]; then
    MAX_LOGIN=5
fi

LOG_FILE="/root/natssh/logs/autokill.log"
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR"
MAX_LOG_SIZE=512000 # 500KB
SUSPEND_DIR="/root/natssh/suspended"
SUSPEND_MINUTES="${SUSPEND_MINUTES:-15}"
if ! [[ "$SUSPEND_MINUTES" =~ ^[0-9]+$ ]]; then
    SUSPEND_MINUTES=15
fi
SUSPEND_SEC=$(( SUSPEND_MINUTES * 60 ))
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
REAPER="$(dirname "$(readlink -f "$0")")/reap.py"
if [ -f "$REAPER" ]; then
    python3 "$REAPER" 2>>"$LOG_FILE"
    if [ $? -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - REAPER ERROR: reap.py gagal dieksekusi" >> "$LOG_FILE"
    fi
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - PERINGATAN: reap.py tidak ditemukan di $REAPER" >> "$LOG_FILE"
fi

# 1 sesi SSH tunnel = 1 proses user-owned ("sshd: user"); pasangan "[priv]" milik ROOT
# (terbuang oleh grep -v root) -> perangkat = count langsung, JANGAN dibagi 2
LIMITS_DIR="$(dirname "$(readlink -f "$0")")/limits"
ps -eo user:32=,comm= | awk '$2 ~ /sshd/ && $1 != "root" {print $1}' | sort | uniq -c | while read count user; do
    if id "$user" &>/dev/null; then
        # Jangan reset suspend yang masih berlaku
        if [ -f "$SUSPEND_DIR/$user" ]; then
            exp_now=$(cat "$SUSPEND_DIR/$user" 2>/dev/null)
            if [[ "$exp_now" =~ ^[0-9]+$ ]] && [ "$(date +%s)" -lt "$exp_now" ]; then
                continue
            fi
        fi
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
            # audit dulu sebelum tendang (tandai killed agar tidak duplikat)
            eps=""
            for pid in $(pgrep -u "$user" sshd); do
                st=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//')
                [ -z "$st" ] && continue
                e=$(date -d "$st" +%s 2>/dev/null)
                [ -n "$e" ] && eps="$eps $e"
            done
            AUDIT="$(dirname "$(readlink -f "$0")")/audit_kill.py"
            if [ -f "$AUDIT" ]; then
                printf '%s\n' $eps | python3 "$AUDIT" "$user" 2>>"$LOG_FILE"
                if [ $? -ne 0 ]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - AUDIT ERROR: audit_kill.py gagal untuk $user" >> "$LOG_FILE"
                fi
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - PERINGATAN: audit_kill.py tidak ditemukan di $AUDIT" >> "$LOG_FILE"
            fi
            pkill -u "$user" sshd
            usermod -L "$user" 2>/dev/null
            echo $(( $(date +%s) + SUSPEND_SEC )) > "$SUSPEND_DIR/$user"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang & suspend ${SUSPEND_MINUTES}m: $user ($devices perangkat, batas $limit)" >> "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - SUSPEND: $user ($devices perangkat, batas $limit, expired $(date -d @$(( $(date +%s) + SUSPEND_SEC )) '+%Y-%m-%d %H:%M:%S'))" >> /root/natssh/logs/suspended_history.log
        fi
    fi
done
