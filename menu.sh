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
            if [ "$(cat /root/natssh/hide_ip.conf 2>/dev/null)" != "1" ]; then
                echo "IP        : $ipaddr"
            fi
            echo "Port WS   : $cfport (via Cloudflare)"
            udpgw_ports=$(systemctl list-units 'natssh-udpgw@*.service' --state=active --no-legend 2>/dev/null | awk '{print $1}' | sed 's/natssh-udpgw@//;s/.service//' | paste -sd, -)
            echo "Port UDPGW: ${udpgw_ports:-7300}"
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
    local online=$(ps -eo user:40=,comm= | awk '$2=="sshd" && $1=="'"$user"'" {print}' | wc -l)
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

do_ganti_password() {
    local user="$1"
    read -s -p "Password baru (kosong = batal): " p1; echo ""
    [ -z "$p1" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    read -s -p "Ulangi password (kosong = batal): " p2; echo ""
    [ -z "$p2" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if [ "$p1" != "$p2" ]; then
        echo -e "${RED}Password tidak cocok.${NC}"
        return
    fi
    if [ ${#p1} -lt 6 ]; then
        echo -e "${RED}Password minimal 6 karakter.${NC}"
        return
    fi
    echo "$user:$p1" | chpasswd
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SUKSES! Password $user berhasil diubah.${NC}"
    else
        echo -e "${RED}Gagal mengubah password.${NC}"
    fi
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
        echo "6. Ganti Password"
        echo -e "${RED}0. Kembali ke daftar${NC}"
        read -p "Aksi (0-6): " a || exit 0
        case $a in
            1) do_suspend "$user"; pause; continue ;;
            2) do_unsuspend "$user"; pause; continue ;;
            3) do_perpanjang "$user"; pause; continue ;;
            4) do_hapus "$user"; pause; continue ;;
            5) do_limit "$user"; pause; continue ;;
            6) do_ganti_password "$user"; pause; continue ;;
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
    # audit sesi aktif dulu sebelum kill
    eps=""
    for pid in $(pgrep -u "$1" sshd); do
        st=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//')
        [ -z "$st" ] && continue
        e=$(date -d "$st" +%s 2>/dev/null)
        [ -n "$e" ] && eps="$eps $e"
    done
    printf '%s\n' $eps | python3 "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/audit_kill.py" "$1" 2>/dev/null
    usermod -L "$1"
    pkill -u "$1" sshd 2>/dev/null
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

akun_ganti_password() {
    read -p "Username (0 = batal): " user
    [ "$user" == "0" ] && return
    if ! id "$user" &>/dev/null; then
        echo -e "${RED}User tidak ditemukan.${NC}"
        return
    fi
    read -s -p "Password baru (0 = batal): " pass; echo ""
    [ "$pass" == "0" ] && return
    if [ ${#pass} -lt 6 ]; then
        echo -e "${RED}Password minimal 6 karakter.${NC}"
        return
    fi
    echo "$user:$pass" | chpasswd
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SUKSES! Password $user berhasil diubah.${NC}"
    else
        echo -e "${RED}Gagal mengubah password.${NC}"
    fi
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
        echo "4. Ganti Password Akun"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-4): " p || exit 0
        case $p in
            1) akun_baru ;;
            2) akun_daftar ;;
            3) akun_autoclean ;;
            4) akun_ganti_password ;;
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
    ps -eo user:40=,comm= | awk '$2=="sshd" && $1!="root" {print $1}' | sort | uniq -c | while read count user; do
        if id "$user" &>/dev/null; then
            shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
            if [ "$shell" == "/bin/false" ]; then
                echo -e "User: ${GREEN}$user${NC} | Online: ${RED}${count}${NC} perangkat"
            fi
        fi
    done
}

