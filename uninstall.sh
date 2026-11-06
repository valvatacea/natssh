#!/bin/bash
# Uninstaller for natssh (SSH WebSocket Proxy & Autokill)

RED='[0;31m'
GREEN='[0;32m'
YELLOW='[0;33m'
CYAN='[0;36m'
NC='[0m'

echo -e "${CYAN}================================================${NC}"
echo -e "${YELLOW}   UNINSTALL NATSSH (WebSocket Proxy & Autokill)  ${NC}"
echo -e "${CYAN}================================================${NC}"

# Cek apakah dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Tolong jalankan skrip ini sebagai root (sudo -i).${NC}"
  exit 1
fi

echo -e "
[*] Menghentikan dan menghapus Service natssh-ws..."
systemctl stop natssh-ws.service 2>/dev/null
systemctl disable natssh-ws.service 2>/dev/null
rm -f /etc/systemd/system/natssh-ws.service
systemctl daemon-reload
echo -e "${GREEN}Service berhasil dihapus.${NC}"

echo -e "\n[*] Menghentikan dan menghapus Service natssh-udpgw template..."
for pp in 7100 7200 7300 7400 7500; do
    systemctl disable --now natssh-udpgw@${pp} 2>/dev/null
done
rm -f /etc/systemd/system/natssh-udpgw@.service
systemctl daemon-reload

crontab -l | grep -v "unsuspend.sh" | crontab - 2>/dev/null
crontab -l | grep -v "autobackup.sh" | crontab - 2>/dev/null
rm -rf /root/natssh/suspended

echo -e "\n[*] Menghapus Cronjob Autokill..."
# Membuat backup crontab sementara, menghapus baris autokill, lalu memulihkan
crontab -l | grep -v "autokill.sh" | crontab -
echo -e "${GREEN}Cronjob berhasil dihapus.${NC}"

echo -e "[*] Menonaktifkan Banner SSH..."
if grep -qE "^\s*Banner" /etc/ssh/sshd_config; then
    sed -i "/^\s*Banner/d" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
fi
echo -e "${GREEN}Banner SSH dinonaktifkan.${NC}"

echo -e ""
echo -e "[*] Menghapus file skrip..."
read -p "Apakah Anda ingin menghapus file menu.sh, ws.py, autokill.sh, dan install.sh? (y/n): " hapus_file
if [[ "$hapus_file" =~ ^[Yy]$ ]]; then
    rm -f menu.sh ws.py autokill.sh install.sh autokill_v2.sh autobackup.sh unsuspend.sh
    read -p "Hapus juga data (issue.net, ws.log, autokill.log, backup, slot banner, conf)? (y/N): " hapus_data
    if [[ "$hapus_data" =~ ^[Yy]$ ]]; then
        rm -f /etc/issue.net /root/autokill.log /root/backup_akun_ssh.sh
        rm -rf /root/natssh/banners /root/natssh/ws.log
        rm -f /root/natssh/host.conf /root/natssh/port.conf /root/natssh/ip.conf /root/natssh/hide_ip.conf /root/natssh/suspend_minutes.conf
        rm -rf /root/natssh/limits /root/natssh/conns.json /root/natssh/audit_state.json /root/natssh/audit_sess.log
        echo -e "${GREEN}Data banner/log/backup terhapus.${NC}"
    else
        echo -e "${YELLOW}Data dipertahankan.${NC}"
    fi
    echo -e "${GREEN}File skrip berhasil dihapus dari direktori saat ini.${NC}"
else
    echo -e "${YELLOW}File skrip tetap dipertahankan.${NC}"
fi

echo -e "
${CYAN}================================================${NC}"
echo -e "${GREEN} UNINSTALL SELESAI!                             ${NC}"
echo -e "${CYAN}================================================${NC}"
