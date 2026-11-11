#!/bin/bash
# Installer for natssh (SSH WebSocket Proxy & Autokill untuk VPS NAT)
# Repo: https://github.com/valvatacea/natssh.git

RED='[0;31m'
GREEN='[0;32m'
YELLOW='[0;33m'
CYAN='[0;36m'
NC='[0m'

echo -e "${CYAN}================================================${NC}"
echo -e "${YELLOW}   INSTALASI NATSSH (WebSocket Proxy & Autokill)  ${NC}"
echo -e "${CYAN}================================================${NC}"

# Cek apakah dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Tolong jalankan skrip ini sebagai root (sudo -i).${NC}"
  exit 1
fi

echo -e "
[*] Memeriksa dependensi..."
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}Python3 belum terinstal. Menginstal...${NC}"
    apt-get update && apt-get install -y python3
else
    echo -e "${GREEN}Python3 sudah terinstal.${NC}"
fi

# Tanya port interaktif
read -p "Masukkan Port NAT kosong untuk WebSocket (default: 20865): " ws_port
ws_port=${ws_port:-20865}
read -p "Maksimal perangkat per akun / batas autokill (default: 5): " max_login
max_login=${max_login:-5}
if ! [[ "$max_login" =~ ^[0-9]+$ ]] || [ "$max_login" -lt 1 ] || [ "$max_login" -gt 20 ]; then
    echo "Batas perangkat tidak valid!"; exit 1
fi
if ! [[ "$ws_port" =~ ^[0-9]+$ ]] || [ "$ws_port" -lt 1 ] || [ "$ws_port" -gt 65535 ]; then
    echo "Port tidak valid!"; exit 1
fi

# Download file utama
echo -e "
[*] Mengunduh file dari repositori..."
wget -qO menu.sh https://raw.githubusercontent.com/valvatacea/natssh/main/menu.sh
wget -qO ws.py https://raw.githubusercontent.com/valvatacea/natssh/main/ws.py
wget -qO autokill.sh https://raw.githubusercontent.com/valvatacea/natssh/main/autokill.sh
wget -qO unsuspend.sh https://raw.githubusercontent.com/valvatacea/natssh/main/unsuspend.sh
wget -qO autobackup.sh https://raw.githubusercontent.com/valvatacea/natssh/main/autobackup.sh
wget -qO uninstall.sh https://raw.githubusercontent.com/valvatacea/natssh/main/uninstall.sh
wget -qO apply_speed.sh https://raw.githubusercontent.com/valvatacea/natssh/main/apply_speed.sh
wget -qO apply_cf_marks.sh https://raw.githubusercontent.com/valvatacea/natssh/main/apply_cf_marks.sh

# Unduhan gagal = file kosong -> service crash-loop; cek ukuran
for f in menu.sh ws.py autokill.sh unsuspend.sh autobackup.sh uninstall.sh apply_speed.sh apply_cf_marks.sh; do
    [ -s "$f" ] || { echo "Gagal mengunduh $f (repo privat/offline?)"; exit 1; }
done
echo -e "
[*] Port WebSocket akan disetel via Environment systemd (ws.py v2): ${ws_port}"

echo -e "
[*] Mengatur izin eksekusi..."
chmod +x menu.sh autokill.sh unsuspend.sh autobackup.sh uninstall.sh apply_speed.sh apply_cf_marks.sh

echo -e "
[*] Mengatur Service Systemd untuk WebSocket Proxy (ws.py)..."
cat > /etc/systemd/system/natssh-ws.service <<EOF
[Unit]
Description=NATSSH WebSocket Proxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$(pwd)
Environment=NATSSH_WS_PORT=${ws_port}
Environment=NATSSH_MAX_TOTAL=150
ExecStart=/usr/bin/python3 $(pwd)/ws.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable natssh-ws.service
systemctl start natssh-ws.service
echo -e "${GREEN}Service natssh-ws berhasil dibuat dan dijalankan!${NC}"

# Port badvpn-udpgw (UDP-over-TCP gateway), internal localhost saja
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


echo -e "\\n[*] Cronjob apply speed digabung dengan restart (lihat bawah)..."

echo -e "\n[*] Menyiapkan service NATSSH speed limit (tidak diaktifkan otomatis)..."
cat > /etc/systemd/system/natssh-speed.service <<'EOF'
[Unit]
Description=NATSSH SSH speed limit (tc)
After=network.target

