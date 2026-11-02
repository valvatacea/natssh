#!/bin/bash
# NATSSH Menu v4.0 — utama 4 kategori + submenu
# Konvensi: akun jualan = shell /bin/false; 1 sesi tunnel = 2 proses sshd (hitungan /2)

RED='\u001b[0;31m'
GREEN='\u001b[0;32m'
YELLOW='\u001b[0;33m'
CYAN='\u001b[0;36m'
NC='\u001b[0m'

port_ws() {
    # port WebSocket running — ss menampilkan nama proses "python3", bukan ws.py,
    # maka cocokkan via PID: hasil kosong = service tak berjalan
    local wpid
    wpid=$(pgrep -f "ws.py" | head -1)
    [ -n "$wpid" ] || return 1
    ss -tlnp 2>/dev/null | grep "pid=$wpid," | awk '{print $4}' | awk -F: '{print $NF}' | head -1
}

garis() { echo -e "${GREEN}======================================${NC}"; }
pause()  { echo ""; read -r -p "Tekan Enter untuk kembali..." _ || true; }
# catatan: JANGAN read -n 1 — sisakan newline di buffer, read berikutnya can baris kosong = "batal" palsu

# ══════════ AKUN ══════════

akun_baru() {
    read -p "Masukkan Username (0 = batal): " user
    if [ "$user" == "0" ]; then echo -e "${YELLOW}Dibatalkan.${NC}"; return; fi
    if id "$user" &>/dev/null; then
        echo -e "${RED}Gagal: Username sudah ada!${NC}"
    else
        read -s -p "Masukkan Password (0 = batal): " pass; echo ""
        if [ "$pass" == "0" ]; then echo -e "${YELLOW}Dibatalkan.${NC}"; return; fi
        read -p "Masa Aktif (Hari) (0 = batal): " aktif
        if [ "$aktif" == "0" ]; then echo -e "${YELLOW}Dibatalkan.${NC}"; return; fi
        if [ -z "$pass" ] || [ ${#pass} -lt 6 ] || ! [[ "$aktif" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Gagal: password minimal 6 karakter & hari harus angka!${NC}"
        else
            exp=$(date -d "$aktif days" +"%Y-%m-%d")
            useradd -e "$exp" -m -s /bin/false "$user"
            echo "$user:$pass" | chpasswd
            # Detail siap-salin untuk dikirim ke pelanggan
            # host.conf  = domain Cloudflare (recommended) / IP utk koneksi langsung
            # port.conf  = port Cloudflare yg dipakai klien (default 2086); asal via Origin Rule ke port NAT
            ipaddr=$(cat /root/natssh/ip.conf 2>/dev/null || curl -s -m 3 ifconfig.me 2>/dev/null)
            ipaddr=${ipaddr:-$(hostname -I | awk '{print $1}')}
            host=$(cat /root/natssh/host.conf 2>/dev/null)
            wsport=$(port_ws)
            cfport=$(cat /root/natssh/port.conf 2>/dev/null)
            cfport=${cfport:-2086}
            maxlog=$(crontab -l | grep -o "MAX_LOGIN=[0-9]*" | head -1 | cut -d= -f2)
            echo -e "${GREEN}SUKSES! Akun $user berhasil dibuat.${NC}"
            echo ""
            echo "================ DETAIL AKUN ================"
            # host = IP kalau domain tak didefinisikan -> cukup tampilkan sekali di baris IP
            [ -z "$host" ] && host="$ipaddr"
            if [ "$host" != "$ipaddr" ]; then
                echo "Domain    : $host"
            fi
            local hostcf=$(cat /root/natssh/host_cf.conf 2>/dev/null)
            [ -n "$hostcf" ] && echo "Domain CF : $hostcf"
            echo "IP        : $ipaddr"
            echo "Port WS   : $cfport (via Cloudflare)"
            echo "Cloudflare: 80, 8080, 8880, 2052, 2082, 2086, 2095 | TLS: 443, 2053, 2083, 2087, 2096, 8443"
            echo "CloudFront: 80, 443, 2052, 2053, 2082, 2083, 2086, 2087, 2095, 2096, 8443 (HTTPS)"
            echo "Port NAT  : ${wsport:-20865} (cadangan, koneksi langsung tanpa Cloudflare)"
            echo "Username  : $user"
            echo "Password  : $pass"
            echo "Expired   : $exp ($aktif hari)"
            echo "Limit     : ${maxlog:-5} perangkat"
            echo "============================================"
            echo "(blok di atas siap disalin & dikirim ke pelanggan)"
        fi
    fi
}

do_hapus() {
    local user="$1"
    local exp=$(chage -l "$user" | grep "Account expires" | awk -F": " '{print $2}')
    local online=$(ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | grep -c "^$user$")
    echo -e "${YELLOW}Akan dihapus: ${CYAN}$user${NC} (Expired: $exp, online: ${online} perangkat)"
    read -p "Yakin hapus? (y/N): " yakin
    if [[ "$yakin" =~ ^[Yy]$ ]]; then
        res=$(userdel -r "$user" 2>&1); rc=$?
        # "mail spool not found" hanya notice (tak ada mailbox), bukan error — disembunyikan
        warn=$(echo "$res" | grep -v "mail spool" || true)
        [ -n "$warn" ] && echo -e "${YELLOW}Peringatan: $warn${NC}"
        if [ $rc -eq 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - HAPUS manual: $user (expired: $exp)" >> /root/autokill.log
            echo -e "${GREEN}SUKSES! Akun $user telah dihapus beserta datanya.${NC}"
        else
            echo -e "${RED}Gagal menghapus (exit $rc) — cek manual: $res${NC}"
        fi
    else
        echo -e "${YELLOW}Dibatalkan — akun tidak dihapus.${NC}"
    fi
}

pilih_akun() {
    # Cetak daftar akun jualan bernomor -> set global AKUN; return 1 bila batal/kosong/salah
    AKUN=""
    local users=()
    while read u; do users+=("$u"); done < <(awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd)
    if [ ${#users[@]} -eq 0 ]; then
        echo -e "${RED}Tidak ada akun jualan.${NC}"
        return 1
    fi
    echo -e "${YELLOW}--- DAFTAR AKUN ---${NC}"
    local i u exp status st
    for i in "${!users[@]}"; do
        u=${users[$i]}
        exp=$(chage -l "$u" | grep "Account expires" | awk -F": " '{print $2}')
        status=$(passwd -S "$u" | awk '{print $2}')
        st=""; [ "$status" == "L" ] && st=" ${RED}[LOCKED]${NC}"
        echo -e "$((i+1)). ${CYAN}$u${NC} | Exp: ${YELLOW}$exp${NC}$st"
    done
    read -p "$1 (nomor / username, 0 = batal): " pilih
    [ -z "$pilih" ] && return 1
    [ "$pilih" == "0" ] && return 1
    if [[ "$pilih" =~ ^[0-9]+$ ]]; then
        if [ "$pilih" -ge 1 ] && [ "$pilih" -le ${#users[@]} ]; then
            AKUN=${users[$((pilih-1))]}
        else
            echo -e "${RED}Gagal: nomor $pilih di luar daftar!${NC}"
            return 1
        fi
    else
        AKUN="$pilih"
    fi
    if ! id "$AKUN" &>/dev/null; then
        echo -e "${RED}Gagal: Username tidak ditemukan!${NC}"
        return 1
    fi
    return 0
}

do_perpanjang() {
    # Dihitung dari tanggal expired AKUN (bukan hari ini) — sisa pelanggan tak hangus
    local user="$1"
    read -p "Tambah Masa Aktif (Hari) (0 = batal): " aktif
    [ "$aktif" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if ! [[ "$aktif" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Gagal: jumlah hari harus angka!${NC}"
        return
    fi
    local cur_exp=$(chage -l "$user" | grep "Account expires" | awk -F": " '{print $2}')
    local base=$(date +%s)
    if [ "$cur_exp" != "never" ] && [ -n "$cur_exp" ]; then
        local exp_sec=$(date -d "$cur_exp" +%s 2>/dev/null || echo 0)
        [ "$exp_sec" -gt "$base" ] && base=$exp_sec
    fi
    local exp=$(date -d "@$(( base + aktif * 86400 ))" +"%Y-%m-%d")
    chage -E "$exp" "$user"
    echo -e "${GREEN}SUKSES! Masa aktif $user diperpanjang hingga $exp.${NC}"
}

akun_daftar() {
    # Pusat kelola: daftar bernomor -> pilih akun -> aksi suspend/unsuspend/perpanjang/hapus
    while true; do
        pilih_akun "Kelola akun" || return
        local user="$AKUN"
        local exp status
        exp=$(chage -l "$user" | grep "Account expires" | awk -F": " '{print $2}')
        status=$(passwd -S "$user" | awk '{print $2}')
        [ "$status" == "L" ] && st="${RED}LOCKED${NC}" || st="${GREEN}AKTIF${NC}"
        echo -e ""
        echo -e "Akun: ${CYAN}$user${NC} | Exp: ${YELLOW}$exp${NC} | Status: $st"
        echo -e "${CYAN}--- AKSI ---${NC}"
        echo "1. Suspend"
        echo "2. Unsuspend"
        echo "3. Perpanjang"
        echo "4. Hapus"
        echo "5. Batas Login Khusus Akun Ini"
        echo -e "${RED}0. Kembali ke daftar${NC}"
        read -p "Aksi (0-5): " a || exit 0
        case $a in
            1) do_suspend "$user"; pause; continue ;;
            2) do_unsuspend "$user"; pause; continue ;;
            3) do_perpanjang "$user"; pause; continue ;;
            4) do_hapus "$user"; pause; continue ;;
            5) do_limit "$user"; pause; continue ;;
            0) continue ;;   # kembali ke DAFTAR (label), bukan keluar browser
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
    done
}

do_limit() {
    local selfdir=$(dirname "$(readlink -f "$0")")
    local lfile="$selfdir/limits/$1"
    local global=$(crontab -l 2>/dev/null | grep -o "MAX_LOGIN=[0-9]*" | head -1 | cut -d= -f2)
    global=${global:-5}
    local khusus="" 
    [ -f "$lfile" ] && khusus=$(cat "$lfile" 2>/dev/null)
    echo -e "Batas login global : ${YELLOW}${global}${NC} perangkat"
    if [ -n "$khusus" ]; then
        local disp="${khusus} perangkat (aktif)"
        [ "$khusus" == "unlimited" ] && disp="TANPA BATAS (aktif)"   # toleransi file manual
        echo -e "Batas khusus akun  : ${GREEN}${disp}${NC}"
    else
        echo -e "Batas khusus akun  : ${YELLOW}— (ikut global)${NC}"
    fi
    read -p "Nilai baru (angka bebas; di bawah 1 / kosong = ikut global ${global}): " n
    if [[ "$n" =~ ^-?[0-9]+$ ]] && [ "$n" -lt 1 ]; then
        rm -f "$lfile"
        echo -e "${GREEN}Di bawah 1 → akun ini ikut global (${global} perangkat).${NC}"
        return
    fi
    if [ -z "$n" ]; then
        rm -f "$lfile"
        echo -e "${GREEN}Batas khusus dihapus — akun ini kembali ikut global (${global}).${NC}"
        return
    fi
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Gagal: harus angka!${NC}"
        return
    fi
    mkdir -p "$selfdir/limits"
    echo "$n" > "$lfile"
    local nn="$n perangkat"
    echo -e "${GREEN}SUKSES! Batas khusus akun $1: ${nn} (autokill pakai ini, bukan global ${global}).${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - LIMIT: batas khusus $1 = $n perangkat (global $global)" >> /root/autokill.log
}

do_suspend() {
    usermod -L "$1"
    echo -e "${GREEN}SUKSES! Akun $1 dikunci (suspend) — pelanggan tak bisa login.${NC}"
}

do_unsuspend() {
    usermod -U "$1"
    echo -e "${GREEN}SUKSES! Akun $1 dibuka kuncinya — bisa login kembali.${NC}"
}

akun_autoclean() {
    echo -e "${YELLOW}Memindai akun kedaluwarsa...${NC}"
    today=$(date +%s)
    count=0
    while read user; do
        exp_date=$(chage -l "$user" | grep "Account expires" | awk -F": " '{print $2}')
        if [ -n "$exp_date" ] && [ "$exp_date" != "never" ]; then
            exp_sec=$(date -d "$exp_date" +%s 2>/dev/null) || continue
            if [ "$today" -ge "$exp_sec" ]; then
                userdel -r "$user"
                echo -e "Menghapus akun ${RED}$user${NC} (Kedaluwarsa: $exp_date)"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - AUTO-CLEAN hapus $user (kedaluwarsa: $exp_date)" >> /root/autokill.log
                ((count++))
            fi
        fi
    done < <(awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd)
    echo -e "${GREEN}Selesai! $count akun kedaluwarsa dihapus (tercatat di /root/autokill.log).${NC}"
}

menu_akun() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   MANAJEMEN AKUN SSH${NC}"
        garis
        echo "1. Buat Akun SSH Baru"
        echo "2. Daftar Akun (kelola: suspend/unsuspend/perpanjang/hapus)"
        echo "3. Bersihkan Akun Kedaluwarsa (Auto-Clean)"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-3): " p || exit 0
        case $p in
            1) akun_baru ;;
            2) akun_daftar ;;
            3) akun_autoclean ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        # browser akun (2) mengelola pause-nya sendiri — 0 = kembali instan, tanpa pause ekstra
        [ "$p" != "0" ] && [ "$p" != "2" ] && pause
    done
}