autokill_manual() {
    # batas utk eksekusi ini: Enter = pakai global (cron), 0 = batal, angka >= 1 = khusus
    local global=$(crontab -l 2>/dev/null | grep -o "MAX_LOGIN=[0-9]*" | head -1 | cut -d= -f2)
    global=${global:-5}
    read -p "Batas perangkat eksekusi ini (Enter = global ${global}, 0 = batal): " max_login
    if [ "$max_login" == "0" ]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        return
    fi
    [ -z "$max_login" ] && max_login=$global
    if ! [[ "$max_login" =~ ^[0-9]+$ ]] || [ "$max_login" -lt 1 ]; then
        echo -e "${RED}Gagal: harus angka >= 1!${NC}"
        return
    fi
    echo -e "${YELLOW}Mengeksekusi pemutusan paksa (Autokill, batas ${max_login})...${NC}"
    ps -eo user:40=,comm= | awk '$2=="sshd" && $1!="root" {print $1}' | sort | uniq -c | while read count user; do
        if id "$user" &>/dev/null; then
            shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
            devices=$count   # 1 sesi tunnel = 1 proses user-owned (pasangan [priv] milik root)
            if [ "$shell" == "/bin/false" ] && [ "$devices" -gt "$max_login" ]; then
                echo -e "Menendang user ${RED}$user${NC} ($devices perangkat)..."
                pkill -u "$user" sshd
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang manual: $user ($devices perangkat, batas $max_login)" >> /root/autokill.log
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
    # ── RESOURCE SSH ──
    local nsess=$(ps -eo user:40=,args= | awk '$1!="root" && /sshd/ && !/priv/ {c++} END{print c+0}')
    local rss_ssh=$(ps -eo rss,user,comm | awk '$3=="sshd" && $2!="root" {s+=$1} END{printf "%d", s/1024}')
    local rss_ws=$(ps -eo rss,args | awk '/[w]s.py/ {s+=$1} END{printf "%d", s/1024}')
    local nuser=$(ps -eo user:40=,comm= | awk '$2=="sshd" && $1!="root" {print $1}' | sort -u | wc -l)
    echo -e "${CYAN}── RESOURCE SSH ──${NC}"
    echo -e "Sesi aktif      : ${GREEN}${nsess:-0}${NC} (dari ${nuser:-0} akun)"
    echo -e "RAM sshd pelanggan : ${GREEN}${rss_ssh:-0}${NC} MB"
    echo -e "RAM bridge ws.py   : ${GREEN}${rss_ws:-0}${NC} MB"
    if [ "${nsess:-0}" -gt 0 ]; then
        local avg=$(awk -v a="${rss_ssh:-0}" -v b="${nsess:-1}" 'BEGIN{printf "%.1f", a/b}')
        echo -e "Rata-rata/sesi  : ${GREEN}${avg}${NC} MB"
    fi
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
    echo -e "Ditolak (TOLAK) : ${RED}${tolak}${NC}x"
    if [ "$peak" -ge $(( cur_max * 80 / 100 )) ]; then
        echo -e "${RED}Puncak >= 80% batas — pertimbangkan naikkan lewat Konfigurasi: Ubah Maks Koneksi Serentak (MAX_TOTAL).${NC}"
    fi
}

ws_peruser() {
    # Sanding waktu: sesi "sshd: user" (lstart) <-> koneksi bridge (conns.json:
    # IP asli, aplikasi, durasi, byte up/down; fallback ws.log pra-patch).
    # Username SSH tak terbaca jembatan (terenkripsi post-KEX) -> -2..+10 dtk, kemungkinan.
    local dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
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
    done < <(ps -eo user:40=,comm= | awk '$2=="sshd" && $1!="root" {print $1}' | sort -u)
    if [ -z "$rows" ]; then
        echo -e "${YELLOW}Tidak ada akun jualan yang sedang online.${NC}"
        return
    fi
    echo -e "${YELLOW}--- PERANGKAT PER AKUN (korelasi waktu) ---${NC}"
    printf '%b' "$rows" | python3 "$dir/ws_match.py" "$dir/conns.json" "$dir/ws.log" "$dir/audit_sess.log" "$dir/suspended_history.log"
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
        echo "4. Puncak Koneksi WebSocket (slot)"
        echo "5. Perangkat per Akun (live + riwayat sesi)"
        echo "6. Status RAM / CPU / Disk + Resource SSH"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-6): " p || exit 0
        case $p in
            1) sessi_online ;;
            2) autokill_manual ;;
            3) autokill_riwayat ;;
            4) ws_peak ;;
            5) ws_peruser ;;
            6) status_sistem ;;
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

