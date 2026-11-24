#!/bin/bash
# Uninstaller for natssh (SSH WebSocket Proxy & Autokill)

RED='\u001b[0;31m'
GREEN='\u001b[0;32m'
YELLOW='\u001b[0;33m'
CYAN='\u001b[0;36m'
NC='\u001b[0m'

echo -e "${CYAN}================================================${NC}"
echo -e "${YELLOW}   UNINSTALL NATSSH (WebSocket Proxy & Autokill)  ${NC}"
echo -e "${CYAN}================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Tolong jalankan skrip ini sebagai root (sudo -i).${NC}"
  exit 1
fi

echo -e "\n[*] Menghentikan dan menghapus Service natssh-ws..."
systemctl stop natssh-ws.service 2>/dev/null
systemctl disable natssh-ws.service 2>/dev/null
rm -f /etc/systemd/system/natssh-ws.service
systemctl daemon-reload
echo -e "${GREEN}Service natssh-ws berhasil dihapus.${NC}"

echo -e "\n[*] Menghentikan dan menghapus Service natssh-speed..."
systemctl disable --now natssh-speed.service 2>/dev/null
rm -f /etc/systemd/system/natssh-speed.service
systemctl daemon-reload
echo -e "${GREEN}Service natssh-speed berhasil dihapus.${NC}"

echo -e "\n[*] Menghentikan dan menghapus Service natssh-udpgw..."
for pp in 7100 7200 7300 7400 7500; do
    systemctl disable --now natssh-udpgw@${pp} 2>/dev/null
done
rm -f /etc/systemd/system/natssh-udpgw@.service
systemctl daemon-reload
echo -e "${GREEN}Service natssh-udpgw berhasil dihapus.${NC}"

echo -e "\\n[*] Menghapus binary badvpn-udpgw..."
rm -f /usr/local/bin/badvpn-udpgw
rm -rf /tmp/badvpn-build
echo -e "${GREEN}Binary badvpn-udpgw berhasil dihapus.${NC}"

echo -e "\n[*] Menghentikan dan menghapus Service nginx..."
systemctl stop nginx.service 2>/dev/null
systemctl disable nginx.service 2>/dev/null
rm -f /etc/nginx/sites-enabled/natssh-ws /etc/nginx/sites-available/natssh-ws
rm -f /etc/nginx/ssl/natssh.pem /etc/nginx/ssl/natssh_key.pem /etc/nginx/ssl/natssh_fullchain.pem
systemctl daemon-reload
echo -e "${GREEN}Service nginx berhasil dihapus.${NC}"

echo -e "\\n[*] Membersihkan konfigurasi Nginx Stream (SSH Direct)..."
rm -f /etc/nginx/stream.conf
sed -i '/include \/etc\/nginx\/stream\.conf;/d' /etc/nginx/nginx.conf
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
echo -e "${GREEN}Konfigurasi Nginx Stream dibersihkan.${NC}"

echo -e "\n[*] Membersihkan crontab..."
crontab_l=$(crontab -l 2>/dev/null)
crontab_new=$(echo "$crontab_l" | grep -v "unsuspend.sh" | grep -v "autobackup.sh" | grep -v "apply_speed.sh" | grep -v "generate_cdn_geo.sh" | grep -v "systemctl.*restart.*natssh-ws" | grep -v "systemctl.*restart.*natssh-udpgw" | grep -v "systemctl.*restart.*nginx" | grep -v "sess_audit" | grep -v "autokill.sh" | grep -v "acme.sh --cron")
echo "$crontab_new" | crontab - 2>/dev/null || true

echo -e "\n[*] Merestore sshd_config dari backup (rollback)..."
if [ -f /etc/ssh/sshd_config.natssh_backup ]; then
    cp /etc/ssh/sshd_config.natssh_backup /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.natssh_backup
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo -e "${GREEN}sshd_config dikembalikan ke kondisi awal (rollback).${NC}"
else
    echo -e "[*] Tidak ada backup sshd_config. Membersihkan baris natssh secara manual..."
    sed -i "/^[#[:space:]]*Banner/d" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    sed -i "/^[#[:space:]]*ClientAliveInterval/d" /etc/ssh/sshd_config
    sed -i "/^[#[:space:]]*ClientAliveCountMax/d" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    sed -i "/^[#[:space:]]*PermitTunnel/d" /etc/ssh/sshd_config
    sed -i "/^[#[:space:]]*GatewayPorts/d" /etc/ssh/sshd_config
    sed -i "/^[#[:space:]]*TCPKeepAlive/d" /etc/ssh/sshd_config
    sed -i "/^[#[:space:]]*MaxSessions/d" /etc/ssh/sshd_config
    sed -i "/^[#[:space:]]*MaxStartups/d" /etc/ssh/sshd_config
    sed -i "/^[#[:space:]]*UseDNS/d" /etc/ssh/sshd_config
    sed -i "/^[#[:space:]]*Compression/d" /etc/ssh/sshd_config
sed -i "/^[#[:space:]]*AllowTcpForwarding/d" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
fi

rm -f /usr/local/bin/natssh
echo -e "${GREEN}Perintah 'natssh' dihapus.${NC}"

echo -e "\n[*] Menghapus file skrip..."
read -p "Apakah Anda ingin menghapus file menu.sh, ws.py, autokill.sh, dan install.sh? (y/n): " hapus_file
if [[ "$hapus_file" =~ ^[Yy]$ ]]; then
    rm -f /root/natssh/menu.sh /root/natssh/ws.py /root/natssh/autokill.sh /root/natssh/install.sh /root/natssh/autokill_v2.sh /root/natssh/autobackup.sh /root/natssh/uninstall.sh /root/natssh/promo_rotate.sh /root/natssh/sess_audit.py /root/natssh/reap.py /root/natssh/audit_kill.py /root/natssh/ws_match.py /root/natssh/generate_cdn_geo.sh
    read -p "Hapus juga data (issue.net, ws.log, autokill.log, backup, slot banner, conf)? (y/N): " hapus_data
    if [[ "$hapus_data" =~ ^[Yy]$ ]]; then
        rm -f /etc/issue.net /root/natssh/logs/autokill.log /root/backup_akun_ssh.sh
        rm -rf /root/natssh/banners /root/natssh/logs/ws.log /etc/nginx/ssl /root/.acme.sh
        rm -f /root/natssh/config/host.conf /root/natssh/config/port.conf /root/natssh/config/ip.conf /root/natssh/config/hide_ip.conf /root/natssh/config/suspend_minutes.conf /root/natssh/config/cdn_geo.conf /root/natssh/config/cf_ips.cache /root/natssh/config/cfront_ips.cache /root/natssh/config/host_cf.conf /root/natssh/config/.env
        rm -rf /root/natssh/limits /root/natssh/logs/conns.json /root/natssh/logs/audit_state.json /root/natssh/logs/audit_sess.log /root/natssh/logs/api.log /root/natssh/logs/autobackup.log /root/natssh/logs/promo.log /root/natssh/config/promo
        echo -e "${GREEN}Data banner/log/backup terhapus.${NC}"
    else
        echo -e "${YELLOW}Data dipertahankan.${NC}"
    fi
    echo -e "${GREEN}File skrip berhasil dihapus dari direktori natssh.${NC}"
else
    echo -e "${YELLOW}File skrip tetap dipertahankan.${NC}"
fi

echo -e "\n${CYAN}================================================${NC}"
echo -e "${GREEN} UNINSTALL SELESAI!                             ${NC}"
echo -e "${CYAN}================================================${NC}"