# ══════════ MONITORING ══════════

sessi_online() {
    echo -e "${YELLOW}--- USER YANG SEDANG LOGIN ---${NC}"
    ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
        if id "$user" &>/dev/null; then
            shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
            if [ "$shell" == "/bin/false" ]; then
                echo -e "User: ${GREEN}$user${NC} | Online: ${RED}${count}${NC} perangkat"
            fi
        fi
    done
}

autokill_manual() {
    read -p "Batas maksimal perangkat untuk eksekusi ini (contoh: 1 atau 2): " max_login
    echo -e "${YELLOW}Mengeksekusi pemutusan paksa (Autokill)...${NC}"
    ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | while read count user; do
        if id "$user" &>/dev/null; then
            shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
            devices=$count   # 1 sesi tunnel = 1 proses user-owned (pasangan [priv] milik root)
            if [ "$shell" == "/bin/false" ] && [ "$devices" -gt "$max_login" ]; then
                echo -e "Menendang user ${RED}$user${NC} ($devices perangkat)..."
                pkill -u "$user" sshd
            fi
        fi
    done
    echo -e "${GREEN}Autokill selesai!${NC}"
}

autokill_riwayat() {
    echo -e "${YELLOW}--- 20 RIWAYAT AUTOKILL TERAKHIR ---${NC}"
    if [ -f "/root/autokill.log" ]; then
        tail -n 20 /root/autokill.log
    else
        echo -e "${RED}Belum ada riwayat autokill saat ini.${NC}"
    fi
}

