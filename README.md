# 🚀 SSH WebSocket Proxy & Manajemen Lengkap (Khusus VPS NAT)

Solusi komprehensif, ringan, dan aman untuk lingkungan **VPS NAT** dengan port terbatas. Proyek ini membungkus koneksi SSH bawaan sistem menjadi lalu lintas WebSocket (WS) agar dapat melewati proksi Cloudflare, dilengkapi menu interaktif untuk manajemen akun, dan fitur pemutus koneksi otomatis (Autokill) guna mencegah *multi-login*.

## 🌟 Fitur Utama
- **Manajemen Akun Lanjutan (`menu.sh`):** Menu interaktif terminal untuk membuat, menghapus, memperpanjang masa aktif, memantau *login* aktif, dan mengecek RAM/CPU.
- **Fitur Ekstra Admin:** Mengunci sementara akun (Suspend), membuka kunci (Unsuspend), dan menghapus otomatis seluruh akun yang kedaluwarsa (Auto-Clean).
- **Bypass Cloudflare (`ws.py`):** Menerima lalu lintas WebSocket dari port NAT (Cloudflare) dan meneruskannya ke port lokal SSH.
- **Autokill Otomatis (`autokill.sh`):** Memonitor via Cronjob dan memutus paksa sesi pengguna yang *login* lebih dari batas maksimal perangkat.
- **100% Aman untuk VPS NAT:** Tidak menginstal aplikasi eksternal yang berisiko merusak port Xray atau panel 3X-UI.

---

## 🛠️ Prasyarat
1. VPS Linux (Ubuntu/Debian) dengan akses Root.
2. Python 3 terinstal secara bawaan.
3. Minimal **2 Port NAT kosong** (Satu untuk proxy Cloudflare, satu lagi untuk SSH lokal).
4. Akun Cloudflare yang sudah terhubung dengan domain Anda.

---

## 📖 Panduan Instalasi

### 1. Konfigurasi Menu Manajemen Interaktif (Bash)
Script ini menyediakan antarmuka terminal untuk mengelola semua akun SSH Anda.

1. Buka terminal VPS dan buat file baru:
   ```bash
   nano menu.sh
   ```
2. Salin dan tempel kode berikut:
   ```bash
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
   ```
3. Berikan izin eksekusi dan jalankan menu:
   ```bash
   chmod +x menu.sh
   ./menu.sh
   ```

### 2. Konfigurasi WebSocket Proxy (Python)
Script ini berfungsi sebagai jembatan antara port eksternal (Cloudflare) dan port internal (SSH).

1. Buat file baru:
   ```bash
   nano ws.py
   ```
2. Salin dan tempel kode berikut:
   ```python
   import socket
   import threading

   WS_PORT = 20865     # GANTI dengan Port NAT kosong untuk Cloudflare
   SSH_PORT = 20861    # GANTI dengan Port SSH lokal Anda

   def forward(src, dst):
       try:
           while True:
               data = src.recv(4096)
               if not data: break
               dst.send(data)
       except: pass
       finally:
           src.close()
           dst.close()

   def handle_client(client_socket):
       try:
           request = client_socket.recv(4096).decode('utf-8', errors='ignore')
           if 'HTTP' in request:
               response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
               client_socket.send(response.encode())
           
           ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
           ssh_socket.connect(('127.0.0.1', SSH_PORT))
           
           threading.Thread(target=forward, args=(client_socket, ssh_socket)).start()
           threading.Thread(target=forward, args=(ssh_socket, client_socket)).start()
       except:
           client_socket.close()

   if __name__ == '__main__':
       server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
       server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
       server.bind(('0.0.0.0', WS_PORT))
       server.listen(100)
       print(f"[*] WebSocket Proxy: Port {WS_PORT} -> SSH Port {SSH_PORT}")
       
       while True:
           client, addr = server.accept()
           threading.Thread(target=handle_client, args=(client,)).start()
   ```
3. Jalankan script secara permanen di latar belakang:
   ```bash
   nohup python3 ws.py > /dev/null 2>&1 &
   ```

### 3. Konfigurasi Autokill Latar Belakang (Cronjob)
Meskipun Menu no. 9 memiliki fitur Autokill manual, script ini berjalan otomatis setiap 2 menit.

1. Buat file script:
   ```bash
   nano autokill.sh
   ```
2. Salin dan tempel kode berikut:
   ```bash
   #!/bin/bash
   MAX_LOGIN=5 # Batas maksimal perangkat

   ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
       if id "$user" &>/dev/null; then
           shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
           if [ "$shell" == "/bin/false" ] && [ "$count" -gt "$MAX_LOGIN" ]; then
               pkill -u "$user" sshd
               echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang: $user ($count sesi)" >> /root/autokill.log
           fi
       fi
   done
   ```
3. Masukkan ke dalam Cronjob:
   ```bash
   chmod +x autokill.sh
   crontab -e
   ```
   Tambahkan baris berikut di paling bawah dokumen:
   ```bash
   */2 * * * * /root/autokill.sh
   ```

### 4. Pengaturan Cloudflare (Origin Rules)
Agar nama domain bisa digunakan, arahkan lalu lintas ke port WebSocket (Python) Anda:
1. Buka dashboard Cloudflare -> **Rules** -> **Origin Rules**.
2. Buat aturan baru: 
   - **Field:** Hostname | **Operator:** equals | **Value:** `ssh.domainanda.com`
   - **Action:** Rewrite to port `20864` (Sesuaikan dengan `WS_PORT` di file `ws.py`).
3. Pastikan DNS `ssh.domainanda.com` berstatus **Proxied (Awan Oranye)**.

---

## 📱 Contoh Konfigurasi Klien (HTTP Custom)

Untuk menyambungkan aplikasi VPN di HP, gunakan konfigurasi berikut:

- **SSH Host/IP:** `ssh.domainanda.com`
- **SSH Port:** `443` (Port HTTPS standar Cloudflare)
- **Username & Password:** Gunakan akun SSH yang sudah dibuat (contoh: `vpnuser`)
- **Payload WebSocket:**
  ```text
  GET / HTTP/1.1[crlf]Host: ssh.domainanda.com[crlf]Upgrade: websocket[crlf]Connection: Keep-Alive[crlf][crlf]
  ```
- **SNI (Server Name Indication):** `ssh.domainanda.com`
- Aktifkan fitur **Enable DNS** dan **Use Payload**.