backup_config() {
    local ts=$(date +%Y%m%d_%H%M%S)
    local out="/root/natssh_config.tar.gz"
    local list=""
    cd /root/natssh
    [ -f ip.conf ] && list="$list ip.conf"
    [ -f host.conf ] && list="$list host.conf"
    [ -f port.conf ] && list="$list port.conf"
    [ -f hide_ip.conf ] && list="$list hide_ip.conf"
    [ -f suspend_minutes.conf ] && list="$list suspend_minutes.conf"
    [ -d limits ] && list="$list limits"
    [ -d banners ] && list="$list banners"
    [ -f /etc/issue.net ] && cp /etc/issue.net /root/natssh/issue.net.bak && list="$list issue.net.bak"
    [ -f /etc/systemd/system/natssh-ws.service ] && cp /etc/systemd/system/natssh-ws.service /root/natssh/natssh-ws.service.bak && list="$list natssh-ws.service.bak"
    tar -czf "$out" $list >/dev/null 2>&1
    echo -e "${GREEN}SUKSES! Konfigurasi dibackup: ${CYAN}$out${NC}"
    pause
}

conf_autobackup() {
    echo -e "${YELLOW}---- AUTO BACKUP KONFIGURASI ----${NC}"
    if crontab -l 2>/dev/null | grep -q "autobackup.sh"; then
        echo -e "Status: ${GREEN}AKTIF${NC}"
        crontab -l | grep autobackup.sh
    else
        echo -e "Status: ${YELLOW}NONAKTIF${NC}"
    fi
    echo "1. Aktifkan (harian 02:00)"
    echo "2. Aktifkan (tiap 6 jam)"
    echo "3. Nonaktifkan"
    echo "0. Kembali"
    read -p "Pilih: " a
    case $a in
        1)
            crontab -l 2>/dev/null | grep -v "autobackup.sh" | crontab -
            (crontab -l 2>/dev/null; echo "0 2 * * * /root/natssh/autobackup.sh") | crontab -
            echo -e "${GREEN}Auto-backup harian 02:00 diaktifkan.${NC}" ;;
        2)
            crontab -l 2>/dev/null | grep -v "autobackup.sh" | crontab -
            (crontab -l 2>/dev/null; echo "0 */6 * * * /root/natssh/autobackup.sh") | crontab -
            echo -e "${GREEN}Auto-backup tiap 6 jam diaktifkan.${NC}" ;;
        3)
            crontab -l 2>/dev/null | grep -v "autobackup.sh" | crontab -
            echo -e "${YELLOW}Auto-backup dinonaktifkan.${NC}" ;;
        0) return ;;
        *) echo -e "${RED}Tidak valid${NC}" ;;
    esac
    pause
}

menu_backup() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   BACKUP & RESTORE${NC}"
        garis
        echo "1. Backup Data Akun (Ekspor Portabel)"
        [ -f /root/backup_akun_ssh.sh ] && echo -e "   (backup terakhir: $(stat -c '%y' /root/backup_akun_ssh.sh | cut -d. -f1))"
        echo "2. Backup Konfigurasi (tar.gz)"
        echo "3. Atur Auto-Backup Konfigurasi"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-3): " p || exit 0
        case $p in
            1) backup_ekspor ;;
            2) backup_config ;;
            3) conf_autobackup ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && [ "$p" != "2" ] && [ "$p" != "3" ] && pause

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
    echo -e "${YELLOW}Ketik 0 atau kosong untuk batal.${NC}"
    read -p "Port WebSocket baru: " new_port
    if [ -z "$new_port" ] || [ "$new_port" = "0" ]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        return
    fi
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