status_sistem() {
    echo -e "${YELLOW}--- STATUS SISTEM ---${NC}"
    free -m | awk 'NR==2{printf "RAM Usage : %s / %s MB (%.2f%%)\n", $3,$2,$3*100/$2 }'
    top -bn1 | grep load | awk '{printf "CPU Load  : %.2f\n", $(NF-2)}'
    echo -e "Disk      : $(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
}

ws_peak() {
    # puncak pemakaian slot jembatan (dari ws.log) — bantu keputusan naik/turun MAX_TOTAL
    local log=$(dirname "${BASH_SOURCE[0]}")/ws.log
    if [ ! -f "$log" ]; then
        echo -e "${RED}Belum ada log ws.log.${NC}"
        return
    fi
    local t peak=0 tolak=0
    peak=$(grep -o "total=[0-9]*" "$log" | cut -d= -f2 | sort -n | tail -1)
    peak=${peak:-0}
    tolak=$(grep -c "TOLAK" "$log")
    local cur_max=$(systemctl show natssh-ws -p Environment --value 2>/dev/null | grep -o "NATSSH_MAX_TOTAL=[0-9]*" | cut -d= -f2)
    cur_max=${cur_max:-30}
    echo -e "${YELLOW}--- PUNCAK KONEKSI WEBSOCKET ---${NC}"
    echo -e "Puncak serentak : ${GREEN}${peak}${NC} slot"
    echo -e "Batas kini      : ${YELLOW}${cur_max}${NC} slot (NATSSH_MAX_TOTAL)"
    echo -e "Klok TOLAK      : ${RED}${tolak}${NC}x"
    if [ "$peak" -ge $(( cur_max * 80 / 100 )) ]; then
        echo -e "${RED}Puncak >= 80% batas — pertimbangkan naikkan (Konfigurasi > 5).${NC}"
    fi
}

