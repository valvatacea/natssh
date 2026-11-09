#!/bin/bash
# Auto-backup NATSSH: konfigurasi + akun (hash password disimpan)
# Semua timestamp log autobackup pakai WIB (GMT+7)
export TZ=Asia/Jakarta
DIR="/root/natssh"

# --- Backup konfigurasi (nama statis) ---
OUT_CFG="/root/natssh_config.tar.gz"
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
cd "$DIR" && tar -czf "$OUT_CFG" $LIST >/dev/null 2>&1

# --- Backup akun (portable) ---
BACKUP_FILE="/root/backup_akun_ssh.sh"
{
  echo "#!/bin/bash"
  echo "# Auto-backup akun NATSSH - $(date)"
  echo "set -e"
  awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd | while read user; do
    hash=$(grep "^${user}:" /etc/shadow | cut -d: -f2)
    exp_days=$(grep "^${user}:" /etc/shadow | cut -d: -f8)
    if [ -n "$exp_days" ]; then
      exp_date=$(date -d "1970-01-01 + $exp_days days" +"%Y-%m-%d" 2>/dev/null)
      if [ $? -eq 0 ]; then
        echo "useradd -e \"$exp_date\" -m -s /bin/false \"$user\""
      else
        echo "useradd -m -s /bin/false \"$user\""
      fi
    else
      echo "useradd -m -s /bin/false \"$user\""
    fi
    echo "usermod -p '$hash' \"$user\""
  done
} > "$BACKUP_FILE"
chmod 700 "$BACKUP_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-backup: config=$OUT_CFG akun=$BACKUP_FILE" >> /root/natssh/autobackup.log
