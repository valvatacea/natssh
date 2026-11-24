#!/bin/bash
# Auto-backup NATSSH: konfigurasi + akun (hash password disimpan)
# Semua timestamp log autobackup pakai WIB (GMT+7)
export TZ=Asia/Jakarta
DIR="/root/natssh"
BACKUP_DIR="/root/natssh_backup"
mkdir -p "$BACKUP_DIR"

ts=$(date +%Y%m%d_%H%M%S)
OUT_CFG="$BACKUP_DIR/config_$ts.tar.gz"
bakdir="${DIR}/tmp_bak_$$"
mkdir -p "$bakdir"

LIST=""
[ -f "$DIR/config/.env" ] && LIST="$LIST $DIR/config/.env"
[ -d "$DIR/limits" ] && LIST="$LIST $DIR/limits"
[ -d "$DIR/banners" ] && LIST="$LIST $DIR/banners"
[ -f /etc/issue.net ] && cp /etc/issue.net "$bakdir/issue.net.bak" && LIST="$LIST $bakdir/issue.net.bak"
[ -f /etc/systemd/system/natssh-ws.service ] && cp /etc/systemd/system/natssh-ws.service "$bakdir/natssh-ws.service.bak" && LIST="$LIST $bakdir/natssh-ws.service.bak"

cd "$DIR" && tar -czf "$OUT_CFG" $LIST >/dev/null 2>&1

# Bersihkan file .bak sementara
rm -rf "$bakdir"

# --- Backup akun (portable) ---
BACKUP_FILE="$BACKUP_DIR/akun_$ts.sh"
{
  echo "#!/bin/bash"
  echo "# Auto-backup akun NATSSH - $(date)"
  awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd | while read user; do
    hash=$(grep "^${user}:" /etc/shadow 2>/dev/null | cut -d: -f2)
    exp_days=$(grep "^${user}:" /etc/shadow 2>/dev/null | cut -d: -f8)
    if [ -n "$exp_days" ]; then
      exp_date=$(date -d "1970-01-01 + $exp_days days" +"%Y-%m-%d" 2>/dev/null)
      if [ $? -eq 0 ]; then
        echo "if ! id \"$user\" >/dev/null 2>&1; then"
        echo "    useradd -e \"$exp_date\" -m -s /bin/false \"$user\""
        echo "    usermod -p '$hash' \"$user\""
        echo "else"
        echo "    echo \"User $user sudah ada, dilewati.\""
        echo "fi"
      else
        echo "if ! id \"$user\" >/dev/null 2>&1; then"
        echo "    useradd -m -s /bin/false \"$user\""
        echo "    usermod -p '$hash' \"$user\""
        echo "else"
        echo "    echo \"User $user sudah ada, dilewati.\""
        echo "fi"
      fi
    else
      echo "if ! id \"$user\" >/dev/null 2>&1; then"
      echo "    useradd -m -s /bin/false \"$user\""
      echo "    usermod -p '$hash' \"$user\""
      echo "else"
      echo "    echo \"User $user sudah ada, dilewati.\""
      echo "fi"
    fi
  done
  echo ""
  echo "# --- Batas perangkat per akun ---"
  echo "mkdir -p /root/natssh/limits"
  for f in /root/natssh/limits/*; do
    if [ -f "$f" ]; then
      lim=$(cat "$f" 2>/dev/null)
      name=$(basename "$f")
      echo "if [ ! -f \"/root/natssh/limits/$name\" ]; then"
      echo "    echo \"$lim\" > /root/natssh/limits/$name"
      echo "else"
      echo "    echo \"Limits $name sudah ada, dilewati.\""
      echo "fi"
    fi
  done
} > "$BACKUP_FILE"
chmod 700 "$BACKUP_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-backup: config=$OUT_CFG akun=$BACKUP_FILE" >> /root/natssh/logs/autobackup.log