ws_peruser() {
    # Sanding waktu: sesi "sshd: user" (lstart) <-> koneksi bridge (conns.json:
    # IP asli, aplikasi, durasi, byte up/down; fallback ws.log pra-patch).
    # Username SSH tak terbaca jembatan (terenkripsi post-KEX) -> -2..+10 dtk, kemungkinan.
    local dir=$(dirname "${BASH_SOURCE[0]}")
    local rows=""
    while read -r user; do
        [ -z "$user" ] && continue
        local shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
        [ "$shell" == "/bin/false" ] || continue
        for pid in $(pgrep -u "$user" sshd); do
            local st=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//')
            [ -z "$st" ] && continue
            local ep=$(date -d "$st" +%s 2>/dev/null)
            [ -z "$ep" ] && continue
            rows+="$user $ep\n"
        done
    done < <(ps -ef | grep sshd | grep -v root | grep -v grep | awk '{print $1}' | sort -u)
    if [ -z "$rows" ]; then
        echo -e "${YELLOW}Tidak ada akun jualan yang sedang online.${NC}"
        return
    fi
    echo -e "${YELLOW}--- PERANGKAT PER AKUN (korelasi waktu) ---${NC}"
    printf '%b' "$rows" | python3 "$dir/ws_match.py" "$dir/conns.json" "$dir/ws.log" "$dir/audit_sess.log"
}

menu_monitor() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   MONITORING & LOG${NC}"
        garis
        echo "1. User Sedang Login"
        echo "2. Autokill Manual (Tendang Multi-Login)"
        echo "3. Riwayat Autokill"
        echo "4. Status RAM / CPU / Disk"
        echo "5. Puncak Koneksi WebSocket (slot)"
        echo "6. Perangkat per Akun (live + riwayat sesi)"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-6): " p || exit 0
        case $p in
            1) sessi_online ;;
            2) autokill_manual ;;
            3) autokill_riwayat ;;
            4) status_sistem ;;
            5) ws_peak ;;
            6) ws_peruser ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && pause
    done
}

