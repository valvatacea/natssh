#!/bin/bash
# Buka kunci akun yang masa suspend 15 menitnya habis
# Semua timestamp log unsuspend pakai WIB (GMT+7)
export TZ=Asia/Jakarta
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C

SUSPEND_DIR="/root/natssh/suspended"
LOG_FILE="/root/natssh/logs/autokill.log"
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR"

# Flock: mencegah overlap jika cron jalankan sambil yang lain masih berjalan
LOCK_FILE="$LOG_DIR/unsuspend.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Unsuspend sudah berjalan, lewati." >> "$LOG_FILE"
    exit 0
fi

[ -d "$SUSPEND_DIR" ] || exit 0
now=$(date +%s)
for f in "$SUSPEND_DIR"/*; do
    [ -f "$f" ] || continue
    user=$(basename "$f")
    exp=$(cat "$f" 2>/dev/null)
    if [[ "$exp" =~ ^[0-9]+$ ]] && [ "$now" -ge "$exp" ]; then
        if usermod -U "$user" 2>/dev/null; then
            rm -f "$f"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Unsuspend otomatis: $user" >> "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - UNSUSPEND: $user" >> "$LOG_DIR/suspended_history.log"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - GAGAL unsuspend: $user (usermod gagal)" >> "$LOG_FILE"
        fi
    fi
done
