#!/bin/bash
export TZ=Asia/Jakarta
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCHED="$DIR/config/promo/promo_schedule.conf"
BACKUP="$DIR/banners/.default_backup"
LOG="$DIR/logs/promo.log"
STATE="$DIR/.promo_cycle"
NOW=$(date +%s)

active_keys=(); active_slots=(); active_intervals=(); active_jedas=(); active_ends=()
if [ -f "$SCHED" ]; then
    while IFS='|' read -r slot start days interval enabled jeda; do
        [ -z "$slot" ] && continue
        days=${days:-1}; interval=${interval:-30}; jeda=${jeda:-0}
        [[ "$days" =~ ^[0-9]+$ ]] || days=1
        [[ "$interval" =~ ^[0-9]+$ ]] || interval=30
        [[ "$jeda" =~ ^[0-9]+$ ]] || jeda=0
        [ "$enabled" = "1" ] || continue
        end=$((start + days*86400))
        [ "$NOW" -ge "$start" ] && [ "$NOW" -le "$end" ] || continue
        active_keys+=("$start"); active_slots+=("$slot"); active_intervals+=("$interval")
        active_jedas+=("$jeda"); active_ends+=("$end")
    done < <(sort -t'|' -k2 -n "$SCHED")
fi
n_active=${#active_keys[@]}

next_index() {
    local cur="$1"
    [ "$n_active" -eq 0 ] && echo "-1" && return
    local i pos=-1
    for i in "${!active_keys[@]}"; do
        [ "${active_keys[$i]}" = "$cur" ] && { pos=$i; break; }
    done
    if [ "$pos" -ge 0 ]; then echo $(( (pos + 1) % n_active )); else echo 0; fi
}

state_key=""; state_phase=0; state_ts=0
[ -f "$STATE" ] && IFS='|' read -r state_key state_phase state_ts < "$STATE"

# No active promos
if [ "$n_active" -eq 0 ]; then
    has_enabled=0
    if [ -f "$SCHED" ]; then
        while IFS='|' read -r slot start days interval enabled jeda; do
            [ -z "$slot" ] && continue
            [ "$enabled" = "1" ] && { has_enabled=1; break; }
        done < "$SCHED"
    fi
    if [ "$has_enabled" = "0" ]; then
        crontab -l 2>/dev/null | grep -v "promo_rotate.sh" | crontab - 2>/dev/null
        [ -f "$BACKUP" ] && [ -f /etc/issue.net ] && ! cmp -s "$BACKUP" /etc/issue.net && cp "$BACKUP" /etc/issue.net
        rm -f "$STATE" "$DIR/.promo_last_run" "$DIR/.promo_backup_done"
    else
        [ -f "$BACKUP" ] && [ -f /etc/issue.net ] && ! cmp -s "$BACKUP" /etc/issue.net && cp "$BACKUP" /etc/issue.net
        rm -f "$STATE"
    fi
    exit 0
fi

# Determine current promo
cur_idx=-1
for i in "${!active_keys[@]}"; do
    [ "${active_keys[$i]}" = "$state_key" ] && { cur_idx=$i; break; }
done
if [ "$cur_idx" -lt 0 ]; then
    idx=$(next_index "$state_key")
    cur_idx=$idx
    if [ -n "$state_key" ]; then
        [ -f "$BACKUP" ] && [ -f /etc/issue.net ] && ! cmp -s "$BACKUP" /etc/issue.net && cp "$BACKUP" /etc/issue.net
        state_phase=0; state_ts=0
    fi
fi

active_key="${active_keys[$cur_idx]}"
active_slot="${active_slots[$cur_idx]}"
active_interval="${active_intervals[$cur_idx]}"
active_jeda="${active_jedas[$cur_idx]}"
[[ "$active_jeda" =~ ^[0-9]+$ ]] || active_jeda=0
[[ "$active_interval" =~ ^[0-9]+$ ]] || active_interval=30
if [ -f "$DIR/config/promo/promo_targets_${active_slot}.conf" ]; then
    TARGETS="$DIR/config/promo/promo_targets_${active_slot}.conf"
else
    TARGETS="$DIR/config/promo/promo_targets.conf"
fi

# Main loop: process phases sequentially if conditions met
changed=1
while [ "$changed" = "1" ]; do
    changed=0
    case $state_phase in
        0)
            if [ "$state_ts" = "0" ] || [ $((NOW - state_ts)) -ge $((active_interval * 60)) ]; then
                [ ! -f "$DIR/.promo_backup_done" ] && [ -f /etc/issue.net ] && { cp /etc/issue.net "$BACKUP"; touch "$DIR/.promo_backup_done"; }
                if [ -f "$DIR/banners/$active_slot.txt" ]; then
                    cp "$DIR/banners/$active_slot.txt" /etc/issue.net
                else
                    echo "$(date '+%F %T') PROMO WARNING banner tidak ada untuk slot=$active_slot, lewati pemasang banner" >> "$LOG"
                fi
                if [ -f "$TARGETS" ]; then
                    while read -r u; do
                        u=$(echo "$u" | xargs); [ -z "$u" ] && continue
                        n=$(ps -eo user:40=,comm= | awk -v u="$u" '$2=="sshd" && $1==u' | wc -l)
                        if [ "$n" -gt 0 ]; then
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
                            if [ "$active_jeda" -gt 0 ]; then
                                usermod -L "$u" 2>/dev/null
                                mkdir -p /root/natssh/suspended
                                echo $(( NOW + active_jeda )) > "/root/natssh/suspended/$u"
                                echo "$(date '+%F %T') PROMO JEDA $u (${active_jeda}s) slot=$active_slot" >> "$LOG"
                            fi
                        fi
                    done < "$TARGETS"
                fi
                echo "$(date '+%F %T') PROMO ACTIVE slot=$active_slot interval=${active_interval}m" >> "$LOG"
                echo "${active_key}|1|${NOW}" > "$STATE"
                state_phase=1; state_ts=$NOW; changed=1
            fi
            ;;
        1)
            if [ "$active_jeda" -eq 0 ] || [ $((NOW - state_ts)) -ge "$active_jeda" ]; then
                if [ "$active_jeda" -gt 0 ] && [ -f "$TARGETS" ]; then
                    while read -r u; do
                        u=$(echo "$u" | xargs); [ -z "$u" ] && continue
                        usermod -U "$u" 2>/dev/null
                    done < "$TARGETS"
                fi
                echo "${active_key}|2|${NOW}" > "$STATE"
                state_phase=2; state_ts=$NOW; changed=1
            fi
            ;;
        2)
            if [ "$active_jeda" -eq 0 ] || [ $((NOW - state_ts)) -ge "$active_jeda" ]; then
                [ -f "$BACKUP" ] && [ -f /etc/issue.net ] && ! cmp -s "$BACKUP" /etc/issue.net && { cp "$BACKUP" /etc/issue.net; echo "$(date '+%F %T') PROMO RESTORE default (cycle done) slot=$active_slot" >> "$LOG"; }
                idx=$(next_index "$active_key")
                next_key="${active_keys[$idx]}"
                if [ "$next_key" != "$active_key" ] && [ -n "$next_key" ]; then
                    echo "${next_key}|0|0" > "$STATE"
                    echo "$(date '+%F %T') PROMO SWITCH -> slot=${active_slots[$idx]}" >> "$LOG"
                    active_key="$next_key"; active_slot="${active_slots[$idx]}"
                    active_interval="${active_intervals[$idx]}"; active_jeda="${active_jedas[$idx]}"
                    [[ "$active_jeda" =~ ^[0-9]+$ ]] || active_jeda=0
                    [[ "$active_interval" =~ ^[0-9]+$ ]] || active_interval=30
                    if [ -f "$DIR/config/promo/promo_targets_${active_slot}.conf" ]; then
                        TARGETS="$DIR/config/promo/promo_targets_${active_slot}.conf"
                    else
                        TARGETS="$DIR/config/promo/promo_targets.conf"
                    fi
                    state_key="$active_key"; state_phase=0; state_ts=0; changed=1
                else
                    echo "${active_key}|0|${NOW}" > "$STATE"
                    state_phase=0; state_ts=$NOW; changed=1
                fi
            fi
            ;;
    esac
done