# ══════════ BACKUP ══════════

backup_ekspor() {
    echo -e "${YELLOW}Membuat cadangan (Backup) data akun SSH...${NC}"
    backup_file="/root/backup_akun_ssh.sh"

    echo "#!/bin/bash" > $backup_file
    echo "# SCRIPT RESTORE AKUN SSH VPN" >> $backup_file
    echo "# Tanggal Backup: $(date)" >> $backup_file
    echo "" >> $backup_file

    awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd | while read user; do
        hash=$(grep "^${user}:" /etc/shadow | cut -d: -f2)
        exp_days=$(grep "^${user}:" /etc/shadow | cut -d: -f8)
        if [ -n "$exp_days" ]; then
            exp_date=$(date -d "1970-01-01 + $exp_days days" +"%Y-%m-%d" 2>/dev/null)
            if [ $? -eq 0 ]; then
                echo "useradd -e \"$exp_date\" -m -s /bin/false \"$user\"" >> $backup_file
            else
                echo "useradd -m -s /bin/false \"$user\"" >> $backup_file
            fi
        else
            echo "useradd -m -s /bin/false \"$user\"" >> $backup_file
        fi
        echo "usermod -p '$hash' \"$user\"" >> $backup_file
    done

    chmod 700 $backup_file   # hash password klien di dalamnya — jangan world-readable
    echo -e "${GREEN}SUKSES! Data seluruh akun dan kata sandi berhasil diekstrak.${NC}"
    echo -e "File cadangan tersimpan di: ${CYAN}$backup_file${NC} (mode 700)"
    echo -e "Cara Pakai: pindahkan ke VPS baru lalu jalankan ${CYAN}./backup_akun_ssh.sh${NC}"
}

menu_backup() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   BACKUP & RESTORE${NC}"
        garis
        echo "1. Backup Data Akun (Ekspor Portabel)"
        [ -f /root/backup_akun_ssh.sh ] && echo -e "   (backup terakhir: $(stat -c '%y' /root/backup_akun_ssh.sh | cut -d. -f1))"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-1): " p || exit 0
        case $p in
            1) backup_ekspor ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && pause
    done
}

# ══════════ KONFIGURASI ══════════

conf_maxlogin() {
    cur=$(crontab -l | grep -o "MAX_LOGIN=[0-9]*" | head -1 | cut -d= -f2)
    cur=${cur:-5}
    echo -e "Batas saat ini: ${YELLOW}${cur} perangkat/akun${NC} (cron + banner pelanggan)"
    read -p "Batas perangkat baru (1-20): " max_login
    if ! [[ "$max_login" =~ ^[0-9]+$ ]] || [ "$max_login" -lt 1 ] || [ "$max_login" -gt 20 ]; then
        echo -e "${RED}Gagal: harus angka 1-20!${NC}"
    else
        local selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
        if crontab -l 2>/dev/null | grep -q "MAX_LOGIN="; then
            (crontab -l | sed "s/MAX_LOGIN=[0-9]*/MAX_LOGIN=$max_login/") | crontab -
        elif crontab -l 2>/dev/null | grep -q "autokill.sh"; then
            (crontab -l | sed "s|\(.*autokill.sh\)|MAX_LOGIN=$max_login \1|") | crontab -
        else
            # crontab kosong / tanpa autokill: TULIS baris penuh — jangan pipa kosong ke crontab
            (crontab -l 2>/dev/null; echo "*/2 * * * * MAX_LOGIN=$max_login $selfdir/autokill.sh") | crontab -
        fi
        sed -i "s/Maksimal [0-9]* Perangkat/Maksimal $max_login Perangkat/g" /etc/issue.net
        echo -e "${GREEN}SUKSES! Batas menjadi ${max_login} perangkat (cron autokill + banner diperbarui).${NC}"
    fi
}