conf_service() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   KONTROL LAYANAN NATSSH-WS${NC}"
        garis
        status=$(systemctl is-active natssh-ws 2>/dev/null)
        echo -e "Status saat ini: ${GREEN}${status}${NC}"
        echo ""
        echo "1. Start"
        echo "2. Stop"
        echo "3. Restart"
        echo -e "${RED}0. Kembali${NC}"
        read -p "Pilih (0-3): " p || exit 0
        case $p in
            1)
                echo -e "${YELLOW}Menjalankan natssh-ws...${NC}"
                systemctl start natssh-ws
                sleep 2
                systemctl is-active --quiet natssh-ws && echo -e "${GREEN}SUKSES! natssh-ws berjalan.${NC}" || echo -e "${RED}Gagal start!${NC}"
                pause
                ;;
            2)
                echo -e "${YELLOW}Menghentikan natssh-ws...${NC}"
                echo -e "${RED}PERINGATAN: Semua koneksi aktif akan terputus!${NC}"
                read -p "Yakin stop? (y/N): " y
                if [[ "$y" =~ ^[Yy]$ ]]; then
                    systemctl stop natssh-ws
                    sleep 2
                    systemctl is-active --quiet natssh-ws && echo -e "${RED}Masih berjalan!${NC}" || echo -e "${GREEN}Berhasil dihentikan.${NC}"
                else
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                fi
                pause
                ;;
            3)
                echo -e "${YELLOW}Me-restart natssh-ws...${NC}"
                echo -e "${RED}PERINGATAN: Semua koneksi aktif akan terputus!${NC}"
                read -p "Yakin restart? (y/N): " y
                if [[ "$y" =~ ^[Yy]$ ]]; then
                    systemctl restart natssh-ws
                    sleep 3
                    systemctl is-active --quiet natssh-ws && echo -e "${GREEN}SUKSES! natssh-ws berjalan kembali.${NC}" || echo -e "${RED}Gagal restart!${NC}"
                else
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                fi
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

