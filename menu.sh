#!/bin/bash
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[0;33m'
CYAN='[0;36m'
NC='[0m'

while true; do
    clear
    echo -e "${GREEN}======================================${NC}"
    echo -e "${YELLOW}   MENU MANAJEMEN SSH VPN (v3.0)      ${NC}"
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
    echo -e "${CYAN}[ MONITORING & LOG ]${NC}"
    echo "8. Cek User Yang Sedang Login"
    echo "9. Autokill (Tendang Multi-Login)"
    echo "10. Cek Riwayat Autokill (Log File)"
    echo "11. Info RAM & CPU VPS"
    echo -e "${CYAN}[ DATABASE ]${NC}"
    echo "12. Backup Data Akun (Ekspor Portabel)"
    echo -e "${RED}13. Keluar${NC}"
    echo -e "${GREEN}======================================${NC}"
    read -p "Pilih menu (1-13): " menu
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
            echo -e "${YELLOW}--- 20 RIWAYAT AUTOKILL TERAKHIR ---${NC}"
            if [ -f "/root/autokill.log" ]; then
                tail -n 20 /root/autokill.log
            else
                echo -e "${RED}Belum ada riwayat autokill saat ini.${NC}"
            fi
            ;;
        11)
            echo -e "${YELLOW}--- STATUS SISTEM ---${NC}"
            free -m | awk 'NR==2{printf "RAM Usage : %s / %s MB (%.2f%%)\n", $3,$2,$3*100/$2 }'
            top -bn1 | grep load | awk '{printf "CPU Load  : %.2f\n", $(NF-2)}'
            ;;
        12)
            echo -e "${YELLOW}Membuat cadangan (Backup) data akun SSH...${NC}"
            backup_file="/root/backup_akun_ssh.sh"
            
            echo "#!/bin/bash" > $backup_file
            echo "# SCRIPT RESTORE AKUN SSH VPN" >> $backup_file
            echo "# Tanggal Backup: $(date)" >> $backup_file
            echo "" >> $backup_file
            
            awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd | while read user; do
                # Ambil hash password asli yang sudah terenkripsi dari shadow
                hash=$(grep "^${user}:" /etc/shadow | cut -d: -f2)
                
                # Ambil tanggal kedaluwarsa dari shadow (dalam hitungan hari sejak 1 Jan 1970)
                exp_days=$(grep "^${user}:" /etc/shadow | cut -d: -f8)
                
                if [ -n "$exp_days" ]; then
                    # Konversi hitungan hari ke format YYYY-MM-DD
                    exp_date=$(date -d "1970-01-01 + $exp_days days" +"%Y-%m-%d" 2>/dev/null)
                    if [ $? -eq 0 ]; then
                        echo "useradd -e "$exp_date" -m -s /bin/false "$user"" >> $backup_file
                    else
                        echo "useradd -m -s /bin/false "$user"" >> $backup_file
                    fi
                else
                    echo "useradd -m -s /bin/false "$user"" >> $backup_file
                fi
                
                # Terapkan hash password kembali menggunakan usermod
                echo "usermod -p '$hash' "$user"" >> $backup_file
            done
            
            chmod +x $backup_file
            echo -e "${GREEN}SUKSES! Data seluruh akun dan kata sandi berhasil diekstrak.${NC}"
            echo -e "File cadangan tersimpan di: ${CYAN}$backup_file${NC}"
            echo -e "💡 ${YELLOW}Cara Pakai:${NC} Pindahkan file ini ke VPS baru Anda, lalu jalankan perintah ${CYAN}./backup_akun_ssh.sh${NC} untuk memulihkan semua akun beserta masa aktifnya."
            ;;
        13)
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
