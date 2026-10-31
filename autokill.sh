#!/bin/bash
MAX_LOGIN=5 # Batas maksimal perangkat

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

ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
    if id "$user" &>/dev/null; then
        shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
        if [ "$shell" == "/bin/false" ] && [ "$count" -gt "$MAX_LOGIN" ]; then
            pkill -u "$user" sshd
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang: $user ($count sesi)" >> "$LOG_FILE"
        fi
    fi
done
