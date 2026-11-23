#!/bin/bash
# Installer for natssh (SSH WebSocket Proxy & Autokill untuk VPS NAT)
# Repo: https://github.com/valvatacea/natssh.git
# Path dinamis: $(pwd) = direktori tempat installer dijalankan

RED='\u001b[0;31m'
GREEN='\u001b[0;32m'
YELLOW='\u001b[0;33m'
CYAN='\u001b[0;36m'
NC='\u001b[0m'

# Ekstraksi root domain menggunakan Public Suffix List (unduh dari publicsuffix.org)
extract_root_domain() {
    local domain="$1"
    local psl_file="$2"
    local parts count best_len line trimmed
    local best_suffix="" best_len=0

    # Hitung jumlah label domain (titik + 1)
    local ddots="${domain//[^.]/}"
    parts=${#ddots}
    parts=$((parts + 1))

    local line_count=0
    while IFS= read -r line; do
        line_count=$((line_count + 1))
        # Progress tiap 2000 baris
        if [ $((line_count % 2000)) -eq 0 ]; then
            echo -e "${YELLOW}   ... memproses baris ke-$line_count${NC}"
        fi

        # Trim whitespace (bash only, tidak pakai sed)
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        line="$trimmed"

        [[ -z "$line" || "$line" == \/\/ ]] && continue

        # Hilangkan leading *. dari wildcard rules
        if [[ "$line" == \*.* ]]; then
            line="${line#*.}"
        fi

        # Lewati exceptions (!rule)
        [[ "$line" == !* ]] && continue
        [[ -z "$line" ]] && continue

        # Hitung jumlah label suffix (titik + 1)
        local sdots="${line//[^.]/}"
        count=${#sdots}
        count=$((count + 1))

        # Cek apakah domain cocok dengan suffix (sama atau diakhiri dengan .suffix)
        if [[ "$domain" == "$line" || "$domain" == *".$line" ]]; then
            if [ "$count" -gt "$best_len" ] && [ "$parts" -gt "$count" ]; then
                best_suffix="$line"
                best_len="$count"
            fi
        fi
    done < "$psl_file"

    echo -e "${GREEN}   Selesai memproses $line_count baris PSL${NC}"

    if [ -n "$best_suffix" ]; then
        # Ekstrak root domain: hilangkan label di depan sampai tersisa best_len label
        local start=$((parts - best_len))
        local remaining="$domain"
        local idx=1
        while [ $idx -lt $start ]; do
            remaining="${remaining#*.}"
            idx=$((idx + 1))
        done
        echo "$remaining"
        return 0
    fi
    return 1
}

echo -e "${CYAN}================================================${NC}"
echo -e "${YELLOW}   INSTALASI NATSSH (WebSocket Proxy & Autokill)  ${NC}"
echo -e "${CYAN}================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Tolong jalankan skrip ini sebagai root (sudo -i).${NC}"
  exit 1
fi
ulimit -n 65535

ulimit -n 65535

echo -e "\n[*] Memeriksa dependensi..."
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}Python3 belum terinstal. Menginstal...${NC}"
    apt-get update && apt-get install -y python3
else
    echo -e "${GREEN}Python3 sudah terinstal.${NC}"
fi
read -p "Masukkan Port SSH WS (kosongkan untuk otomatis): " ws_port
if [ -z "$ws_port" ]; then
    ws_port=20865
fi

read -p "Maksimal perangkat per akun / batas autokill (default: 5): " max_login
max_login=${max_login:-5}
if ! [[ "$max_login" =~ ^[0-9]+$ ]] || [ "$max_login" -lt 1 ] || [ "$max_login" -gt 20 ]; then
    echo "Batas perangkat tidak valid!"; exit 1
fi
if ! [[ "$ws_port" =~ ^[0-9]+$ ]] || [ "$ws_port" -lt 1 ] || [ "$ws_port" -gt 65535 ]; then
    echo "Port tidak valid!"; exit 1
fi
if ss -tln | grep -q ":${ws_port} "; then
    echo -e "${RED}Port ${ws_port} sudah dipakai proses lain!${NC}"; exit 1
fi

# Port SSH Direct (raw TCP listener di ws.py, untuk SSH non-WebSocket)
default_direct=$((ws_port + 4))
read -p "Masukkan Port SSH Direct (kosongkan untuk otomatis): " direct_port
if [ -z "$direct_port" ]; then
    direct_port=$default_direct
fi
if ! [[ "$direct_port" =~ ^[0-9]+$ ]] || [ "$direct_port" -lt 1 ] || [ "$direct_port" -gt 65535 ]; then
    echo "Port SSH Direct tidak valid!"; exit 1
fi
if ss -tln | grep -q ":${direct_port} "; then
    echo -e "${RED}Port ${direct_port} sudah dipakai proses lain!${NC}"; exit 1
fi

DIR=$(pwd)
echo -e "\n[*] Direktori instalasi: $DIR"

mkdir -p "$DIR/config"
mkdir -p "$DIR/config/promo"
mkdir -p "$DIR/logs"
mkdir -p "$DIR/suspended"
mkdir -p /etc/nginx/ssl

echo -e "\n[*] Konfigurasi Domain/Host (wajib diisi)"
while true; do
    read -p "Masukkan Domain/Host (Contoh: id1.xenonblue.qzz.io): " ssl_domain
    ssl_domain=$(echo "$ssl_domain" | xargs)
    if [ -z "$ssl_domain" ]; then
        echo -e "${RED}Domain/Host wajib diisi, tidak boleh kosong!${NC}"
    else
        break
    fi
done

# Backup host.conf untuk rollback jika instalasi gagal di tengah jalan
INSTALL_SUKSES=0
HOST_CONF_BACKUP=0
if [ -f "$DIR/config/host.conf" ]; then
    cp "$DIR/config/host.conf" "$DIR/config/host.conf.bak"
    HOST_CONF_BACKUP=1
fi

_rollback_host_conf() {
    if [ "$INSTALL_SUKSES" -eq 0 ] && [ "$HOST_CONF_BACKUP" -eq 1 ] && [ -f "$DIR/config/host.conf.bak" ]; then
        cp "$DIR/config/host.conf.bak" "$DIR/config/host.conf"
        rm -f "$DIR/config/host.conf.bak"
        echo -e "${RED}Rollback: config/host.conf dikembalikan ke versi sebelumnya.${NC}"
    fi
}
trap '_rollback_host_conf' EXIT

echo "$ssl_domain" > "$DIR/config/host.conf"
echo -e "${GREEN}Domain disimpan ke $DIR/config/host.conf${NC}"

# Ekstraksi root domain via Public Suffix List, fallback ke host.conf jika gagal
echo -e "\n[*] Mengecek Public Suffix List..."
PSL_FILE="$DIR/config/public_suffix_list.dat"
root_domain=""
if [ -s "$PSL_FILE" ]; then
    echo -e "${GREEN}PSL sudah tersedia di $PSL_FILE, lewati unduhan.${NC}"
else
    echo -e "[*] Mengunduh Public Suffix List..."
    if wget -q "https://publicsuffix.org/list/public_suffix_list.dat" -O "$PSL_FILE" 2>/dev/null; then
        echo -e "${GREEN}PSL tersimpan di $PSL_FILE.${NC}"
    else
        echo -e "${YELLOW}Gagal unduh Public Suffix List, pakai fallback host.conf${NC}"
    fi
fi

if [ -s "$PSL_FILE" ]; then
    root_domain=$(extract_root_domain "$ssl_domain" "$PSL_FILE")
    if [ -z "$root_domain" ]; then
        echo -e "${YELLOW}Public Suffix List tidak dapat menentukan root domain, pakai fallback host.conf${NC}"
        root_domain="$ssl_domain"
    fi
fi

if [ -z "$root_domain" ]; then
    echo -e "${YELLOW}PSL tidak tersedia, pakai fallback host.conf${NC}"
    root_domain="$ssl_domain"
fi
echo -e "${GREEN}Root domain untuk sertifikat: ${root_domain}${NC}"

# Validasi suffix domain terhadap Public Suffix List
if [ "$root_domain" = "$ssl_domain" ]; then
    echo -e "${YELLOW}Peringatan: Suffix domain '${ssl_domain}' tidak ditemukan dalam Public Suffix List.${NC}"
    echo -e "${YELLOW}Sertifikat SSL mungkin tidak valid untuk domain dengan suffix tidak dikenal.${NC}"
    read -p "Lanjutkan terbitkan sertifikat untuk ${root_domain}? (y/N): " confirm_suffix
    if [[ ! "$confirm_suffix" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Instalasi dibatalkan.${NC}"; exit 1
    fi
fi

echo -e "\n[*] Mengunduh file dari repositori..."
wget -qO "$DIR/menu.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/menu.sh
wget -qO "$DIR/ws.py" https://raw.githubusercontent.com/valvatacea/natssh/main/ws.py
wget -qO "$DIR/autokill.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/autokill.sh
wget -qO "$DIR/unsuspend.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/unsuspend.sh
wget -qO "$DIR/autobackup.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/autobackup.sh
wget -qO "$DIR/uninstall.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/uninstall.sh
wget -qO "$DIR/apply_speed.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/apply_speed.sh
wget -qO "$DIR/apply_cf_marks.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/apply_cf_marks.sh
wget -qO "$DIR/promo_rotate.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/promo_rotate.sh
wget -qO "$DIR/sess_audit.py" https://raw.githubusercontent.com/valvatacea/natssh/main/sess_audit.py
wget -qO "$DIR/reap.py" https://raw.githubusercontent.com/valvatacea/natssh/main/reap.py
wget -qO "$DIR/audit_kill.py" https://raw.githubusercontent.com/valvatacea/natssh/main/audit_kill.py
wget -qO "$DIR/ws_match.py" https://raw.githubusercontent.com/valvatacea/natssh/main/ws_match.py
wget -qO "$DIR/generate_cdn_geo.sh" https://raw.githubusercontent.com/valvatacea/natssh/main/generate_cdn_geo.sh

for f in menu.sh ws.py autokill.sh unsuspend.sh autobackup.sh uninstall.sh apply_speed.sh apply_cf_marks.sh promo_rotate.sh sess_audit.py reap.py audit_kill.py ws_match.py generate_cdn_geo.sh; do
    [ -s "$DIR/$f" ] || { echo "Gagal mengunduh $f (repo privat/offline?)"; exit 1; }
done
echo -e "\n[*] Port WebSocket akan disetel via Environment systemd (ws.py v2): ${ws_port}"

echo -e "\n[*] Mengatur izin eksekusi..."
chmod +x "$DIR/menu.sh" "$DIR/autokill.sh" "$DIR/unsuspend.sh" "$DIR/autobackup.sh" "$DIR/uninstall.sh" "$DIR/apply_speed.sh" "$DIR/apply_cf_marks.sh" "$DIR/promo_rotate.sh" "$DIR/sess_audit.py" "$DIR/reap.py" "$DIR/audit_kill.py" "$DIR/ws_match.py" "$DIR/generate_cdn_geo.sh"

echo -e "\n[*] Mengatur Service Systemd untuk WebSocket Proxy (ws.py)..."
cat > /etc/systemd/system/natssh-ws.service <<EOF
[Unit]
Description=NATSSH WebSocket Proxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$DIR
Environment=NATSSH_WS_PORT=${ws_port}
Environment=NATSSH_MAX_TOTAL=150
Environment=NATSSH_SSH_DIRECT_ENABLED=1
Environment=NATSSH_SSH_DIRECT_PORT=${direct_port}
Environment=NATSSH_PROXY_PROTOCOL=1
ExecStart=/usr/bin/python3 $DIR/ws.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable natssh-ws.service
systemctl start natssh-ws.service
echo -e "${GREEN}Service natssh-ws berhasil dibuat dan dijalankan!${NC}"

udpgw_ports="7100 7200 7300 7400 7500"

echo -e "\n[*] Menginstal dependensi build badvpn-udpgw..."
apt-get update >/dev/null 2>&1
apt-get install -y build-essential cmake git >/dev/null 2>&1

echo -e "\n[*] Mengunduh dan build badvpn-udpgw..."
rm -rf /tmp/badvpn-build
git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn-build >/dev/null 2>&1
mkdir -p /tmp/badvpn-build/build
cd /tmp/badvpn-build/build
cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1
make >/dev/null 2>&1
make install >/dev/null 2>&1
cd - >/dev/null

if ! command -v badvpn-udpgw >/dev/null 2>&1; then
    echo -e "${RED}Gagal build/install badvpn-udpgw.${NC}"; exit 1
fi

echo -e "\n[*] Mengatur template Service Systemd untuk badvpn-udpgw..."
cat > /etc/systemd/system/natssh-udpgw@.service <<EOF
[Unit]
Description=NATSSH badvpn-udpgw (UDP Gateway) port %i (localhost only)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:%i
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
for pp in $udpgw_ports; do
    systemctl enable --now natssh-udpgw@${pp} >/dev/null 2>&1
done
echo -e "${GREEN}Service natssh-udpgw aktif di: ${udpgw_ports} (localhost only).${NC}"

echo -e "\n[*] Menginstal nginx (reverse proxy WebSocket)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >/dev/null 2>&1
if ! command -v nginx &> /dev/null; then
    echo -e "${RED}Gagal menginstal nginx.${NC}"; exit 1
fi

read -p "Masukkan Port Nginx Reverse (kosongkan untuk 443 atau 8443): " nginx_port
if [ -z "$nginx_port" ]; then
    if ss -tln | grep -q ":443 "; then
        nginx_port=8443
    else
        nginx_port=443
    fi
fi
if ! [[ "$nginx_port" =~ ^[0-9]+$ ]] || [ "$nginx_port" -lt 1 ] || [ "$nginx_port" -gt 65535 ]; then
    echo "Port tidak valid!"; exit 1
fi
if ss -tln | grep -q ":${nginx_port} "; then
    echo -e "${RED}Port ${nginx_port} sudah dipakai proses lain!${NC}"; exit 1
fi

rm -f /etc/nginx/sites-enabled/default

ssl_domain=$(cat "$DIR/config/host.conf" 2>/dev/null)
if [ -z "$ssl_domain" ]; then
    echo -e "${RED}Domain/Host kosong di $DIR/config/host.conf! Instalasi dibatalkan.${NC}"; exit 1
fi

echo -e "\n[*] Memeriksa acme.sh..."
if [ -x "$HOME/.acme.sh/acme.sh" ]; then
    acme_version=$("$HOME/.acme.sh/acme.sh" --version 2>/dev/null | head -1)
    echo -e "${GREEN}acme.sh sudah terinstal: ${acme_version:-versi tidak terbaca}, lewati instalasi.${NC}"
else
    echo -e "[*] Memasang acme.sh (belum ada)..."
    curl https://get.acme.sh | sh -s email=admin@example.com
fi

# Pemeriksaan acme.sh
if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    echo -e "${RED}acme.sh tidak ditemukan atau tidak dapat dieksekusi di $HOME/.acme.sh/acme.sh${NC}"; exit 1
fi
acme_version=$("$HOME/.acme.sh/acme.sh" --version 2>/dev/null | head -1)
if [ -z "$acme_version" ]; then
    echo -e "${RED}Gagal menjalankan acme.sh. Periksa koneksi internet dan instalasi acme.sh.${NC}"; exit 1
fi
echo -e "${GREEN}acme.sh siap: $acme_version${NC}"

echo -e "\n[*] Muat variabel dari config/.env (jika ada)..."
if [ -f "$DIR/config/.env" ]; then
    set -a
    . "$DIR/config/.env"
    set +a
    echo -e "${GREEN}Variabel .env dimuat.${NC}"
else
    echo -e "${YELLOW}File config/.env tidak ditemukan, lewati.${NC}"
fi

echo -e "\n[*] Konfigurasi Cloudflare (untuk DNS challenge)..."
if [ -z "${CF_Token}" ] && [ -z "${CF_Key}" ]; then
    echo -e "${YELLOW}Pilih jenis kredensial Cloudflare:${NC}"
    echo -e "  1) API Token"
    echo -e "  2) API Key + Email"
    read -p "Pilihan (1-2, 0 = batal): " cf_pilih
    case "$cf_pilih" in
        1)
            read -p "Masukkan Cloudflare API Token: " CF_Token
            export CF_Token="${CF_Token}"
            ;;
        2)
            read -p "Masukkan Cloudflare API Key: " CF_Key
            read -p "Masukkan Cloudflare Account Email: " CF_Email
            export CF_Key="${CF_Key}"
            export CF_Email="${CF_Email}"
            ;;
        0|"")
            echo -e "${RED}Dibatalkan.${NC}"; exit 1
            ;;
        *)
            echo -e "${RED}Pilihan tidak valid.${NC}"; exit 1
            ;;
    esac
