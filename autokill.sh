#!/bin/bash
MAX_LOGIN=5 # Batas maksimal perangkat

ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
    if id "$user" &>/dev/null; then
        shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
        if [ "$shell" == "/bin/false" ] && [ "$count" -gt "$MAX_LOGIN" ]; then
            pkill -u "$user" sshd
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang: $user ($count sesi)" >> /root/autokill.log
        fi
    fi
done