conf_speed() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}--- ATUR LIMIT SPEED per CDN ---${NC}"
        garis
        if tc class show dev eth0 2>/dev/null | grep -q "class htb.*1:10"; then
            _limits=$(grep -E "^(UP|DOWN)_" /root/natssh/speed.conf 2>/dev/null | grep -v "25mbit")
            if [ -n "$_limits" ]; then
                echo -e "${GREEN}Limit AKTIF:${NC}"
                echo "$_limits"
            fi
        fi
        echo ""
        echo "1. Set limit Cloudflare (upload + download)"
        echo "2. Set limit CloudFront (upload + download)"
        echo "3. Set semua (CF + CFront) sekaligus"
        echo "4. Hapus limit speed"
        echo "5. Status detail (tc)"
        echo "0. Kembali"
        read -p "Pilih (0-5): " c || return
        case $c in
            1)
                read -p "Upload Cloudflare (default 25, 0=batal): " up
                [ "$up" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$up" ] && up="25"
                read -p "Download Cloudflare (default 25, 0=batal): " down
                [ "$down" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$down" ] && down="25"
                for v in up down; do
                    val=${!v}; if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$val" =~ ^\.[0-9]+$ ]]; then eval "$v=${val}mbit"; fi
                done
                # update only CF fields in speed.conf
                iface=$(ip route | grep default | awk '{print $5}' | head -1); iface=${iface:-eth0}
                if [ ! -f /root/natssh/speed.conf ]; then
                    echo "IFACE=$iface" > /root/natssh/speed.conf
                    echo "UP_CF=25mbit" >> /root/natssh/speed.conf
                    echo "DOWN_CF=25mbit" >> /root/natssh/speed.conf
                    echo "UP_CFRONT=25mbit" >> /root/natssh/speed.conf
                    echo "DOWN_CFRONT=25mbit" >> /root/natssh/speed.conf
                    echo "MODE=cdn-split" >> /root/natssh/speed.conf
                fi
                sed -i "s/^IFACE=.*/IFACE=$iface/" /root/natssh/speed.conf
                sed -i "s/^UP_CF=.*/UP_CF=$up/" /root/natssh/speed.conf
                sed -i "s/^DOWN_CF=.*/DOWN_CF=$down/" /root/natssh/speed.conf
                bash /root/natssh/apply_speed.sh 2>/dev/null
                systemctl enable --now natssh-speed.service 2>/dev/null
                echo -e "${GREEN}Limit Cloudflare diterapkan.${NC}"; pause ;;
            2)
                read -p "Upload CloudFront (default 25, 0=batal): " up
                [ "$up" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$up" ] && up="25"
                read -p "Download CloudFront (default 25, 0=batal): " down
                [ "$down" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$down" ] && down="25"
                for v in up down; do
                    val=${!v}; if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$val" =~ ^\.[0-9]+$ ]]; then eval "$v=${val}mbit"; fi
                done
                iface=$(ip route | grep default | awk '{print $5}' | head -1); iface=${iface:-eth0}
                if [ ! -f /root/natssh/speed.conf ]; then
                    echo "IFACE=$iface" > /root/natssh/speed.conf
                    echo "UP_CF=25mbit" >> /root/natssh/speed.conf
                    echo "DOWN_CF=25mbit" >> /root/natssh/speed.conf
                    echo "UP_CFRONT=25mbit" >> /root/natssh/speed.conf
                    echo "DOWN_CFRONT=25mbit" >> /root/natssh/speed.conf
                    echo "MODE=cdn-split" >> /root/natssh/speed.conf
                fi
                sed -i "s/^IFACE=.*/IFACE=$iface/" /root/natssh/speed.conf
                sed -i "s/^UP_CFRONT=.*/UP_CFRONT=$up/" /root/natssh/speed.conf
                sed -i "s/^DOWN_CFRONT=.*/DOWN_CFRONT=$down/" /root/natssh/speed.conf
                bash /root/natssh/apply_speed.sh 2>/dev/null
                systemctl enable --now natssh-speed.service 2>/dev/null
                echo -e "${GREEN}Limit CloudFront diterapkan.${NC}"; pause ;;
            3)
                read -p "Upload Cloudflare (default 25, 0=batal): " up_cf
                [ "$up_cf" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$up_cf" ] && up_cf="25"
                read -p "Download Cloudflare (default 25, 0=batal): " down_cf
                [ "$down_cf" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$down_cf" ] && down_cf="25"
                read -p "Upload CloudFront (default 25, 0=batal): " up_cfront
                [ "$up_cfront" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$up_cfront" ] && up_cfront="25"
                read -p "Download CloudFront (default 25, 0=batal): " down_cfront
                [ "$down_cfront" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                [ -z "$down_cfront" ] && down_cfront="25"
                for v in up_cf down_cf up_cfront down_cfront; do
                    val=${!v}; if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$val" =~ ^\.[0-9]+$ ]]; then eval "$v=${val}mbit"; fi
                done
                iface=$(ip route | grep default | awk '{print $5}' | head -1); iface=${iface:-eth0}
                echo "IFACE=$iface" > /root/natssh/speed.conf
                echo "UP_CF=$up_cf" >> /root/natssh/speed.conf
                echo "DOWN_CF=$down_cf" >> /root/natssh/speed.conf
                echo "UP_CFRONT=$up_cfront" >> /root/natssh/speed.conf
                echo "DOWN_CFRONT=$down_cfront" >> /root/natssh/speed.conf
                echo "MODE=cdn-split" >> /root/natssh/speed.conf
                bash /root/natssh/apply_speed.sh 2>/dev/null
                systemctl enable --now natssh-speed.service 2>/dev/null
                echo -e "${GREEN}Limit semua CDN diterapkan.${NC}"; pause ;;
            4)
                tc qdisc del dev eth0 root 2>/dev/null
                tc qdisc del dev eth0 ingress 2>/dev/null
                ip link set dev ifb0 down 2>/dev/null
                ip link del ifb0 2>/dev/null
                rm -f /root/natssh/speed.conf
                systemctl disable --now natssh-speed.service 2>/dev/null
                echo -e "${GREEN}Limit speed dihapus.${NC}"; pause ;;
            5)
                iface=$(grep "^IFACE=" /root/natssh/speed.conf 2>/dev/null | cut -d= -f2); iface=${iface:-eth0}
                echo "--- tc classes $iface ---"; tc class show dev $iface
                echo "--- tc filters $iface ---"; tc filter show dev $iface parent 1:
                echo "--- ingress ---"; tc filter show dev $iface parent ffff:
                pause ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

conf_restart_schedule() {
    echo -e "${YELLOW}--- JADWAL RESTART OTOMATIS NATSSH-WS ---${NC}"
    echo ""
    if crontab -l 2>/dev/null | grep -q "systemctl.*restart.*natssh-ws"; then
        echo -e "${GREEN}Jadwal saat ini:${NC}"
        crontab -l | grep "systemctl.*restart.*natssh-ws"
        echo ""
        read -p "Hapus jadwal restart? (y/N): " h
        if [[ "$h" =~ ^[Yy]$ ]]; then
            crontab -l | grep -v "systemctl.*restart.*natssh-ws" | crontab -
            echo -e "${GREEN}Jadwal restart dihapus.${NC}"
        fi
    else
        echo -e "${YELLOW}Belum ada jadwal restart otomatis.${NC}"
        echo ""
        echo "Pilih jadwal:"
        echo "1. Setiap jam"
        echo "2. Setiap 6 jam"
        echo "3. Setiap 12 jam"
        echo "4. Setiap hari jam 03:00"
        echo "5. Custom"
        echo -e "${RED}0. Batal${NC}"
        read -p "Pilih (0-5): " p
        case $p in
            1) (crontab -l 2>/dev/null; echo "0 * * * * /usr/bin/systemctl restart natssh-ws; /usr/bin/systemctl restart 'natssh-udpgw@*' >/dev/null 2>&1") | crontab - && echo -e "${GREEN}Jadwal set: setiap jam.${NC}";;
            2) (crontab -l 2>/dev/null; echo "0 */6 * * * /usr/bin/systemctl restart natssh-ws; /usr/bin/systemctl restart 'natssh-udpgw@*' >/dev/null 2>&1") | crontab - && echo -e "${GREEN}Jadwal set: setiap 6 jam.${NC}";;
            3) (crontab -l 2>/dev/null; echo "0 */12 * * * /usr/bin/systemctl restart natssh-ws; /usr/bin/systemctl restart 'natssh-udpgw@*' >/dev/null 2>&1") | crontab - && echo -e "${GREEN}Jadwal set: setiap 12 jam.${NC}";;
            4) (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/systemctl restart natssh-ws; /usr/bin/systemctl restart 'natssh-udpgw@*' >/dev/null 2>&1") | crontab - && echo -e "${GREEN}Jadwal set: setiap hari jam 03:00.${NC}";;
            5)
                read -p "Masukkan cron (contoh: 0 3 * * *): " cron
                read -p "Lanjut? (y/N): " y
                if [[ "$y" =~ ^[Yy]$ ]] && [ -n "$cron" ]; then
                    (crontab -l 2>/dev/null; echo "$cron /usr/bin/systemctl restart natssh-ws; /usr/bin/systemctl restart 'natssh-udpgw@*' >/dev/null 2>&1") | crontab -
                    echo -e "${GREEN}Jadwal custom tersimpan.${NC}"
                else
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                fi
                ;;
            0) echo -e "${YELLOW}Dibatalkan.${NC}";;
            *) echo -e "${RED}Pilihan tidak valid!${NC}";;
        esac
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
<p align="center">
<font color="cyan">╔═════════════════════════╗</font><br>
<font color="yellow"><b>⚡ PREMIUM VPN SERVICE ⚡</b></font><br>
<font color="cyan">╠═════════════════════════╣</font><br>
<font color="green">✅ KONEKSI BERHASIL</font><br>
<font color="orange">🌍 Server : Indonesia — Premium</font><br>
<font color="aqua">🚀 Speed : up 100 Mbps</font><br>
<font color="lime">📱 Maksimal 4 Perangkat/Akun</font><br>
<font color="orange">⚔ Auto-Kill AKTIF</font><br>
<font color="white">────────────────────</font><br>
<font color="red">⛔ Dilarang: Torrent · DDoS · Data Waster · Hack</font><br>
<font color="grey">🛡 Support : </font><font color="magenta"><a href="https://wa.me/6281223711096?text=Halo%2C%20saya%20ingin%20membeli%20layanan%20SSH%2FVPN.%20Bisa%20info%20paket%20dan%20harganya%3F" target="_blank" rel="noopener">+6281223711096</a></font><br>
<font color="cyan">╚═════════════════════════╝</font><br>
<font color="green"><b>═══ SELAMAT MENIKMATI ═══</b></font><br>
</p>
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
                        0) break ;;
                        *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
                    esac
                done
                ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
    done
}

