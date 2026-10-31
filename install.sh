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
read -p "Masukkan Port NAT kosong untuk WebSocket (default: 20864): " ws_port
ws_port=${ws_port:-20864}

# Download file utama
echo -e "
[*] Mengunduh file dari repositori..."
wget -qO menu.sh https://raw.githubusercontent.com/valvatacea/natssh/main/menu.sh
wget -qO ws.py https://raw.githubusercontent.com/valvatacea/natssh/main/ws.py
wget -qO autokill.sh https://raw.githubusercontent.com/valvatacea/natssh/main/autokill.sh
wget -qO uninstall.sh https://raw.githubusercontent.com/valvatacea/natssh/main/uninstall.sh

echo -e "
[*] Mengatur port di ws.py..."
sed -i "s/WS_PORT = 20864/WS_PORT = ${ws_port}/g" ws.py

echo -e "
[*] Mengatur izin eksekusi..."
chmod +x menu.sh autokill.sh uninstall.sh

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

echo -e "
[*] Mengatur Cronjob untuk Autokill..."
# Cek apakah cronjob sudah ada agar tidak duplikat
if ! crontab -l | grep -q "autokill.sh"; then
    (crontab -l 2>/dev/null; echo "*/2 * * * * $(pwd)/autokill.sh") | crontab -
    echo -e "${GREEN}Cronjob Autokill berhasil ditambahkan (berjalan setiap 2 menit).${NC}"
else
    echo -e "${GREEN}Cronjob Autokill sudah ada.${NC}"
fi

echo -e "
[*] Mengatur Banner Pesan SSH..."
cat > /etc/issue.net <<EOF
<br>
<font color="green"><b>======================================</b></font><br>
<font color="yellow"><b>       SELAMAT DATANG DI PREMIUM VPN  </b></font><br>
<font color="green"><b>======================================</b></font><br>
<font color="red"><b> PERINGATAN: </b></font><br>
<font color="white"> - Dilarang Torrent </font><br>
<font color="white"> - Dilarang DDOS / Hacking </font><br>
<font color="white"> - Max Login 1 Perangkat (Auto-Kill) </font><br>
<font color="green"><b>======================================</b></font><br>
EOF

# Aktifkan banner di sshd_config
sed -i 's/#Banner none/Banner \/etc\/issue.net/g' /etc/ssh/sshd_config
sed -i 's/#Banner \/etc\/issue.net/Banner \/etc\/issue.net/g' /etc/ssh/sshd_config
systemctl restart sshd

echo -e "
${CYAN}================================================${NC}"
echo -e "${GREEN} INSTALASI SELESAI!                             ${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "1. Untuk mengelola akun, jalankan: ${YELLOW}./menu.sh${NC}"
echo -e "2. Untuk mengecek status WebSocket: ${YELLOW}systemctl status natssh-ws${NC}"
echo -e "3. Port WebSocket Anda saat ini: ${YELLOW}${ws_port}${NC}"