fi

# Simpan kredensial ke config/.env
if [ -n "${CF_Token}" ]; then
    if [ -f "$DIR/config/.env" ]; then
        if grep -q "^CF_Token=" "$DIR/config/.env"; then
            sed -i "s|^CF_Token=.*|CF_Token=${CF_Token}|" "$DIR/config/.env"
        else
            echo "CF_Token=${CF_Token}" >> "$DIR/config/.env"
        fi
    else
        echo "CF_Token=${CF_Token}" > "$DIR/config/.env"
    fi
    echo -e "${GREEN}Cloudflare API Token disimpan ke config/.env${NC}"
fi

if [ -n "${CF_Key}" ]; then
    if [ -f "$DIR/config/.env" ]; then
        if grep -q "^CF_Key=" "$DIR/config/.env"; then
            sed -i "s|^CF_Key=.*|CF_Key=${CF_Key}|" "$DIR/config/.env"
        else
            echo "CF_Key=${CF_Key}" >> "$DIR/config/.env"
        fi
    else
        echo "CF_Key=${CF_Key}" > "$DIR/config/.env"
    fi
    if [ -n "${CF_Email}" ]; then
        if [ -f "$DIR/config/.env" ]; then
            if grep -q "^CF_Email=" "$DIR/config/.env"; then
                sed -i "s|^CF_Email=.*|CF_Email=${CF_Email}|" "$DIR/config/.env"
            else
                echo "CF_Email=${CF_Email}" >> "$DIR/config/.env"
            fi
        else
            echo "CF_Email=${CF_Email}" > "$DIR/config/.env"
        fi
        echo -e "${GREEN}Cloudflare API Key + Email disimpan ke config/.env${NC}"
    fi