conf_domain_cf_edit() {
    # domain CloudFront (jalur AWS) utk kartu akun; host_cf.conf — opsional
    local cur=$(cat /root/natssh/host_cf.conf 2>/dev/null)
    echo -e "Domain CloudFront saat ini: ${YELLOW}${cur:-BELUM DIATUR (baris tak tampil di kartu)}${NC}"
    read -p "Domain CloudFront baru (kosong = hapus/sembunyikan, 0 = batal): " h
    [ "$h" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if [ -z "$h" ]; then
        rm -f /root/natssh/host_cf.conf
        echo -e "${GREEN}Domain CloudFront dihapus — baris 'Domain CF' tak tampil di kartu.${NC}"
    elif ! [[ "$h" =~ ^[a-zA-Z0-9.-]{3,100}(:[0-9]+)?$ ]]; then
        echo -e "${RED}Gagal: format domain salah (contoh: dabcdefgh.cloudfront.net)!${NC}"
    else
        echo "$h" > /root/natssh/host_cf.conf
        echo -e "${GREEN}Domain CloudFront tersimpan: $h — muncul di baris 'Domain CF' kartu akun.${NC}"
    fi
}

conf_port() {
    cur_port=$(port_ws)
    if [ -z "$cur_port" ]; then
        echo -e "${RED}Service natssh-ws tidak berjalan/tak terdeteksi! Cek: systemctl status natssh-ws${NC}"
        return
    fi
    echo -e "Port WebSocket saat ini: ${YELLOW}${cur_port}${NC}"
    read -p "Port WebSocket baru: " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}Gagal: port harus angka 1-65535!${NC}"
    elif ss -tln | grep -q ":$new_port "; then
        echo -e "${RED}Gagal: port $new_port sedang dipakai proses lain!${NC}"
    else
        unit=/etc/systemd/system/natssh-ws.service
        if [ -f "$unit" ]; then
            if grep -q "Environment=NATSSH_WS_PORT" "$unit"; then
                sed -i "s/Environment=NATSSH_WS_PORT=[0-9]*/Environment=NATSSH_WS_PORT=$new_port/" "$unit"
            else
                sed -i "/^\[Service\]/a Environment=NATSSH_WS_PORT=$new_port" "$unit"
            fi
            systemctl daemon-reload
            echo -e "${YELLOW}Restart natssh-ws — koneksi aktif terputus 2-3 detik...${NC}"
            systemctl restart natssh-ws
            sleep 1
            systemctl is-active --quiet natssh-ws && \
                echo -e "${GREEN}SUKSES! WebSocket kini di port $new_port (ingat: update forwarding Cloudflare/NAT!).${NC}" || \
                echo -e "${RED}Service gagal start! Cek: journalctl -u natssh-ws -n 20${NC}"
        else
            echo -e "${RED}Gagal: unit natssh-ws.service tidak ditemukan (install dulu).${NC}"
        fi
    fi
}

conf_domain() {
    # satu pintu domain: Cloudflare (biasa) + CloudFront — dua-duanya ke kartu akun
    local cur curcf
    while true; do
        cur=$(cat /root/natssh/host.conf 2>/dev/null)
        curcf=$(cat /root/natssh/host_cf.conf 2>/dev/null)
        echo -e "${YELLOW}---- UBAH DOMAIN ----${NC}"
        echo -e "1. Domain (Cloudflare) : ${GREEN}${cur:-OTOMATIS (IP publik)}${NC}"
        echo -e "2. Domain CloudFront   : ${GREEN}${curcf:-BELUM DIATUR}${NC}"
        echo -e "${RED}0. Kembali${NC}"
        read -p "Pilih (0-2): " p || exit 0
        case $p in
            1) conf_domain_edit ;;
            2) conf_domain_cf_edit ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        pause
    done
}