[Service]
Type=oneshot
ExecStart=/root/natssh/apply_speed.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo -e "${GREEN}Service natssh-speed disiapkan (belum diaktifkan). Aktif setelah konfigurasi limit speed.${NC}"

echo -e "
[*] Mengatur Cronjob untuk Autokill..."
# Cek apakah cronjob sudah ada agar tidak duplikat
if ! crontab -l | grep -q "autokill.sh"; then
    (crontab -l 2>/dev/null; echo "*/1 * * * * MAX_LOGIN=$max_login $(pwd)/autokill.sh") | crontab -
    echo 15 > suspend_minutes.conf
    echo -e "${GREEN}Cronjob Autokill berhasil ditambahkan (berjalan setiap 1 menit).${NC}"
else
    echo -e "${GREEN}Cronjob Autokill sudah ada.${NC}"
fi
mkdir -p /root/natssh/suspended 2>/dev/null
# Cron unsuspend (tiap 1 menit)
if ! crontab -l 2>/dev/null | grep -q "unsuspend.sh"; then
    (crontab -l 2>/dev/null; echo "* * * * * $(pwd)/unsuspend.sh >> /root/natssh/logs/autokill.log 2>&1") | crontab -
fi
[ -f suspend_minutes.conf ] || echo 15 > suspend_minutes.conf
# Cron sess_audit (tiap 2 menit) — riwayat sesi per user
if ! crontab -l 2>/dev/null | grep -q "sess_audit"; then
    (crontab -l 2>/dev/null; echo "*/2 * * * * /usr/bin/python3 $(pwd)/sess_audit.py >/dev/null 2>&1") | crontab -
fi
# Auto restart natssh-ws (jam 04:00)
if ! crontab -l 2>/dev/null | grep -q "systemctl.*restart.*natssh-ws"; then
    (crontab -l 2>/dev/null; echo "0 4 * * * /usr/bin/systemctl restart natssh-ws; /usr/bin/systemctl restart 'natssh-udpgw@*' >/dev/null 2>&1") | crontab -
    echo -e "${GREEN}Cronjob auto-restart natssh-ws berhasil ditambahkan (jam 04:00).${NC}"
fi

echo -e "
[*] Mengatur Banner Pesan SSH..."
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
<font color="grey">🛡 Support : </font><font color="magenta"><a href="https://wa.me/6281223711096?text=Halo%2C%20saya%20ingin%20membeli%20layanan%20SSH%2FVPN.%20Bisa%20info%20paket%20dan%20harganya%3F" target="_blank" rel="noopener">+6281223711096</a></font><br>
<font color="cyan">╚═══════════════════════╝</font><br>
<font color="green"><b>═══ SELAMAT MENIKMATI ═══</b></font><br>
</p>
</center>
EOF

# Aktifkan banner di sshd_config (aman diulang: bila 'Banner' sudah ada, cukup pastikan arahnya benar)
if grep -qE "^#?\s*Banner" /etc/ssh/sshd_config; then
    sed -i 's/^#\s*Banner.*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
else
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
fi
systemctl restart sshd

# Izinkan TCP forwarding untuk tunnel udpgw (localhost)
if grep -qE "^[#[:space:]]*AllowTcpForwarding" /etc/ssh/sshd_config; then
    sed -i 's/^[#[:space:]]*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
else
    echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
fi
# Aktifkan keepalive SSH (server-side) agar sesi tidak idle/putus
if grep -qE "^[#[:space:]]*ClientAliveInterval" /etc/ssh/sshd_config; then
    sed -i 's/^[#[:space:]]*ClientAliveInterval.*/ClientAliveInterval 30/' /etc/ssh/sshd_config
else
    echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
fi
if grep -qE "^[#[:space:]]*ClientAliveCountMax" /etc/ssh/sshd_config; then
    sed -i 's/^[#[:space:]]*ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config
else
    echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config
fi
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null

echo -e "
${CYAN}================================================${NC}"
echo -e "${GREEN} INSTALASI SELESAI!                             ${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "1. Untuk mengelola akun, jalankan: ${YELLOW}./menu.sh${NC}"
echo -e "2. Untuk mengecek status WebSocket: ${YELLOW}systemctl status natssh-ws${NC}"
echo -e "3. Port WebSocket Anda saat ini: ${YELLOW}${ws_port}${NC}"
echo -e "4. Batas perangkat per akun (autokill): ${YELLOW}${max_login}${NC}"
echo -e "5. badvpn-udpgw (localhost only): ${YELLOW}${udpgw_ports}${NC}"
