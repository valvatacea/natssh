#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

while true; do
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${YELLOW}   MENU MANAJEMEN SSH VPN (v2.0)      ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo -e "${CYAN}[ MANAJEMEN AKUN ]${NC}"
    echo "1. Buat Akun SSH Baru"
    echo "2. Hapus Akun SSH"
    echo "3. Perpanjang Masa Aktif Akun"
    echo "4. Cek Daftar Semua Akun SSH & Kedaluwarsa"
    echo -e "${CYAN}[ FITUR LANJUTAN ]${NC}"
    echo "5. Kunci Akun Sementara (Suspend)"
    echo "6. Buka Kunci Akun (Unsuspend)"
    echo "7. Bersihkan Semua Akun Kedaluwarsa (Auto-Clean)"
    echo -e "${CYAN}[ MONITORING & SISTEM ]${NC}"
    echo "8. Cek User Yang Sedang Login"
    echo "9. Autokill (Tendang Multi-Login)"
    echo "10. Info RAM & CPU VPS"
    echo -e "${RED}11. Keluar${NC}"
    echo -e "${GREEN}======================================${NC}"
    read -p "Pilih menu (1-11): " menu
    echo ""

    case $menu in
        1)
            read -p "Masukkan Username : " user
            if id "$user" &>/dev/null; then
                echo -e "${RED}Gagal: Username sudah ada!${NC}"
            else
                read -p "Masukkan Password : " pass
                read -p "Masa Aktif (Hari) : " aktif
                exp=$(date -d "$aktif days" +"%Y-%m-%d")
                useradd -e "$exp" -m -s /bin/false "$user"
                echo "$user:$pass" | chpasswd
                echo -e "${GREEN}SUKSES! Akun $user berhasil dibuat.${NC} Expired: $exp"
            fi
            ;;
        2)
            read -p "Masukkan Username yg dihapus: " user
            if id "$user" &>/dev/null; then
                userdel -r "$user"
                echo -e "${GREEN}SUKSES! Akun $user telah dihapus beserta datanya.${NC}"
            else
                echo -e "${RED}Gagal: Username tidak ditemukan!${NC}"
            fi
            ;;
        3)
            read -p "Masukkan Username : " user
            if id "$user" &>/dev/null; then
                read -p "Tambah Masa Aktif (Hari) : " aktif
                exp=$(date -d "$aktif days" +"%Y-%m-%d")
                chage -E "$exp" "$user"
                echo -e "${GREEN}SUKSES! Masa aktif $user diperpanjang hingga $exp.${NC}"
            else
                echo -e "${RED}Gagal: Username tidak ditemukan!${NC}"
            fi
            ;;
        4)
            echo -e "${YELLOW}--- DAFTAR AKUN SSH & EXPIRED ---${NC}"
            awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd | while read user; do
                exp=$(chage -l $user | grep "Account expires" | awk -F": " '{print $2}')
                status=$(passwd -S $user | awk '{print $2}')
                if [ "$status" == "L" ]; then state="${RED}[LOCKED]${NC}"; else state="${GREEN}[AKTIF]${NC}"; fi
                echo -e "User: ${CYAN}$user${NC} | Exp: ${YELLOW}$exp${NC} $state"
            done
            ;;
        5)
            read -p "Masukkan Username yang akan dikunci: " user
            if id "$user" &>/dev/null; then
                usermod -L "$user"
                echo -e "${GREEN}SUKSES! Akun $user telah dikunci sementara.${NC}"
            else
                echo -e "${RED}Gagal: Username tidak ditemukan!${NC}"
            fi
            ;;
        6)
            read -p "Masukkan Username yang akan dibuka kuncinya: " user
            if id "$user" &>/dev/null; then
                usermod -U "$user"
                echo -e "${GREEN}SUKSES! Akun $user telah dibuka kuncinya dan bisa login kembali.${NC}"
            else
                echo -e "${RED}Gagal: Username tidak ditemukan!${NC}"
            fi
            ;;
        7)
            echo -e "${YELLOW}Memindai akun kedaluwarsa...${NC}"
            today=$(date +%s)
            count=0
            awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd | while read user; do
                exp_date=$(chage -l $user | grep "Account expires" | awk -F": " '{print $2}')
                if [ "$exp_date" != "never" ] && [ "$exp_date" != "never" ]; then
                    exp_sec=$(date -d "$exp_date" +%s)
                    if [ $today -ge $exp_sec ]; then
                        userdel -r "$user"
                        echo -e "Menghapus akun ${RED}$user${NC} (Kedaluwarsa: $exp_date)"
                        ((count++))
                    fi
                fi
            done
            echo -e "${GREEN}Selesai! Sistem bersih dari akun kedaluwarsa.${NC}"
            ;;
        8)
            echo -e "${YELLOW}--- USER YANG SEDANG LOGIN ---${NC}"
            ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
                if id "$user" &>/dev/null; then
                     shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
                     if [ "$shell" == "/bin/false" ]; then
                         echo -e "User: ${GREEN}$user${NC} | Online di: ${RED}$count${NC} perangkat"
                     fi
                fi
            done
            ;;
        9)
            read -p "Masukkan batas maksimal login (contoh: 1 atau 2): " max_login
            echo -e "${YELLOW}Mengeksekusi pemutusan paksa (Autokill)...${NC}"
            ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
                if id "$user" &>/dev/null; then
                    shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
                    if [ "$shell" == "/bin/false" ] && [ "$count" -gt "$max_login" ]; then
                        echo -e "Menendang user ${RED}$user${NC} (login $count sesi)..."
                        pkill -u "$user" sshd
                    fi
                fi
            done
            echo -e "${GREEN}Autokill selesai!${NC}"
            ;;
        10)
            echo -e "${YELLOW}--- STATUS SISTEM ---${NC}"
            free -m | awk 'NR==2{printf "RAM Usage : %s / %s MB (%.2f%%)\n", $3,$2,$3*100/$2 }'
            top -bn1 | grep load | awk '{printf "CPU Load  : %.2f\n", $(NF-2)}'
            ;;
        11)
            echo "Keluar dari menu."
            break
            ;;
        *)
            echo -e "${RED}Pilihan tidak valid!${NC}"
            ;;
    esac
    echo ""
    read -n 1 -s -r -p "Tekan Enter untuk kembali ke menu..."
done