conf_domain_edit() {
    # host/domain Cloudflare di kartu akun; host.conf dipakai akun_baru (fallback: IP publik)
    local cur=$(cat /root/natssh/host.conf 2>/dev/null)
    echo -e "Host kartu akun saat ini: ${YELLOW}${cur:-OTOMATIS (IP publik)}${NC}"
    read -p "Domain/host baru (kosong = otomatis IP, 0 = batal): " h
    [ "$h" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if [ -z "$h" ]; then
        rm -f /root/natssh/host.conf
        echo -e "${GREEN}Host kembali otomatis (IP publik terdeteksi saat buat akun).${NC}"
    elif ! [[ "$h" =~ ^[a-zA-Z0-9.-]{3,100}(:[0-9]+)?$ ]]; then
        echo -e "${RED}Gagal: format domain/host salah (contoh: vpn.example.com)!${NC}"
    else
        echo "$h" > /root/natssh/host.conf
        echo -e "${GREEN}Domain tersimpan: $h — dipakai otomatis di kartu akun berikutnya.${NC}"
    fi
}

conf_maxtotal() {
    # batas koneksi serentak jembatan (Environment=NATSSH_MAX_TOTAL di unit systemd)
    local unit=/etc/systemd/system/natssh-ws.service
    local cur=$(systemctl show natssh-ws -p Environment --value 2>/dev/null | grep -o "NATSSH_MAX_TOTAL=[0-9]*" | cut -d= -f2)
    cur=${cur:-30}
    local peak=$(grep -o "total=[0-9]*" "$(dirname "${BASH_SOURCE[0]}")/ws.log" 2>/dev/null | cut -d= -f2 | sort -n | tail -1)
    echo -e "Batas koneksi serentak (MAX_TOTAL) : ${YELLOW}${cur}${NC} slot"
    echo -e "Puncak pemakaian sejauh ini        : ${GREEN}${peak:-0}${NC} slot${NC}"
    read -p "Nilai baru (10-200, 0 = batal): " n
    [ "$n" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 10 ] || [ "$n" -gt 200 ]; then
        echo -e "${RED}Gagal: harus angka 10-200!${NC}"
        return
    fi
    if [ ! -f "$unit" ]; then
        echo -e "${RED}Gagal: unit natssh-ws.service tidak ditemukan.${NC}"
        return
    fi
    if grep -q "Environment=NATSSH_MAX_TOTAL" "$unit"; then
        sed -i "s/Environment=NATSSH_MAX_TOTAL=[0-9]*/Environment=NATSSH_MAX_TOTAL=$n/" "$unit"
    else
        sed -i "/^\[Service\]/a Environment=NATSSH_MAX_TOTAL=$n" "$unit"
    fi
    systemctl daemon-reload
    echo -e "${YELLOW}Restart natssh-ws — koneksi aktif terputus 2-3 detik...${NC}"
    systemctl restart natssh-ws
    sleep 1
    systemctl is-active --quiet natssh-ws &&         echo -e "${GREEN}SUKSES! MAX_TOTAL kini $n slot.${NC}" || \
        echo -e "${RED}Service gagal start! Cek: journalctl -u natssh-ws -n 20${NC}"
}

conf_banner() {
    while true; do
        echo -e "${YELLOW}--- BANNER SAAT INI (/etc/issue.net) ---${NC}"
        cat /etc/issue.net 2>/dev/null || echo "(kosong)"
        echo ""
        echo -e "${CYAN}--- AKSI BANNER ---${NC}"
        echo "1. Edit banner di editor (nano/vi)"
        echo "2. Reset ke banner bawaan"
        echo "3. Simpan banner saat ini ke slot"
        echo "4. Daftar Banner Tersimpan (muat/hapus)"
        echo "0. Kembali ke Konfigurasi Sistem"
        read -p "Pilih (0-4): " b || exit 0
        case $b in
            1)
                if command -v nano &>/dev/null; then
                    nano /etc/issue.net
                elif command -v vi &>/dev/null; then
                    vi /etc/issue.net
                else
                    echo -e "${RED}Tidak ada editor (nano/vi) terpasang!${NC}"
                fi
                pause
                ;;
            2)
                maxlog=$(crontab -l | grep -o "MAX_LOGIN=[0-9]*" | head -1 | cut -d= -f2)
                maxlog=${maxlog:-5}
                cat > /etc/issue.net <<BEOF