conf_hide_ip() {
    local cur=$(cat /root/natssh/hide_ip.conf 2>/dev/null)
    cur=${cur:-0}
    echo -e "${YELLOW}---- HIDE IP SAAT BUAT AKUN ----${NC}"
    if [ "$cur" = "1" ]; then
        echo -e "Status: ${GREEN}ON (IP disembunyikan)${NC}"
    else
        echo -e "Status: ${YELLOW}OFF (IP ditampilkan)${NC}"
    fi
    read -p "Toggle? (1=ON, 0=OFF, kosong=batal): " v
    [ -z "$v" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if [ "$v" = "1" ]; then
        echo "1" > /root/natssh/hide_ip.conf
        echo -e "${GREEN}Hide IP diaktifkan.${NC}"
    elif [ "$v" = "0" ]; then
        echo "0" > /root/natssh/hide_ip.conf
        echo -e "${GREEN}Hide IP dinonaktifkan.${NC}"
    else
        echo -e "${RED}Pilihan tidak valid!${NC}"
    fi
}

conf_suspend_minutes() {
    local cur=$(cat /root/natssh/suspend_minutes.conf 2>/dev/null)
    cur=${cur:-15}
    echo -e "${YELLOW}---- DURASI SUSPEND (autokill) ----${NC}"
    echo -e "Durasi saat ini: ${GREEN}${cur} menit${NC}"
    read -p "Durasi baru (1-1440 menit, kosong=batal): " v
    [ -z "$v" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 1440 ]; then
        echo -e "${RED}Nilai tidak valid!${NC}"; pause; return
    fi
    echo "$v" > /root/natssh/suspend_minutes.conf
    echo -e "${GREEN}Durasi suspend diubah menjadi ${v} menit.${NC}"
    pause
}

conf_udpgw() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   BADVPN-UDPGW (UDP GATEWAY)${NC}"
        garis
        active=""
        for pp in 7100 7200 7300 7400 7500; do
            st=$(systemctl is-active natssh-udpgw@${pp} 2>/dev/null)
            [ "$st" = "active" ] && active="$active $pp"
        done
        echo -e "Status : ${GREEN}active${NC}  Port aktif:${YELLOW}${active:- (none)}${NC}"
        echo -e "Tunnel contoh: ssh -N -L 7300:127.0.0.1:7300 user@host"
        garis
        echo "1. Ubah Port (pilih port untuk aktif/nonaktif)"
        echo -e "${RED}0. Kembali${NC}"
        read -p "Pilih (0-1): " p || return
        case $p in
            1)
                ports_list="7100 7200 7300 7400 7500"
                clear
                garis
                echo -e "${YELLOW}   KELOLA PORT UDGPW${NC}"
                garis
                i=1
                for pp in $ports_list; do
                    st=$(systemctl is-active natssh-udpgw@${pp} 2>/dev/null)
                    echo "$i) $pp  [$st]"
                    i=$((i+1))
                done
                echo "0) Batal"
                echo -e "${YELLOW}Catatan: pilih port aktif -> nonaktifkan; nonaktif -> aktifkan.${NC}"
                garis
                read -p "Pilih nomor port (0 batal): " n
                [ "$n" = "0" ] && return
                case $n in
                    1) pp=7100 ;; 2) pp=7200 ;; 3) pp=7300 ;; 4) pp=7400 ;; 5) pp=7500 ;; *) echo -e "${RED}Tidak valid${NC}"; pause; return ;;
                esac
                if systemctl is-active --quiet natssh-udpgw@${pp}; then
                    systemctl disable --now natssh-udpgw@${pp} >/dev/null 2>&1 && echo -e "${GREEN}${pp} nonaktif${NC}" || echo -e "${RED}Gagal${NC}"
                else
                    systemctl enable --now natssh-udpgw@${pp} >/dev/null 2>&1 && echo -e "${GREEN}${pp} aktif${NC}" || echo -e "${RED}Gagal${NC}"
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && pause
    done
}