fi

if [ -z "$CF_Token" ] && [ -z "${CF_Key}" ]; then
    echo -e "${RED}Kredensial Cloudflare tidak diisi. Instalasi dibatalkan.${NC}"; exit 1
fi

echo -e "\n[*] Memeriksa perintah idn (untuk domain internasional)..."
if ! command -v idn >/dev/null 2>&1; then
    echo -e "${YELLOW}idn belum terpasang. Memasang...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y idn
    elif command -v apk >/dev/null 2>&1; then
        apk add idn
    else
        echo -e "${RED}Gagal memasang idn (paket manager tidak didukung).${NC}"
    fi
fi
if ! command -v idn >/dev/null 2>&1; then
    echo -e "${RED}idn tidak tersedia, sertifikat untuk domain IDN mungkin gagal.${NC}"
else
    echo -e "${GREEN}idn siap.${NC}"
fi

echo -e "\n[*] Menerbitkan sertifikat SSL via acme.sh (Cloudflare DNS challenge)..."
"$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "*.${root_domain}" -d "${root_domain}" \
    --cert-file /etc/nginx/ssl/natssh.crt \
    --key-file /etc/nginx/ssl/natssh.key \
    --fullchain-file /etc/nginx/ssl/natssh_fullchain.crt \
    --reloadcmd "systemctl reload nginx" || {
    echo -e "${RED}Gagal menerbitkan sertifikat SSL.${NC}"; exit 1
    }