<br>
<center>
<font color="cyan">　　　　　　　　　　╔══════════════════════════════════╗</font><br>
<font color="yellow"><b>　　　　　　　　　　 ⚡ PREMIUM VPN SERVICE ⚡</b></font><br>
<font color="cyan">　　　　　　　　　　╠══════════════════════════════════╣</font><br>
<font color="green">　　　　　　　　　　 ✅ KONEKSI BERHASIL</font><br>
<font color="orange">　　　　　　　　　　 🌍 Server : Indonesia — Premium</font><br>
<font color="aqua">　　　　　　　　　　 🚀 Speed : up 100 Mbps</font><br>
<font color="lime">　　　　　　　　　　 📱 Maksimal ${maxlog} Perangkat/Akun</font><br>
<font color="orange">　　　　　　　　　　 ⚔ Auto-Kill AKTIF</font><br>
<font color="white">　　　　　　　　　　 ─────────────────────────────</font><br>
<font color="red">　　　　　　　　　　 ⛔ Dilarang: Torrent · DDoS · Hack</font><br>
<font color="grey">　　　　　　　　　　 🛡 Support : Hubungi Admin</font><br>
<font color="cyan">　　　　　　　　　　╚══════════════════════════════════╝</font><br>
<font color="green"><b>　　　　　　　　　　  ═══ SELAMAT MENIKMATI ═══</b></font><br>
</center>
BEOF
                echo -e "${GREEN}Banner direset ke bawaan (limit ${maxlog} perangkat).${NC}"
                pause
                ;;
            3)
                mkdir -p /root/natssh/banners
                read -p "Nama slot (huruf/angka, 1-24): " nama
                if ! [[ "$nama" =~ ^[a-zA-Z0-9_-]{1,24}$ ]]; then
                    echo -e "${RED}Gagal: nama hanya huruf/angka/-/_ maks 24!${NC}"
                elif [ -f "/root/natssh/banners/$nama.txt" ]; then
                    read -p "Slot '$nama' sudah ada — timpa? (y/N): " t
                    if [[ "$t" =~ ^[Yy]$ ]]; then
                        cp /etc/issue.net "/root/natssh/banners/$nama.txt"
                        echo -e "${GREEN}Banner tersimpan ke slot '$nama'.${NC}"
                    else
                        echo -e "${YELLOW}Dibatalkan.${NC}"
                    fi
                else
                    cp /etc/issue.net "/root/natssh/banners/$nama.txt"
                    echo -e "${GREEN}Banner tersimpan ke slot '$nama'.${NC}"
                fi
                pause
                ;;
            4)
                local dir=/root/natssh/banners
                local files=()
                for f in "$dir"/*.txt; do [ -f "$f" ] && files+=("$f"); done
                if [ ${#files[@]} -eq 0 ]; then
                    echo -e "${RED}Belum ada slot tersimpan.${NC}"
                    pause
                    continue
                fi
                while true; do
                    files=()
                    for f in "$dir"/*.txt; do [ -f "$f" ] && files+=("$f"); done
                    if [ ${#files[@]} -eq 0 ]; then
                        echo -e "${RED}Tidak ada slot tersimpan.${NC}"
                        break
                    fi
                    echo -e "${YELLOW}--- DAFTAR BANNER TERSIMPAN ---${NC}"
                    local i
                    for i in "${!files[@]}"; do
                        local nm=$(basename "${files[$i]}" .txt)
                        local tgl=$(stat -c '%y' "${files[$i]}" | cut -d. -f1)
                        echo -e "$((i+1)). ${CYAN}$nm${NC} ($tgl)"
                    done
                    read -p "Pilih slot nomor (0 = kembali): " p || exit 0
                    [ -z "$p" ] || [ "$p" == "0" ] && break
                    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt ${#files[@]} ]; then
                        echo -e "${RED}Gagal: nomor di luar daftar!${NC}"
                        continue
                    fi
                    local pilih="${files[$((p-1))]}"
                    local nm=$(basename "$pilih" .txt)
                    echo -e ""
                    echo -e "${CYAN}Slot: ${YELLOW}$nm${NC}"
                    echo -e "${YELLOW}--- ISI (8 baris awal) ---${NC}"
                    cat "$pilih" | head -8
                    echo ""
                    echo "1. Muat (timpa banner aktif)"
                    echo "2. Hapus slot ini"
                    echo "0. Kembali ke daftar"
                    read -p "Aksi (0-2): " a || exit 0
                    case $a in
                        1)
                            read -p "Yakin timpa banner aktif dengan '$nm'? (y/N): " y
                            if [[ "$y" =~ ^[Yy]$ ]]; then
                                cp "$pilih" /etc/issue.net
                                echo -e "${GREEN}Banner dimuat dari '$nm'.${NC}"
                                pause
                            else
                                echo -e "${YELLOW}Dibatalkan.${NC}"
                                sleep 1
                            fi
                            ;;
                        2)
                            read -p "Yakin hapus slot '$nm'? (y/N): " y
                            if [[ "$y" =~ ^[Yy]$ ]]; then
                                rm -f "$pilih"
                                echo -e "${GREEN}Slot '$nm' dihapus.${NC}"
                                sleep 1
                            else
                                echo -e "${YELLOW}Dibatalkan.${NC}"
                                sleep 1
                            fi
                            ;;
                        0) ;;
                        *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
                    esac
                done
                ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
    done
}

menu_conf() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   KONFIGURASI SISTEM${NC}"
        garis
        echo "1. Atur Batas Login per Akun (Max Login)"
        echo "2. Ubah Port WebSocket"
        echo "3. Ubah Domain/Host di Kartu Akun"
        echo "4. Ubah Banner Pelanggan"
        echo "5. Ubah Maks Koneksi Serentak (MAX_TOTAL)"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-5): " p || exit 0
        case $p in
            1) conf_maxlogin ;;
            2) conf_port ;;
            3) conf_domain ;;
            4) conf_banner ;;
            5) conf_maxtotal ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && pause
    done
}

# ══════════ MENU UTAMA ══════════

while true; do
    clear
    garis
    echo -e "${YELLOW}   MENU MANAJEMEN SSH VPN (v4.0)      ${NC}"
    garis
    echo "1. Manajemen Akun           (buat/hapus/perpanjang/suspend)"
    echo "2. Monitoring & Log         (online/autokill/sistem)"
    echo "3. Backup & Restore"
    echo "4. Konfigurasi Sistem       (batas login/port)"
    echo -e "${RED}0. Keluar${NC}"
    garis
    read -p "Pilih menu (0-4): " menu || exit 0
    case $menu in
        1) menu_akun ;;
        2) menu_monitor ;;
        3) menu_backup ;;
        4) menu_conf ;;
        0) echo "Keluar dari menu."; break ;;
        *) echo -e "${RED}Pilihan tidak valid!${NC}"; pause ;;
    esac
done