menu_conf() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   KONFIGURASI SISTEM${NC}"
        garis
        echo -e "${CYAN}  -- Port --${NC}"
        printf "  %-3s %-46s\n" "1." "Ubah Port WebSocket"
        printf "  %-3s %-46s\n" "2." "Ubah Domain/Host di Kartu Akun"
        printf "  %-3s %-46s\n" "3." "Hide IP"
        echo -e "${CYAN}  -- Batas --${NC}"
        printf "  %-3s %-46s\n" "4." "Atur Batas Login per Akun (Max Login)"
        printf "  %-3s %-46s\n" "5." "Ubah Maks Koneksi Serentak (MAX_TOTAL)"
        printf "  %-3s %-46s\n" "6." "Atur Limit Speed per CDN (CF/CFront)"
        echo -e "${CYAN}  -- Layanan --${NC}"
        printf "  %-3s %-46s\n" "7." "Kontrol Layanan natssh-ws (Start/Stop/Restart)"
        printf "  %-3s %-46s\n" "8." "badvpn-udpgw (UDP Gateway)"
        printf "  %-3s %-46s\n" "9." "Atur Jadwal Restart Otomatis"
        echo -e "${CYAN}  -- Lainnya --${NC}"
        printf "  %-3s %-46s\n" "10." "Ubah Banner Pelanggan"
        printf "  %-3s %-46s\n" "11." "Ubah Durasi Suspend (menit)"
        echo -e "${RED}  0.  Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-11): " p || exit 0
        case $p in
            1) conf_port ;;
            2) conf_domain ;;
            3) conf_hide_ip ;;
            4) conf_maxlogin ;;
            5) conf_maxtotal ;;
            6) conf_speed ;;
            7) conf_service ;;
            8) conf_udpgw ;;
            9) conf_restart_schedule ;;
            10) conf_banner ;;
            11) conf_suspend_minutes ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && [ "$p" != "4" ] && [ "$p" != "10" ] && [ "$p" != "11" ] && pause
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
