#!/bin/bash
# Semua timestamp log promo pakai WIB (GMT+7)
export TZ=Asia/Jakarta

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCHED="$DIR/promo_schedule.conf"
TARGETS="$DIR/promo_targets.conf"
BACKUP="$DIR/banners/.default_backup"
LOG="$DIR/promo.log"
LASTRUN="$DIR/.promo_last_run"
NOW=$(date +%s)

# hapus cron jika tidak ada promo enabled
has_enabled=0
if [ -f "$SCHED" ]; then
    while IFS='|' read -r slot start days interval enabled jeda; do
        [ -z "$slot" ] && continue
        [ "$enabled" = "1" ] || continue
        has_enabled=1
        break
    done < "$SCHED"
fi
if [ "$has_enabled" = "0" ]; then
    crontab -l 2>/dev/null | grep -v "promo_rotate.sh" | crontab - 2>/dev/null
    # restore jika perlu
    if [ -f "$BACKUP" ] && [ -f /etc/issue.net ] && ! cmp -s "$BACKUP" /etc/issue.net; then
        cp "$BACKUP" /etc/issue.net
        echo "$(date '+%F %T') PROMO RESTORE default (no active promo)" >> "$LOG"
    fi
    # cleanup flag
    rm -f "$DIR/.promo_backup_done"
    exit 0
fi

# cari promo aktif
active_slot=""; active_start=""; active_end=""; active_interval=""
while IFS='|' read -r slot start days interval enabled jeda; do
    [ -z "$slot" ] && continue
    [ "$enabled" = "1" ] || continue
    end=$((start + days*86400))
    [ "$NOW" -ge "$start" ] && [ "$NOW" -le "$end" ] || continue
    active_slot="$slot"; active_start="$start"; active_end="$end"; active_interval="${interval:-30}"; active_days="$days"; active_jeda="${jeda:-0}"
    break
done < "$SCHED"

# tidak ada promo aktif dalam rentang -> restore
if [ -z "$active_slot" ]; then
    if [ -f "$BACKUP" ] && [ -f /etc/issue.net ] && ! cmp -s "$BACKUP" /etc/issue.net; then
        cp "$BACKUP" /etc/issue.net
        echo "$(date '+%F %T') PROMO RESTORE default" >> "$LOG"
    fi
    # cleanup flag biar promo berikutnya bisa backup lagi
    rm -f "$DIR/.promo_backup_done"
    exit 0
fi

# backup banner saat ini (hanya saat transisi: tidak ada promo aktif -> ada promo aktif)
# gunakan flag file untuk tandai sudah backup
BACKUP_DONE="$DIR/.promo_backup_done"
if [ -f /etc/issue.net ] && [ ! -f "$BACKUP_DONE" ]; then
    cp /etc/issue.net "$BACKUP"
    touch "$BACKUP_DONE"
fi

# apply banner promo
if [ -f "$DIR/banners/$active_slot.txt" ]; then
    cp "$DIR/banners/$active_slot.txt" /etc/issue.net
fi

# interval check
last=0
[ -f "$LASTRUN" ] && last=$(cat "$LASTRUN" 2>/dev/null)
iv_sec=$((active_interval * 60))
if [ $((NOW - last)) -ge "$iv_sec" ]; then
    if [ -f "$TARGETS" ]; then
        while read -r u; do
            u=$(echo "$u" | xargs)
            [ -z "$u" ] && continue
            n=$(ps -eo user:40=,comm= | awk -v u="$u" '$2=="sshd" && $1==u' | wc -l)
            if [ "$n" -gt 0 ]; then
                # audit dulu sebelum kill
                eps=""
                for pid in $(pgrep -u "$u" sshd); do
                    st=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//')
                    [ -z "$st" ] && continue
                    e=$(date -d "$st" +%s 2>/dev/null)
                    [ -n "$e" ] && eps="$eps $e"
                done
                printf '%s\n' $eps | python3 "$(dirname "$(readlink -f "$0")")/audit_kill.py" "$u" 2>/dev/null
                loginctl terminate-user "$u" 2>/dev/null
                pkill -KILL -u "$u" 2>/dev/null
                echo "$(date '+%F %T') PROMO DISCONNECT $u ($n sesi) slot=$active_slot" >> "$LOG"
                # jeda sesi: lock akun + tulis suspended/<user> untuk auto-unlock
                if [ "${active_jeda:-0}" -gt 0 ] 2>/dev/null; then
                    usermod -L "$u" 2>/dev/null
                    mkdir -p /root/natssh/suspended
                    echo $(( NOW + active_jeda )) > "/root/natssh/suspended/$u"
                    echo "$(date '+%F %T') PROMO JEDA $u (${active_jeda}s) slot=$active_slot" >> "$LOG"
                    echo "$(date '+%F %T') - SUSPEND: $u (promo jeda ${active_jeda}s, expired $(date -d @$((NOW + active_jeda)) '+%Y-%m-%d %H:%M:%S'))" >> /root/natssh/suspended_history.log
                fi
            fi
        done < "$TARGETS"
    fi
    echo "$NOW" > "$LASTRUN"
    echo "$(date '+%F %T') PROMO ACTIVE slot=$active_slot interval=${active_interval}m" >> "$LOG"
fi
