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

echo -e "
[*] Menghapus Cronjob Autokill..."
# Membuat backup crontab sementara, menghapus baris autokill, lalu memulihkan
crontab -l | grep -v "autokill.sh" | crontab -
echo -e "${GREEN}Cronjob berhasil dihapus.${NC}"

echo -e "
[*] Menghapus file skrip..."
read -p "Apakah Anda ingin menghapus file menu.sh, ws.py, autokill.sh, dan install.sh? (y/n): " hapus_file
if [[ "$hapus_file" =~ ^[Yy]$ ]]; then
    rm -f menu.sh ws.py autokill.sh install.sh autokill_v2.sh
    echo -e "${GREEN}File skrip berhasil dihapus dari direktori saat ini.${NC}"
else
    echo -e "${YELLOW}File skrip tetap dipertahankan.${NC}"
fi

echo -e "
${CYAN}================================================${NC}"
echo -e "${GREEN} UNINSTALL SELESAI!                             ${NC}"
echo -e "${CYAN}================================================${NC}"
