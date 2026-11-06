#!/bin/bash
# Buka kunci akun yang masa suspend 15 menitnya habis
SUSPEND_DIR="/root/natssh/suspended"
LOG_FILE="/root/autokill.log"
[ -d "$SUSPEND_DIR" ] || exit 0
now=$(date +%s)
for f in "$SUSPEND_DIR"/*; do
    [ -f "$f" ] || continue
    user=$(basename "$f")
    exp=$(cat "$f" 2>/dev/null)
    if [[ "$exp" =~ ^[0-9]+$ ]] && [ "$now" -ge "$exp" ]; then
        usermod -U "$user" 2>/dev/null
        rm -f "$f"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Unsuspend otomatis: $user" >> "$LOG_FILE"
    fi
done