cat > /etc/nginx/sites-available/natssh-ws <<EOF
server {
    listen ${nginx_port} ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/natssh.crt;
    ssl_certificate_key /etc/nginx/ssl/natssh.key;

    location / {
        proxy_pass http://127.0.0.1:${ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-CDN \$cdn_label;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/natssh-ws /etc/nginx/sites-enabled/natssh-ws

echo -e "\n[*] Mengoptimalkan nginx untuk WebSocket (file descriptor & connections)..."
sed -i 's/^[[:space:]]*worker_connections .*/    worker_connections 4096;/' /etc/nginx/nginx.conf
if ! grep -q 'worker_rlimit_nofile' /etc/nginx/nginx.conf; then
    sed -i '/^pid \/run\/nginx\.pid;$/a worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
fi
nginx -t && systemctl enable --now nginx
echo -e "${GREEN}Service nginx berhasil dibuat dan dijalankan di port ${nginx_port} SSL -> 127.0.0.1:${ws_port}!${NC}"

echo -e "\n[*] Menginstal modul Nginx Stream untuk SSH Direct (TCP proxy)..."
apt-get install -y libnginx-mod-stream >/dev/null 2>&1

read -p "Masukkan Port Nginx Stream (kosongkan untuk 80 atau 8080): " stream_port
if [ -z "$stream_port" ]; then
    if ss -tln | grep -q ":80 "; then
        stream_port=8080
    else
        stream_port=80
    fi
fi
if ! [[ "$stream_port" =~ ^[0-9]+$ ]] || [ "$stream_port" -lt 1 ] || [ "$stream_port" -gt 65535 ]; then
    echo "Port tidak valid!"; exit 1
fi
if ss -tln | grep -q ":${stream_port} "; then
    echo -e "${RED}Port ${stream_port} sudah dipakai proses lain!${NC}"; exit 1
fi

if ! grep -q 'include /etc/nginx/stream.conf' /etc/nginx/nginx.conf; then
    sed -i '/^http {/i include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf
fi
cat > /etc/nginx/stream.conf <<'EOF'
stream {
    server {
        listen ${stream_port};
        proxy_pass 127.0.0.1:${direct_port};
        proxy_protocol on;
        proxy_timeout 300s;
    }
}
EOF
nginx -t && systemctl restart nginx
echo -e "${GREEN}Service Nginx Stream dijalankan di port ${stream_port} -> 127.0.0.1:${direct_port}!${NC}"

echo -e "\n[*] Menyiapkan service NATSSH speed limit (tidak diaktifkan otomatis)..."
cat > /etc/systemd/system/natssh-speed.service <<'EOF'
[Unit]
Description=NATSSH SSH speed limit (tc)
After=network.target

[Service]
Type=oneshot
ExecStart=$DIR/apply_speed.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo -e "${GREEN}Service natssh-speed disiapkan (belum diaktifkan). Aktif setelah konfigurasi limit speed.${NC}"

echo -e "\n[*] Mengatur Cronjob untuk Autokill..."
if ! crontab -l 2>/dev/null | grep -q "autokill.sh"; then
    (crontab -l 2>/dev/null; echo "*/1 * * * * MAX_LOGIN=$max_login $DIR/autokill.sh") | crontab -
    echo 15 > "$DIR/config/suspend_minutes.conf"
    echo -e "${GREEN}Cronjob Autokill berhasil ditambahkan (berjalan setiap 1 menit).${NC}"
else
    echo -e "${GREEN}Cronjob Autokill sudah ada.${NC}"
fi

if ! crontab -l 2>/dev/null | grep -q "unsuspend.sh"; then
    (crontab -l 2>/dev/null; echo "* * * * * $DIR/unsuspend.sh >> $DIR/logs/autokill.log 2>&1") | crontab -
fi
[ -f "$DIR/config/suspend_minutes.conf" ] || echo 15 > "$DIR/config/suspend_minutes.conf"

if ! crontab -l 2>/dev/null | grep -q "sess_audit"; then
    (crontab -l 2>/dev/null; echo "*/2 * * * * /usr/bin/python3 $DIR/sess_audit.py >/dev/null 2>&1") | crontab -
fi

if ! crontab -l 2>/dev/null | grep -q "systemctl.*restart.*natssh-ws"; then
    (crontab -l 2>/dev/null; echo "0 4 * * * /usr/bin/systemctl restart natssh-ws >/dev/null 2>&1") | crontab -
fi

if ! crontab -l 2>/dev/null | grep -q "systemctl.*restart.*natssh-udpgw"; then
    (crontab -l 2>/dev/null; echo "0 4,15 * * * /usr/bin/systemctl restart 'natssh-udpgw@*' >/dev/null 2>&1") | crontab -
fi

if ! crontab -l 2>/dev/null | grep -q "systemctl.*restart.*nginx"; then
    (crontab -l 2>/dev/null; echo "0 4,30 * * * /usr/bin/systemctl restart nginx >/dev/null 2>&1") | crontab -
fi

echo -e "${GREEN}Cronjob auto-restart per-layanan berhasil ditambahkan (ws 04:00, udpgw 04:15, nginx 04:30).${NC}"

echo -e "\n[*] Backup sshd_config untuk rollback..."
if [ ! -f /etc/ssh/sshd_config.natssh_backup ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.natssh_backup
fi

echo -e "\n[*] Mengatur Banner Pesan SSH..."
cat > /etc/issue.net <<EOF
<br>
<center>
<p align="center">
<font color="cyan">╔═══════════════════════╗</font><br>
<font color="yellow"><b>⚡ PREMIUM VPN SERVICE ⚡</b></font><br>
<font color="cyan">╠═══════════════════════╣</font><br>
<font color="green">✅ KONEKSI BERHASIL</font><br>
<font color="orange">🌍 Server : Indonesia — Premium</font><br>
<font color="aqua">🚀 Speed : up 100 Mbps</font><br>
<font color="lime">📱 Maksimal ${max_login} Perangkat/Akun</font><br>
<font color="orange">⚔ Auto-Kill AKTIF</font><br>
<font color="white">──────────────────</font><br>
<font color="red">⛔ Dilarang: Torrent · DDoS · Data Waster · Hack</font><br>
<font color="grey">🛡 Support : </font><font color="magenta"><a href="https://wa.me/6281223711096?text=Halo%2C%20saya%20ingin%20membeli%20layanan%20SSH%2FVPN.%20Bisa%20info%20paket%20dan%20harganya%3F" target="_blank" rel="noopener">+628****1096</a></font><br>
<font color="cyan">╚═══════════════════════╝</font><br>
<font color="green"><b>═══ SELAMAT MENIKMATI ═══</b></font><br>
</p>
</center>
EOF

if grep -qE "^#?\s*Banner" /etc/ssh/sshd_config; then
    sed -i 's/^\s*#\s*Banner.*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
else
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
fi

sed -i "/^[#[:space:]]*AllowTcpForwarding[[:space:]]/d" /etc/ssh/sshd_config
echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*ClientAliveInterval[[:space:]]/d" /etc/ssh/sshd_config
echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*ClientAliveCountMax[[:space:]]/d" /etc/ssh/sshd_config
echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config

echo -e "\n[*] Mengaktifkan SSH Enhanced (TCP forwarding, tunnel, keep-alive, kapasitas)..."

sed -i "/^[#[:space:]]*PermitTunnel[[:space:]]/d" /etc/ssh/sshd_config
echo "PermitTunnel yes" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*GatewayPorts[[:space:]]/d" /etc/ssh/sshd_config
echo "GatewayPorts no" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*TCPKeepAlive[[:space:]]/d" /etc/ssh/sshd_config
echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*MaxSessions[[:space:]]/d" /etc/ssh/sshd_config
echo "MaxSessions 100" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*MaxStartups[[:space:]]/d" /etc/ssh/sshd_config
echo "MaxStartups 100:30:200" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*UseDNS[[:space:]]/d" /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*Compression[[:space:]]/d" /etc/ssh/sshd_config
echo "Compression no" >> /etc/ssh/sshd_config

systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
echo -e "${GREEN}SSH Enhanced diaktifkan.${NC}"

echo -e "\n[*] Membuat perintah pintas 'natssh'..."
cat > /usr/local/bin/natssh << EOF
#!/bin/bash
exec $DIR/menu.sh \$@
EOF
chmod +x /usr/local/bin/natssh
echo -e "${GREEN}Perintah 'natssh' telah dibuat. Ketik 'natssh' untuk membuka menu.${NC}"

echo -e "\n${CYAN}================================================${NC}"
echo -e "${GREEN} INSTALASI SELESAI!                             ${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "1. Untuk mengelola akun, jalankan: ${YELLOW}natssh${NC}"
echo -e "2. Untuk mengecek status WebSocket: ${YELLOW}systemctl status natssh-ws${NC}"
echo -e "3. Port WebSocket Anda saat ini: ${YELLOW}${ws_port}${NC}"
echo -e "4. Batas perangkat per akun (autokill): ${YELLOW}${max_login}${NC}"
echo -e "5. badvpn-udpgw (localhost only): ${YELLOW}${udpgw_ports}${NC}"
echo -e "6. Nginx reverse proxy (port publik): ${YELLOW}${nginx_port}${NC} -> 127.0.0.1:${ws_port}"
echo -e "7. SSH Direct (TCP listener): ${YELLOW}${direct_port}${NC}"
echo -e "8. Nginx Stream (SSH Direct via proxy): ${YELLOW}${stream_port}${NC} -> 127.0.0.1:${direct_port}"

# Tandai instalasi sukses agar trap rollback tidak aktif
INSTALL_SUKSES=1
rm -f "$DIR/config/host.conf.bak"
