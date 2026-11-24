#!/bin/bash
# NATSSH Menu v4.0 — utama 4 kategori + submenu
# Konvensi: akun jualan = shell /bin/false; 1 sesi tunnel = 2 proses sshd (hitungan /2)

# ══════════ KONFIGURASI WAKTU ══════════
# Semua tampilan waktu ke user pakai WIB (GMT+7)
export TZ=Asia/Jakarta

RED='\u001b[0;31m'
GREEN='\u001b[0;32m'
YELLOW='\u001b[0;33m'
CYAN='\u001b[0;36m'
NC='\u001b[0m'

# Direktori natssh (portabel jika dipindah)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Muat konfigurasi terpusat dari config/.env (jika ada)
if [ -f "${DIR}/config/.env" ]; then
    set -a
    . "${DIR}/config/.env"
    set +a
fi

port_ws() {
    # Port WebSocket — baca dari config/.env (NATSSH_WS_PORT)
    if [ -f "${DIR}/config/.env" ]; then
        grep "^NATSSH_WS_PORT=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2
    fi
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
            # .env: DOMAIN = domain Cloudflare (recommended) / IP utk koneksi langsung
            # NATSSH_WS_PORT = port Cloudflare yg dipakai klien (default 2086); asal via Origin Rule ke port NAT
            ipaddr=$(cat "${DIR}/config/ip.conf" 2>/dev/null || curl -s -m 3 ifconfig.me 2>/dev/null)
            ipaddr=${ipaddr:-$(hostname -I | awk '{print $1}')}
            host=${DOMAIN}
            wsport=$(port_ws)
            cfport=$(cat "${DIR}/config/port.conf" 2>/dev/null)
            cfport=${cfport:-2086}
            maxlog=$(grep "^MAX_LOGIN=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2)
            maxlog=${maxlog:-5}
            echo -e "${GREEN}SUKSES! Akun $user berhasil dibuat.${NC}"
            echo ""
            # Render kartu akun dari template jika ada
            card_template="${DIR}/config/card_account.txt"
            if [ -f "$card_template" ] && [ -s "$card_template" ]; then
                nginx_reverse=$(grep -E 'listen [0-9]+ ssl' /etc/nginx/sites-available/natssh-ws 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
                nginx_reverse=${nginx_reverse:-20865}
                nginx_stream=$(grep -E 'listen [0-9]+' /etc/nginx/stream.conf 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
                nginx_stream=${nginx_stream:-20869}
                cf_ports="80, 443, 8080, 2052, 2053, 2082, 2083, 2086, 2087, 2095, 2096, 8443"
                cf_front_ports="80, 443, 2052, 2053, 2082, 2083, 2086, 2087, 2095, 2096, 8443"
                sisa_hari=$(( $(date -d "$exp" +%s) - $(date +%s) ))
                sisa_hari=$(( sisa_hari / 86400 ))
                [ $sisa_hari -lt 0 ] && sisa_hari=0
                hostcf=${DOMAIN_CF}
                udpgw_ports=$(ss -tln 2>/dev/null | awk '{print $4}' | grep -oE ':7[1-5][0-9][0-9]$' | tr -d ':' | sort -n | paste -sd, | sed 's/,/, /g')
                [ -z "$udpgw_ports" ] && udpgw_ports="7100, 7200, 7300, 7400, 7500"
                template=$(cat "$card_template")
                template=${template//\{domain\}/$host}
                template=${template//\{domain_cf\}/$hostcf}
                template=${template//\{cf_ports\}/$cf_ports}
                template=${template//\{cf_front_ports\}/$cf_front_ports}
                template=${template//\{udpgw_ports\}/${udpgw_ports:-7300}}
                template=${template//\{nginx_reverse\}/$nginx_reverse}
                template=${template//\{nginx_stream\}/$nginx_stream}
                template=${template//\{username\}/$user}
                template=${template//\{password\}/$pass}
                template=${template//\{expired\}/$exp}
                template=${template//\{hari\}/$aktif}
                template=${template//\{limit\}/${maxlog:-5}}
                # Hide IP jika HIDE_IP = 1 (dari .env)
                if [ "${HIDE_IP}" = "1" ]; then
                    template=${template//\{ip\}/}
                    template=$(echo "$template" | sed '/^IP[[:space:]]*:[[:space:]]*$/d')
                else
                    template=${template//\{ip\}/$ipaddr}
                fi
                # Hapus baris yang nilainya kosong (contoh: Domain CF : tanpa nilai)
                template=$(echo "$template" | sed -E '/^[A-Za-z ]+:[[:space:]]*$/d')
                echo -e "$template"
            else
                [ -z "$host" ] && host="$ipaddr"
                hostcf=${DOMAIN_CF}
                echo "================ DETAIL AKUN ================"
                echo "Domain    : $host"
                [ -n "$hostcf" ] && echo "Domain CF : $hostcf"
                # Hide IP jika HIDE_IP = 1 (dari .env)
                if [ "${HIDE_IP}" != "1" ]; then
                    echo "IP        : $ipaddr"
                fi
                echo "Cloudflare: 80, 443, 8080, 2052, 2053, 2082, 2083, 2086, 2087, 2095, 2096, 8443"
                echo "CloudFront: 80, 443, 2052, 2053, 2082, 2083, 2086, 2087, 2095, 2096, 8443"
                nginx_reverse=$(grep -E 'listen [0-9]+ ssl' /etc/nginx/sites-available/natssh-ws 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
                nginx_reverse=${nginx_reverse:-20865}
                nginx_stream=$(grep -E 'listen [0-9]+' /etc/nginx/stream.conf 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
                nginx_stream=${nginx_stream:-20869}
                udpgw_ports=$(ss -tln 2>/dev/null | awk '{print $4}' | grep -oE ':7[1-5][0-9][0-9]$' | tr -d ':' | sort -n | paste -sd, | sed 's/,/, /g')
                [ -z "$udpgw_ports" ] && udpgw_ports="7100, 7200, 7300, 7400, 7500"
                echo "Port UDPGW: ${udpgw_ports}"
                echo "Port Direct : ${nginx_reverse} (reverse), ${nginx_stream} (stream)"
                echo "Username  : $user"
                echo "Password  : $pass"
                echo "Expired   : $exp ($aktif hari)"
                echo "Limit     : ${maxlog:-5} perangkat"
                echo "============================================"
            fi
        fi
    fi
}

do_hapus() {
    local user="$1"
    local exp=$(chage -l "$user" | grep "Account expires" | awk -F": " '{print $2}')
    online=$(ps -eo user:40=,comm= | awk '$2=="sshd" && $1=="'"$user"'" {print}' | wc -l)
    if [ "$online" -gt 0 ]; then
        echo -e "${YELLOW}Akan dihapus: ${CYAN}$user${NC} (Expired: $exp, online: ${online} perangkat)"
        read -p "Yakin hapus akun + putus $online sesi aktif? (y/N): " yakin
    else
        echo -e "${YELLOW}Akan dihapus: ${CYAN}$user${NC} (Expired: $exp, online: 0 perangkat)"
        read -p "Yakin hapus? (y/N): " yakin
    fi
    if [[ "$yakin" =~ ^[Yy]$ ]]; then
        if [ "$online" -gt 0 ]; then
            loginctl terminate-user "$user" 2>/dev/null
            pkill -KILL -u "$user" 2>/dev/null
            for i in {1..10}; do
                pgrep -u "$user" >/dev/null 2>&1 || break
                sleep 0.5
            done
            if pgrep -u "$user" >/dev/null 2>&1; then
                echo -e "${RED}Gagal: masih ada proses aktif:${NC}"
                ps -eo pid,user,comm | awk '$2=="'"$user"'" {print}'
                return
            fi
        fi
        rc=1
        for attempt in 1 2 3; do
            res=$(userdel -r "$user" 2>&1); rc=$?
            if [ $rc -eq 0 ]; then break; fi
            # jika masih ada proses, kill lagi lalu tunggu
            if pgrep -u "$user" >/dev/null 2>&1; then
                loginctl terminate-user "$user" 2>/dev/null
                pkill -9 -u "$user" 2>/dev/null
                for i in {1..10}; do
                    pgrep -u "$user" >/dev/null 2>&1 || break
                    sleep 0.5
                done
            fi
            sleep 1
        done
        warn=$(echo "$res" | grep -v "mail spool" || true)
        [ -n "$warn" ] && echo -e "${YELLOW}Peringatan: $warn${NC}"
        # verifikasi pasca-hapus
        if getent passwd "$user" >/dev/null 2>&1; then
            rc=1
            echo -e "${RED}Gagal: akun masih ada setelah userdel. Proses penghalang:${NC}"
            ps -eo pid,user,comm | awk '$2=="'"$user"'" {print}'
        fi
        if [ $rc -eq 0 ]; then
            # Hapus batas per akun
            rm -f "${DIR}/limits/$user"

            # Bersihkan log akun: autokill.log
            # Hapus baris HAPUS manual: username atau HAPUS konfirmasi langsung: username
            if [ -f "${DIR}/logs/autokill.log" ]; then
                temp=$(mktemp)
                grep -v -E "HAPUS (manual|konfirmasi langsung): $user" "${DIR}/logs/autokill.log" > "$temp" 2>/dev/null || true
                mv "$temp" "${DIR}/logs/autokill.log"
            fi

            # Bersihkan log akun: audit_sess.log
            # Hapus baris yang mengandung user=username
            if [ -f "${DIR}/logs/audit_sess.log" ]; then
                temp=$(mktemp)
                grep -v -E "user=$user[[:space:]]" "${DIR}/logs/audit_sess.log" > "$temp" 2>/dev/null || true
                mv "$temp" "${DIR}/logs/audit_sess.log"
            fi

            # Bersihkan suspended_history.log entries untuk user ini
            # Hapus baris SUSPEND: username atau UNSUSPEND: username
            if [ -f "${DIR}/logs/suspended_history.log" ]; then
                temp=$(mktemp)
                grep -v -E "SUSPEND: $user|UNSUSPEND: $user" "${DIR}/logs/suspended_history.log" > "$temp" 2>/dev/null || true
                mv "$temp" "${DIR}/logs/suspended_history.log"
                # Hapus file jika kosong
                if [ ! -s "${DIR}/logs/suspended_history.log" ]; then
                    rm -f "${DIR}/logs/suspended_history.log"
                fi
            fi

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
        # Validasi format username: alfanumerik, underscore, strip, 1-32 char
        if ! [[ "$pilih" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
            echo -e "${RED}Gagal: format username tidak valid!${NC}"
            return 1
        fi
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
        read -p "Aksi (0-6): " a || continue
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
    # Baca global dari .env (sumber tunggal), fallback crontab, fallback 5
    if [ -f "${selfdir}/config/.env" ] && grep -q "^MAX_LOGIN=" "${selfdir}/config/.env"; then
        global=$(grep "^MAX_LOGIN=" "${selfdir}/config/.env" | cut -d= -f2)
    elif crontab -l 2>/dev/null | grep -q "MAX_LOGIN="; then
        global=$(crontab -l 2>/dev/null | grep -o "MAX_LOGIN=[0-9]*" | head -1 | cut -d= -f2)
    else
        global=5
    fi
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') - LIMIT: batas khusus $1 = $n perangkat (global $global)" >> /root/natssh/logs/autokill.log
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
                loginctl terminate-user "$user" 2>/dev/null
                pkill -KILL -u "$user" 2>/dev/null
                for i in {1..10}; do
                    pgrep -u "$user" >/dev/null 2>&1 || break
                    sleep 0.5
                done
                loginctl terminate-user "$user" 2>/dev/null
                pkill -9 -u "$user" 2>/dev/null
                for i in {1..10}; do
                    pgrep -u "$user" >/dev/null 2>&1 || break
                    sleep 0.5
                done
                userdel -r "$user" 2>/dev/null || true
                echo -e "Menghapus akun ${RED}$user${NC} (Kedaluwarsa: $exp_date)"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - AUTO-CLEAN hapus $user (kedaluwarsa: $exp_date)" >> "${DIR}/logs/autokill.log"
                # Bersihkan riwayat live + sesi dari audit_sess.log dan suspended_history.log
                if [ -f "${DIR}/logs/audit_sess.log" ]; then
                    temp=$(mktemp)
                    grep -v -E "user=$user[[:space:]]" "${DIR}/logs/audit_sess.log" > "$temp" 2>/dev/null || true
                    mv "$temp" "${DIR}/logs/audit_sess.log"
                fi
                if [ -f "${DIR}/logs/suspended_history.log" ]; then
                    temp=$(mktemp)
                    grep -v -E "SUSPEND: $user|UNSUSPEND: $user" "${DIR}/logs/suspended_history.log" > "$temp" 2>/dev/null || true
                    mv "$temp" "${DIR}/logs/suspended_history.log"
                    if [ ! -s "${DIR}/logs/suspended_history.log" ]; then
                        rm -f "${DIR}/logs/suspended_history.log"
                    fi
                fi
                ((count++))
            fi
        fi
    done < <(awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd)
    echo -e "${GREEN}Selesai! $count akun kedaluwarsa dihapus (tercatat di /root/natssh/logs/autokill.log).${NC}"
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
    read -s -p "Ulangi password baru (0 = batal): " pass2; echo ""
    [ "$pass2" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if [ "$pass" != "$pass2" ]; then
        echo -e "${RED}Password tidak cocok.${NC}"
        return
    fi
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

    # Kumpulkan daftar user yang akan ditendang
    local kick_list=""
    local total_devices=0
    while read -r count user; do
        [ -z "$user" ] && continue
        if id "$user" &>/dev/null; then
            local shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd 2>/dev/null)
            if [ "$shell" == "/bin/false" ] && [ "$count" -gt "$max_login" ]; then
                kick_list="$kick_list $user:$count"
                total_devices=$((total_devices + count))
            fi
        fi
    done < <(ps -eo user:40=,comm= | awk '$2=="sshd" && $1!="root" {print $1}' | sort | uniq -c)

    if [ -z "$kick_list" ]; then
        echo -e "${GREEN}Tidak ada user yang melebihi batas ${max_login} perangkat.${NC}"
        return
    fi

    echo -e "${YELLOW}User yang akan ditendang (batas ${max_login} perangkat):${NC}"
    for pair in $kick_list; do
        local u=${pair%%:*}
        local d=${pair##*:}
        echo -e "  ${RED}$u${NC}: ${d} perangkat"
    done
    echo -e "Total perangkat yang akan diputus: ${total_devices}"
    echo ""
    read -p "Yakin men-tendang semua user di atas? (y/N): " y
    if [[ ! "$y" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        return
    fi

    local dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
    for pair in $kick_list; do
        local u=${pair%%:*}

        # Audit sebelum kill: tangkap data sesi dari conns.json / ws.log
        local eps=""
        for pid in $(pgrep -u "$u" sshd 2>/dev/null); do
            local st=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//')
            local ep=$(date -d "$st" +%s 2>/dev/null)
            [ -n "$ep" ] && eps="$eps $ep"
        done
        if [ -n "$eps" ]; then
            echo "$eps" | python3 "$dir/audit_kill.py" "$u" 2>/dev/null
        fi

        # Kill sequence: loginctl terminate-user dulu, lalu pkill -KILL
        loginctl terminate-user "$u" 2>/dev/null
        pkill -KILL -u "$u" 2>/dev/null

        # Tunggu sampai proses hilang (maks 5 detik)
        local waited=0
        while pgrep -u "$u" >/dev/null 2>&1 && [ "$waited" -lt 50 ]; do
            sleep 0.1
            waited=$((waited + 1))
        done

        if pgrep -u "$u" sshd >/dev/null 2>&1; then
            echo -e "${RED}Gagal membersihkan semua sshd $u, masih ada sisa.${NC}"
        else
            echo -e "${GREEN}Sukses menendang $u.${NC}"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Ditendang manual: $u (melebihi batas ${max_login})" >> /root/natssh/logs/autokill.log
        fi
    done
    echo -e "${GREEN}Autokill selesai!${NC}"
}

autokill_riwayat() {
    echo -e "${YELLOW}--- RIWAYAT AUTOKILL TERAKHIR ---${NC}"
    echo ""
    
    local log_autokill="/root/natssh/logs/autokill.log"
    local log_suspend="/root/natssh/logs/suspended_history.log"
    local found=0

    if [ -f "$log_autokill" ] && [ -s "$log_autokill" ]; then
        echo -e "${CYAN}--- Autokill Log ---${NC}"
        tail -n 20 "$log_autokill"
        echo ""
        found=1
    elif [ -f "$log_autokill" ]; then
        echo -e "${YELLOW}Autokill log kosong.${NC}"
        echo ""
    fi

    if [ -f "$log_suspend" ] && [ -s "$log_suspend" ]; then
        echo -e "${CYAN}--- Riwayat Suspend (otomatis) ---${NC}"
        tail -n 20 "$log_suspend"
        echo ""
        found=1
    elif [ -f "$log_suspend" ]; then
        echo -e "${YELLOW}Riwayat suspend kosong.${NC}"
        echo ""
    fi

    if [ "$found" -eq 0 ]; then
        echo -e "${RED}Belum ada riwayat autokill atau suspend.${NC}"
    fi
}

status_sistem() {
    echo -e "${YELLOW}--- STATUS SISTEM ---${NC}"
    free -m | awk 'NR==2{printf "RAM Usage : %s / %s MB (%.2f%%)\n", $3,$2,$3*100/$2 }'
    top -bn1 | grep load | awk '{printf "CPU Load  : %.2f\n", $(NF-2)}'
    echo -e "Disk      : $(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
    # ── RESOURCE SSH ──
    local nsess=$(ps -eo user:40=,comm= | awk '$1!="root" && $2=="sshd" {c++} END{print c+0}')
    local rss_ssh=0
    for u in $(ps -eo user:40=,comm= | awk '$2=="sshd" && $1!="root" {print $1}' | sort -u); do
        local shell=$(awk -F: -v u="$u" '$1==u {print $7}' /etc/passwd 2>/dev/null)
        [ "$shell" == "/bin/false" ] || continue
        local ru=$(ps -eo rss,user:40=,comm | awk -v u="$u" '$2==u && $3=="sshd" {s+=$1} END{printf "%d", s}')
        rss_ssh=$((rss_ssh + ru))
    done
    rss_ssh=$((rss_ssh / 1024))
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

    # ── RESOURCE NGINX ──
    if systemctl is-active --quiet nginx 2>/dev/null; then
        local rss_nginx=$(ps -eo rss,comm | awk '$2=="nginx"{s+=$1} END{printf "%d", s/1024}')
        local n_nginx=$(pgrep -c nginx 2>/dev/null || echo 0)
        echo -e "${CYAN}── RESOURCE NGINX ──${NC}"
        echo -e "Status          : ${GREEN}AKTIF${NC}"
        echo -e "Proses          : ${GREEN}${n_nginx:-0}${NC}"
        echo -e "RAM total       : ${GREEN}${rss_nginx:-0}${NC} MB"
    else
        echo -e "${CYAN}── RESOURCE NGINX ──${NC}"
        echo -e "Status          : ${RED}MATI${NC}"
    fi

    # ── RESOURCE badvpn-udpgw ──
    local udpgw_ports="7100 7200 7300 7400 7500"
    local ada_udpgw=0
    for pp in $udpgw_ports; do
        if systemctl is-active --quiet "natssh-udpgw@${pp}" 2>/dev/null; then
            ada_udpgw=1
            break
        fi
    done
    if [ "$ada_udpgw" -eq 1 ]; then
        echo -e "${CYAN}── RESOURCE badvpn-udpgw ──${NC}"
        for pp in $udpgw_ports; do
            if systemctl is-active --quiet "natssh-udpgw@${pp}" 2>/dev/null; then
                local pid=$(systemctl show "natssh-udpgw@${pp}" -p MainPID --value 2>/dev/null)
                local rss_u=0
                if [ -n "$pid" ] && [ "$pid" != "0" ]; then
                    rss_u=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%d", $1/1024}')
                fi
                echo -e "Port ${pp}        : ${GREEN}AKTIF${NC}  RAM ${GREEN}${rss_u:-0}${NC} MB"
            else
                echo -e "Port ${pp}        : ${RED}MATI${NC}"
            fi
        done
    fi
}

ws_peak() {
    # puncak pemakaian slot jembatan (dari ws.log) — bantu keputusan naik/turun MAX_TOTAL
    local log=$(dirname "${BASH_SOURCE[0]}")/logs/ws.log
    if [ ! -f "$log" ]; then
        echo -e "${RED}Belum ada log ws.log.${NC}"
        return
    fi
    local t peak=0 tolak=0
    peak=$(grep -o "total=[0-9]*" "$log" | cut -d= -f2 | sort -n | tail -1)
    peak=${peak:-0}
    tolak=$(grep -c "TOLAK" "$log")
    # Baca NATSSH_MAX_TOTAL dari .env (sumber tunggal), bukan dari systemd Environment
    local cur_max=$(grep "^NATSSH_MAX_TOTAL=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2)
    cur_max=${cur_max:-150}
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
    printf '%b' "$rows" | python3 "$dir/ws_match.py" "$dir/logs/conns.json" "$dir/logs/ws.log" "$dir/logs/audit_sess.log" "$dir/logs/suspended_history.log"
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
        echo "5. Riwayat Akun (live + sesi)"
        echo "6. Status RAM / CPU / Disk + Resource SSH, Nginx, UDPGW"
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

# Direktori backup terpusat
BACKUP_DIR="/root/natssh_backup"

backup_akun() {
    mkdir -p "$BACKUP_DIR"
    local ts=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/akun_$ts.sh"

    echo -e "${YELLOW}Membuat cadangan data akun SSH...${NC}"

    echo "#!/bin/bash" > "$backup_file"
    echo "# SCRIPT RESTORE AKUN SSH VPN" >> "$backup_file"
    echo "# Tanggal Backup: $(date)" >> "$backup_file"
    echo "# Catatan: Akun yang sudah ada di VPS tujuan tidak akan ditimpa." >> "$backup_file"
    echo "" >> "$backup_file"

    # Hanya akun natssh (yang ada di /root/natssh/limits/)
    local natssh_users=""
    if [ -d /root/natssh/limits ]; then
        for f in /root/natssh/limits/*; do
            [ -f "$f" ] && natssh_users="$natssh_users $(basename "$f")"
        done
    fi

    if [ -z "$natssh_users" ]; then
        echo -e "${YELLOW}Tidak ada akun di /root/natssh/limits/.${NC}"
    fi

    echo "" >> "$backup_file"
    echo "# --- Batas perangkat per akun ---" >> "$backup_file"
    echo "mkdir -p /root/natssh/limits" >> "$backup_file"
    for user in $natssh_users; do
        if [ -f "/root/natssh/limits/$user" ]; then
            lim=$(cat "/root/natssh/limits/$user" 2>/dev/null)
            echo "if [ ! -f "/root/natssh/limits/$user" ]; then" >> "$backup_file"
            echo "    echo "$lim" > /root/natssh/limits/$user" >> "$backup_file"
            echo "else" >> "$backup_file"
            echo "    echo "Limits $user sudah ada, dilewati."" >> "$backup_file"
            echo "fi" >> "$backup_file"
        fi
    done

    local count=0
    for user in $natssh_users; do
        # Skip jika user tidak ada di /etc/passwd
        id "$user" >/dev/null 2>&1 || continue

        hash=$(grep "^${user}:" /etc/shadow 2>/dev/null | cut -d: -f2)
        exp_days=$(grep "^${user}:" /etc/shadow 2>/dev/null | cut -d: -f8)
        if [ -n "$exp_days" ]; then
            exp_date=$(date -d "1970-01-01 + $exp_days days" +"%Y-%m-%d" 2>/dev/null)
            if [ $? -eq 0 ]; then
                echo "if ! id "$user" >/dev/null 2>&1; then" >> "$backup_file"
                echo "    useradd -e "$exp_date" -m -s /bin/false "$user"" >> "$backup_file"
                echo "    usermod -p '$hash' "$user"" >> "$backup_file"
                echo "else" >> "$backup_file"
                echo "    echo "User $user sudah ada, dilewati."" >> "$backup_file"
                echo "fi" >> "$backup_file"
            else
                echo "if ! id "$user" >/dev/null 2>&1; then" >> "$backup_file"
                echo "    useradd -m -s /bin/false "$user"" >> "$backup_file"
                echo "    usermod -p '$hash' "$user"" >> "$backup_file"
                echo "else" >> "$backup_file"
                echo "    echo "User $user sudah ada, dilewati."" >> "$backup_file"
                echo "fi" >> "$backup_file"
            fi
        else
            echo "if ! id "$user" >/dev/null 2>&1; then" >> "$backup_file"
            echo "    useradd -m -s /bin/false "$user"" >> "$backup_file"
            echo "    usermod -p '$hash' "$user"" >> "$backup_file"
            echo "else" >> "$backup_file"
            echo "    echo "User $user sudah ada, dilewati."" >> "$backup_file"
            echo "fi" >> "$backup_file"
        fi
        count=$((count + 1))
    done

    chmod 700 "$backup_file"
    echo -e "${GREEN}SUKSES! Data $count akun, kata sandi, dan batas perangkat berhasil diekstrak.${NC}"
    echo -e "File cadangan tersimpan di: ${CYAN}$backup_file${NC} (mode 700)"
    echo -e "Cara Pakai: pindahkan ke VPS baru lalu jalankan ${CYAN}$backup_file${NC}"
    echo -e "${YELLOW}Catatan: Akun yang sudah ada di VPS tujuan tidak akan ditimpa.${NC}"
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    local ts=$(date +%Y%m%d_%H%M%S)
    local out="$BACKUP_DIR/config_$ts.tar.gz"
    local list=""
    local bakdir="${DIR}/tmp_bak_$$"
    mkdir -p "$bakdir"

    [ -f "${DIR}/config/.env" ] && list="$list ${DIR}/config/.env"
    [ -d "${DIR}/banners" ] && list="$list ${DIR}/banners"
    [ -f /etc/issue.net ] && cp /etc/issue.net "$bakdir/issue.net.bak" && list="$list $bakdir/issue.net.bak"
    [ -f /etc/systemd/system/natssh-ws.service ] && cp /etc/systemd/system/natssh-ws.service "$bakdir/natssh-ws.service.bak" && list="$list $bakdir/natssh-ws.service.bak"

    # Sertifikat SSL untuk nginx
    for sslfile in /etc/nginx/ssl/natssh.pem /etc/nginx/ssl/natssh_key.pem /etc/nginx/ssl/natssh_fullchain.pem; do
        [ -f "$sslfile" ] && cp "$sslfile" "$bakdir/$(basename "$sslfile")" && list="$list $bakdir/$(basename "$sslfile")"
    done

    if [ -z "$list" ]; then
        rm -rf "$bakdir"
        echo -e "${YELLOW}Tidak ada file konfigurasi untuk dibackup.${NC}"
        pause
        return
    fi

    if tar -czf "$out" $list >/dev/null 2>&1; then
        echo -e "${GREEN}SUKSES! Konfigurasi dibackup: ${CYAN}$out${NC}"
    else
        echo -e "${RED}Gagal! Backup konfigurasi gagal.${NC}"
    fi

    # Bersihkan file .ak sementara
    rm -rf "$bakdir"
}

restore_akun() {
    echo -e "${YELLOW}--- RESTORE AKUN SSH ---${NC}"
    echo ""
    echo "File backup akun yang tersedia di $BACKUP_DIR:"
    local i=1
    local files=()
    for f in "$BACKUP_DIR"/akun_*.sh; do
        [ -f "$f" ] || continue
        files+=("$f")
        echo "  $i. $(basename "$f")"
        i=$((i + 1))
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${YELLOW}Tidak ada file backup akun.${NC}"
        pause
        return
    fi

    echo -e "${RED}0. Kembali${NC}"
    read -p "Pilih nomor file untuk restore: " pilih || return
    [ "$pilih" = "0" ] && return

    if ! [[ "$pilih" =~ ^[0-9]+$ ]] || [ "$pilih" -lt 1 ] || [ "$pilih" -gt ${#files[@]} ]; then
        echo -e "${RED}Pilihan tidak valid!${NC}"
        pause
        return
    fi

    local selected="${files[$((pilih - 1))]}"
    echo ""
    echo -e "${YELLOW}Peringatan: Akun yang sudah ada di VPS ini tidak akan ditimpa.${NC}"
    echo -e "${YELLOW}Hanya akun baru yang akan dibuat.${NC}"
    read -p "Lanjutkan restore? (y/N): " konfirm || return
    if [[ ! "$konfirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi

    bash "$selected"
    local rc=$?
    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}SUKSES! Restore akun selesai.${NC}"
    else
        echo -e "${RED}Gagal! Beberapa akun mungkin tidak terbuat.${NC}"
    fi
}

restore_config() {
    echo -e "${YELLOW}--- RESTORE KONFIGURASI ---${NC}"
    echo ""
    echo "File backup konfigurasi yang tersedia di $BACKUP_DIR:"
    local i=1
    local files=()
    for f in "$BACKUP_DIR"/config_*.tar.gz; do
        [ -f "$f" ] || continue
        files+=("$f")
        echo "  $i. $(basename "$f")"
        i=$((i + 1))
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${YELLOW}Tidak ada file backup konfigurasi.${NC}"
        pause
        return
    fi

    echo -e "${RED}0. Kembali${NC}"
    read -p "Pilih nomor file untuk restore: " pilih || return
    [ "$pilih" = "0" ] && return

    if ! [[ "$pilih" =~ ^[0-9]+$ ]] || [ "$pilih" -lt 1 ] || [ "$pilih" -gt ${#files[@]} ]; then
        echo -e "${RED}Pilihan tidak valid!${NC}"
        pause
        return
    fi

    local selected="${files[$((pilih - 1))]}"
    echo ""
    echo -e "${YELLOW}Peringatan: File konfigurasi yang sudah ada akan ditimpa.${NC}"
    read -p "Lanjutkan restore konfigurasi? (y/N): " konfirm || return
    if [[ ! "$konfirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi

    local tmpdir="/tmp/natssh_restore_$$"
    mkdir -p "$tmpdir"
    if tar -xzf "$selected" -C "$tmpdir" 2>/dev/null; then
        [ -f "$tmpdir/.env" ] && cp "$tmpdir/.env" "${DIR}/config/.env"
        [ -d "$tmpdir/banners" ] && cp -r "$tmpdir/banners" "${DIR}/"
        [ -f "$tmpdir/issue.net.bak" ] && cp "$tmpdir/issue.net.bak" /etc/issue.net
        [ -f "$tmpdir/natssh-ws.service.bak" ] && cp "$tmpdir/natssh-ws.service.bak" /etc/systemd/system/natssh-ws.service

        # Kembalikan sertifikat SSL untuk nginx
        for sslfile in natssh.pem natssh_key.pem natssh_fullchain.pem; do
            [ -f "$tmpdir/$sslfile" ] && cp "$tmpdir/$sslfile" /etc/nginx/ssl/
        done

        rm -rf "$tmpdir"

        muat_env
        systemctl daemon-reload 2>/dev/null

        # Terapkan port nginx dari .env ke konfigurasi nginx yang aktif
        if [ -f "${DIR}/config/.env" ] && [ -f /etc/nginx/sites-enabled/natssh-ws ]; then
            nginx_reverse=$(grep "^NGINX_REVERSE_PORT=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2)
            if [ -n "$nginx_reverse" ]; then
                sed -i "s/^    listen [0-9]* ssl;/    listen ${nginx_reverse} ssl;/" /etc/nginx/sites-enabled/natssh-ws
            fi
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx
            else
                echo -e "${RED}Konfigurasi nginx gagal diuji. Periksa /etc/nginx/sites-enabled/natssh-ws${NC}"
            fi
        fi

        echo -e "${GREEN}SUKSES! Konfigurasi direstore.${NC}"
        echo ""
        read -p "Restart natssh-ws sekarang agar perubahan berlaku? (y/N): " restart_ns || true
        if [[ "$restart_ns" =~ ^[Yy]$ ]]; then
            systemctl restart natssh-ws
            sleep 1
            if systemctl is-active --quiet natssh-ws; then
                echo -e "${GREEN}natssh-ws berhasil direstart.${NC}"
            else
                echo -e "${RED}Gagal restart natssh-ws! Cek: journalctl -u natssh-ws -n 20${NC}"
            fi
        else
            echo -e "${YELLOW}Restart ditunda. Beberapa perubahan belum berlaku sampai natssh-ws direstart.${NC}"
        fi
    else
        rm -rf "$tmpdir"
        echo -e "${RED}Gagal! Gagal mengekstrak file backup.${NC}"
    fi
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
    echo -e "${RED}0. Kembali${NC}"
    read -p "Pilih: " a
    case $a in
        1)
            (crontab -l 2>/dev/null | grep -v "autobackup.sh"; echo "0 2 * * * /root/natssh/autobackup.sh") | crontab -
            echo -e "${GREEN}Auto-backup harian 02:00 diaktifkan.${NC}" ;;
        2)
            (crontab -l 2>/dev/null | grep -v "autobackup.sh"; echo "0 */6 * * * /root/natssh/autobackup.sh") | crontab -
            echo -e "${GREEN}Auto-backup tiap 6 jam diaktifkan.${NC}" ;;
        3)
            (crontab -l 2>/dev/null | grep -v "autobackup.sh") | crontab -
            echo -e "${YELLOW}Auto-backup dinonaktifkan.${NC}" ;;
        0) return ;;
        *) echo -e "${RED}Tidak valid${NC}" ;;
    esac
}

menu_backup() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   BACKUP & RESTORE${NC}"
        garis
        echo "1. Backup Data Akun (Ekspor Portabel)"
        [ -d "$BACKUP_DIR" ] && ls -1t "$BACKUP_DIR"/akun_*.sh 2>/dev/null | head -1 | xargs -r basename | xargs -r -I{} echo -e "   (terakhir: {})"
        echo "2. Backup Konfigurasi (tar.gz)"
        [ -d "$BACKUP_DIR" ] && ls -1t "$BACKUP_DIR"/config_*.tar.gz 2>/dev/null | head -1 | xargs -r basename | xargs -r -I{} echo -e "   (terakhir: {})"
        echo "3. Restore Data Akun (dari file backup)"
        echo "4. Restore Konfigurasi (dari file backup)"
        echo "5. Atur Auto-Backup (Konfigurasi)"
        echo -e "${RED}0. Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-5): " p || exit 0
        case $p in
            1) backup_akun ;;
            2) backup_config ;;
            3) restore_akun ;;
            4) restore_config ;;
            5) conf_autobackup ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && pause
    done
}
conf_maxlogin() {
    local selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # Baca nilai saat ini dari config/.env (sumber tunggal), fallback crontab, fallback 5
    if [ -f "${selfdir}/config/.env" ] && grep -q "^MAX_LOGIN=" "${selfdir}/config/.env"; then
        cur=$(grep "^MAX_LOGIN=" "${selfdir}/config/.env" | cut -d= -f2)
    elif crontab -l 2>/dev/null | grep -q "MAX_LOGIN="; then
        cur=$(crontab -l 2>/dev/null | grep -o "MAX_LOGIN=[0-9]*" | head -1 | cut -d= -f2)
    else
        cur=5
    fi
    echo -e "Batas saat ini: ${YELLOW}${cur} perangkat/akun${NC} (dari config/.env)"
    read -p "Batas perangkat baru (1-20): " max_login
    if ! [[ "$max_login" =~ ^[0-9]+$ ]] || [ "$max_login" -lt 1 ] || [ "$max_login" -gt 20 ]; then
        echo -e "${RED}Gagal: harus angka 1-20!${NC}"
    else
        # Tulis ke config/.env (sumber tunggal)
        if [ -f "${selfdir}/config/.env" ]; then
            if grep -q "^MAX_LOGIN=" "${selfdir}/config/.env"; then
                sed -i "s/^MAX_LOGIN=.*/MAX_LOGIN=$max_login/" "${selfdir}/config/.env"
            else
                echo "MAX_LOGIN=$max_login" >> "${selfdir}/config/.env"
            fi
        else
            echo "MAX_LOGIN=$max_login" > "${selfdir}/config/.env"
        fi
        muat_env
        # Bersihkan injeksi MAX_LOGIN= dari crontab autokill; autokill.sh baca dari .env
        if crontab -l 2>/dev/null | grep -q "autokill.sh"; then
            (crontab -l 2>/dev/null | sed 's/MAX_LOGIN=[0-9]* //') | crontab -
        fi
        sed -i "s/Maksimal [0-9]* Perangkat/Maksimal $max_login Perangkat/g" /etc/issue.net
        echo -e "${GREEN}SUKSES! Batas menjadi ${max_login} perangkat (config/.env + banner diperbarui).${NC}"
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
        if [ -f "${DIR}/config/.env" ]; then
            if grep -q "^NATSSH_WS_PORT=" "${DIR}/config/.env"; then
                sed -i "s/^NATSSH_WS_PORT=.*/NATSSH_WS_PORT=$new_port/" "${DIR}/config/.env"
            else
                echo "NATSSH_WS_PORT=$new_port" >> "${DIR}/config/.env"
            fi
        else
            echo "NATSSH_WS_PORT=$new_port" > "${DIR}/config/.env"
        fi
        muat_env
        echo -e "${YELLOW}Restart natssh-ws — koneksi aktif terputus 2-3 detik...${NC}"
        read -p "Yakin restart? Koneksi aktif akan terputus (y/N): " cfr
        if [[ ! "$cfr" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Dibatalkan.${NC}"
            pause
            continue
        fi
        systemctl daemon-reload
        systemctl restart natssh-ws
        sleep 1
        if systemctl is-active --quiet natssh-ws; then
            echo -e "${GREEN}SUKSES! WebSocket kini di port $new_port.${NC}"
            # Update nginx proxy_forward ke port ws baru
            ngconf=/etc/nginx/sites-available/natssh-ws
            if [ -f "$ngconf" ]; then
                sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:$new_port;|" "$ngconf"
                if nginx -t >/dev/null 2>&1 && systemctl restart nginx; then
                    echo -e "${GREEN}Nginx diupdate forward ke port $new_port.${NC}"
                else
                    echo -e "${RED}Nginx gagal restart! Cek: journalctl -u nginx -n 20${NC}"
                fi
            else
                echo -e "${YELLOW}Config nginx tidak ditemukan di $ngconf, lewati.${NC}"
            fi
        else
            echo -e "${RED}Service gagal start! Cek: journalctl -u natssh-ws -n 20${NC}"
        fi
    fi
}

# Ekstraksi root domain menggunakan Public Suffix List (unduh dari publicsuffix.org)
conf_service() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   KONTROL LAYANAN NATSSH-WS${NC}"
        garis
        status=$(systemctl is-active natssh-ws 2>/dev/null)
        echo -e "Status saat ini: ${GREEN}${status}${NC}"
        ws_port=$(port_ws 2>/dev/null || echo "-")
        echo -e "Port WebSocket: ${YELLOW}${ws_port}${NC}"
        echo ""
        echo "1. Start"
        echo "2. Stop"
        echo "3. Restart"
        echo "4. Toggle Keepalive SSH"
        echo "5. Toggle Heartbeat WS"
        echo "6. Ubah Port WebSocket"
        echo -e "${RED}0. Kembali${NC}"
        read -p "Pilih (0-6): " p || exit 0
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
            4) conf_keepalive; continue ;;
            5) conf_heartbeat; continue ;;
            6) conf_port ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

conf_service_direct() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   KONTROL LAYANAN SSH DIRECT${NC}"
        garis
        if grep -q "^NATSSH_SSH_DIRECT_ENABLED=1" "${DIR}/config/.env" 2>/dev/null; then
            echo -e "SSH Direct: ${GREEN}AKTIF${NC}"
        else
            echo -e "SSH Direct: ${RED}NONAKTIF${NC}"
        fi
        direct_port=$(port_direct 2>/dev/null || echo "-")
        echo -e "Port SSH Direct: ${YELLOW}${direct_port}${NC}"
        echo ""
        echo "1. Toggle SSH Direct"
        echo "2. Ubah Port SSH Direct"
        echo -e "${RED}0. Kembali${NC}"
        read -p "Pilih (0-2): " p || exit 0
        case $p in
            1) conf_toggle_ssh_direct ; continue ;;
            2) conf_port_direct ; continue ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

conf_udpgw_service() {
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
        if [ -z "$active" ]; then
            st_text="inactive"
            st_color="${RED}"
        else
            st_text="active"
            st_color="${GREEN}"
        fi
        echo -e "Status : ${st_color}${st_text}${NC}  Port aktif:${YELLOW}${active:- (none)}${NC}"
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
                    [ "$st" = "active" ] && st="active" || st="inactive"
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
                    systemctl disable --now natssh-udpgw@${pp} >/dev/null 2>&1 && echo -e "${GREEN}${pp} nonaktif${NC}" || echo -e "${RED}non-active${NC}"
                else
                    systemctl enable --now natssh-udpgw@${pp} >/dev/null 2>&1 && echo -e "${GREEN}${pp} aktif${NC}" || echo -e "${RED}non-active${NC}"
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && pause
    done
}

conf_nginx_service() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   KONTROL LAYANAN NGINX${NC}"
        garis
        status=$(systemctl is-active nginx 2>/dev/null)
        echo -e "Status saat ini: ${GREEN}${status}${NC}"
        if [ -f "${DIR}/config/.env" ] && grep -q "^NGINX_REVERSE_PORT=" "${DIR}/config/.env"; then
            nginx_port=$(grep "^NGINX_REVERSE_PORT=" "${DIR}/config/.env" | cut -d= -f2)
        else
            nginx_port=$(grep "listen" /etc/nginx/sites-available/natssh-ws 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || echo "-")
        fi
        echo -e "Port Nginx Reverse: ${YELLOW}${nginx_port:-tidak diketahui}${NC}"
        stream_port=$(port_nginx_stream 2>/dev/null || echo "-")
        echo -e "Port Nginx Stream: ${YELLOW}${stream_port}${NC}"
        echo ""
        echo "1. Start"
        echo "2. Stop"
        echo "3. Restart"
        echo "4. Ubah Port Nginx Reverse"
        echo "5. Ubah Port Nginx Stream"
        echo -e "${RED}0. Kembali${NC}"
        read -p "Pilih (0-5): " p || exit 0
        case $p in
            1)
                echo -e "${YELLOW}Menjalankan nginx...${NC}"
                systemctl start nginx
                sleep 2
                systemctl is-active --quiet nginx && echo -e "${GREEN}SUKSES! nginx berjalan.${NC}" || echo -e "${RED}Gagal start!${NC}"
                pause
                ;;
            2)
                echo -e "${YELLOW}Menghentikan nginx...${NC}"
                echo -e "${RED}PERINGATAN: Semua koneksi WebSocket via nginx akan terputus!${NC}"
                read -p "Yakin stop? (y/N): " y
                if [[ "$y" =~ ^[Yy]$ ]]; then
                    systemctl stop nginx
                    sleep 2
                    systemctl is-active --quiet nginx && echo -e "${RED}Masih berjalan!${NC}" || echo -e "${GREEN}Berhasil dihentikan.${NC}"
                else
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                fi
                pause
                ;;
            3)
                echo -e "${YELLOW}Me-restart nginx...${NC}"
                echo -e "${RED}PERINGATAN: Semua koneksi WebSocket via nginx akan terputus!${NC}"
                read -p "Yakin restart? (y/N): " y
                if [[ "$y" =~ ^[Yy]$ ]]; then
                    systemctl restart nginx
                    sleep 3
                    systemctl is-active --quiet nginx && echo -e "${GREEN}SUKSES! nginx berjalan kembali.${NC}" || echo -e "${RED}Gagal restart!${NC}"
                else
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                fi
                pause
                ;;
            4) conf_nginx_port ;;
            5) conf_nginx_stream_port ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

_ensure_speed_service() {
    # pastikan unit systemd natssh-speed ada (buat jika belum) agar limit persist setelah reboot
    local unit=/etc/systemd/system/natssh-speed.service
    if [ ! -f "$unit" ]; then
        cat > "$unit" <<UNIT
[Unit]
Description=NATSSH SSH speed limit (tc)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/natssh/apply_speed.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload 2>/dev/null
    fi
}

conf_speed() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}--- ATUR LIMIT SPEED per CDN ---${NC}"
        garis
        iface_status=$(grep "^IFACE=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2)
        iface_status=${iface_status:-eth0}
        if tc class show dev "$iface_status" 2>/dev/null | grep -q "class htb.*1:10"; then
            _limits=$(grep -E "^(UP|DOWN)_" "${DIR}/config/.env" 2>/dev/null)
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
        echo -e "${RED}0. Kembali${NC}"
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
                    val=${!v}; if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$val" =~ ^\.[0-9]+$ ]]; then eval "$v=${val}mbit"; else echo -e "${RED}Gagal: harus angka!${NC}"; pause; continue 2; fi
                done
                # update only CF fields in .env
                iface=$(ip route | grep default | awk '{print $5}' | head -1); iface=${iface:-eth0}
                if [ ! -f "${DIR}/config/.env" ]; then
                    echo "IFACE=$iface" > "${DIR}/config/.env"
                    echo "MODE=cdn-split" >> "${DIR}/config/.env"
                fi
                sed -i "s/^IFACE=.*/IFACE=$iface/" "${DIR}/config/.env"
                # ensure CF fields exist
                grep -q "^UP_CF=" "${DIR}/config/.env" || echo "UP_CF=25mbit" >> "${DIR}/config/.env"
                grep -q "^DOWN_CF=" "${DIR}/config/.env" || echo "DOWN_CF=25mbit" >> "${DIR}/config/.env"
                sed -i "s/^UP_CF=.*/UP_CF=$up/" "${DIR}/config/.env"
                sed -i "s/^DOWN_CF=.*/DOWN_CF=$down/" "${DIR}/config/.env"
                ip link show "$iface" >/dev/null 2>&1 || { echo -e "${RED}Interface $iface tidak ditemukan!${NC}"; pause; continue; }
                muat_env
                bash /root/natssh/apply_speed.sh || { echo -e "${RED}Gagal menerapkan limit! Cek log: /root/natssh/logs/apply_speed.log${NC}"; pause; continue; }
                _ensure_speed_service
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
                    val=${!v}; if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$val" =~ ^\.[0-9]+$ ]]; then eval "$v=${val}mbit"; else echo -e "${RED}Gagal: harus angka!${NC}"; pause; continue 2; fi
                done
                iface=$(ip route | grep default | awk '{print $5}' | head -1); iface=${iface:-eth0}
                if [ ! -f "${DIR}/config/.env" ]; then
                    echo "IFACE=$iface" > "${DIR}/config/.env"
                    echo "MODE=cdn-split" >> "${DIR}/config/.env"
                fi
                sed -i "s/^IFACE=.*/IFACE=$iface/" "${DIR}/config/.env"
                # ensure CFront fields exist
                grep -q "^UP_CFRONT=" "${DIR}/config/.env" || echo "UP_CFRONT=25mbit" >> "${DIR}/config/.env"
                grep -q "^DOWN_CFRONT=" "${DIR}/config/.env" || echo "DOWN_CFRONT=25mbit" >> "${DIR}/config/.env"
                sed -i "s/^UP_CFRONT=.*/UP_CFRONT=$up/" "${DIR}/config/.env"
                sed -i "s/^DOWN_CFRONT=.*/DOWN_CFRONT=$down/" "${DIR}/config/.env"
                ip link show "$iface" >/dev/null 2>&1 || { echo -e "${RED}Interface $iface tidak ditemukan!${NC}"; pause; continue; }
                muat_env
                bash /root/natssh/apply_speed.sh || { echo -e "${RED}Gagal menerapkan limit! Cek log: /root/natssh/logs/apply_speed.log${NC}"; pause; continue; }
                _ensure_speed_service
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
                    val=${!v}; if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$val" =~ ^\.[0-9]+$ ]]; then eval "$v=${val}mbit"; else echo -e "${RED}Gagal: harus angka!${NC}"; pause; continue 2; fi
                done
                iface=$(ip route | grep default | awk '{print $5}' | head -1); iface=${iface:-eth0}
                # Update .env dengan semua kecepatan CDN (tanpa menghapus key lain)
                if [ -f "${DIR}/config/.env" ]; then
                    sed -i "s/^IFACE=.*/IFACE=$iface/" "${DIR}/config/.env"
                    grep -q "^IFACE=" "${DIR}/config/.env" || echo "IFACE=$iface" >> "${DIR}/config/.env"
                    sed -i "s/^UP_CF=.*/UP_CF=$up_cf/" "${DIR}/config/.env"
                    grep -q "^UP_CF=" "${DIR}/config/.env" || echo "UP_CF=$up_cf" >> "${DIR}/config/.env"
                    sed -i "s/^DOWN_CF=.*/DOWN_CF=$down_cf/" "${DIR}/config/.env"
                    grep -q "^DOWN_CF=" "${DIR}/config/.env" || echo "DOWN_CF=$down_cf" >> "${DIR}/config/.env"
                    sed -i "s/^UP_CFRONT=.*/UP_CFRONT=$up_cfront/" "${DIR}/config/.env"
                    grep -q "^UP_CFRONT=" "${DIR}/config/.env" || echo "UP_CFRONT=$up_cfront" >> "${DIR}/config/.env"
                    sed -i "s/^DOWN_CFRONT=.*/DOWN_CFRONT=$down_cfront/" "${DIR}/config/.env"
                    grep -q "^DOWN_CFRONT=" "${DIR}/config/.env" || echo "DOWN_CFRONT=$down_cfront" >> "${DIR}/config/.env"
                    sed -i "s/^MODE=.*/MODE=cdn-split/" "${DIR}/config/.env"
                    grep -q "^MODE=" "${DIR}/config/.env" || echo "MODE=cdn-split" >> "${DIR}/config/.env"
                else
                    echo "IFACE=$iface" > "${DIR}/config/.env"
                    echo "UP_CF=$up_cf" >> "${DIR}/config/.env"
                    echo "DOWN_CF=$down_cf" >> "${DIR}/config/.env"
                    echo "UP_CFRONT=$up_cfront" >> "${DIR}/config/.env"
                    echo "DOWN_CFRONT=$down_cfront" >> "${DIR}/config/.env"
                    echo "MODE=cdn-split" >> "${DIR}/config/.env"
                fi
                ip link show "$iface" >/dev/null 2>&1 || { echo -e "${RED}Interface $iface tidak ditemukan!${NC}"; pause; continue; }
                muat_env
                bash /root/natssh/apply_speed.sh || { echo -e "${RED}Gagal menerapkan limit! Cek log: /root/natssh/logs/apply_speed.log${NC}"; pause; continue; }
                _ensure_speed_service
                systemctl enable --now natssh-speed.service 2>/dev/null
                echo -e "${GREEN}Limit semua CDN diterapkan.${NC}"; pause ;;
            4)
                tc qdisc del dev eth0 root 2>/dev/null
                tc qdisc del dev eth0 ingress 2>/dev/null
                ip link set dev ifb0 down 2>/dev/null
                ip link del ifb0 2>/dev/null
                if [ -f "${DIR}/config/.env" ]; then
                    sed -i "/^IFACE=/d" "${DIR}/config/.env"
                    sed -i "/^MODE=/d" "${DIR}/config/.env"
                    sed -i "/^UP_CF=/d" "${DIR}/config/.env"
                    sed -i "/^DOWN_CF=/d" "${DIR}/config/.env"
                    sed -i "/^UP_CFRONT=/d" "${DIR}/config/.env"
                    sed -i "/^DOWN_CFRONT=/d" "${DIR}/config/.env"
                    muat_env
                fi
                systemctl disable --now natssh-speed.service 2>/dev/null
                echo -e "${GREEN}Limit speed dihapus.${NC}"; pause ;;
            5)
                iface=$(grep "^IFACE=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2); iface=${iface:-eth0}
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
    echo -e "${YELLOW}--- PENJADWALAN ---${NC}"
    echo ""
    # Tampilkan daftar cron restart aktif per layanan
    for svc in natssh-ws natssh-udpgw nginx; do
        line=$(crontab -l 2>/dev/null | grep "systemctl.*restart.*${svc}" | head -1)
        if [ -n "$line" ]; then
            echo -e "  ${CYAN}${svc}${NC}: ${GREEN}AKTIF${NC} | ${line}"
        else
            echo -e "  ${CYAN}${svc}${NC}: ${RED}TIDAK ADA JADWAL${NC}"
        fi
    done
    echo ""
    # Tampilkan jadwal apply_speed dan generate_cdn_geo
    if crontab -l 2>/dev/null | grep -q "apply_speed.sh"; then
        echo -e "  ${CYAN}apply_speed${NC}: ${GREEN}AKTIF${NC} | $(crontab -l 2>/dev/null | grep 'apply_speed.sh' | head -1)"
    else
        echo -e "  ${CYAN}apply_speed${NC}: ${RED}TIDAK ADA JADWAL${NC}"
    fi
    if crontab -l 2>/dev/null | grep -q "generate_cdn_geo.sh"; then
        echo -e "  ${CYAN}generate_cdn_geo${NC}: ${GREEN}AKTIF${NC} | $(crontab -l 2>/dev/null | grep 'generate_cdn_geo.sh' | head -1)"
    else
        echo -e "  ${CYAN}generate_cdn_geo${NC}: ${RED}TIDAK ADA JADWAL${NC}"
    fi
    if crontab -l 2>/dev/null | grep -q "/usr/sbin/reboot"; then
        echo -e "  ${CYAN}reboot${NC}: ${GREEN}AKTIF${NC} | $(crontab -l 2>/dev/null | grep '/usr/sbin/reboot' | head -1)"
    else
        echo -e "  ${CYAN}reboot${NC}: ${RED}TIDAK ADA JADWAL${NC}"
    fi
    echo ""
    echo "Pilih layanan untuk diatur:"
    echo "1. natssh-ws (WebSocket)"
    echo "2. natssh-udpgw (UDP Gateway)"
    echo "3. nginx (Reverse Proxy)"
    echo "4. apply_speed.sh (Refresh IP + limit speed)"
    echo "5. generate_cdn_geo.sh (Generate cdn_geo.conf)"
    echo "6. Atur Jadwal Reboot"
    echo -e "${RED}0. Batal${NC}"
    read -p "Pilih (0-6): " p
    case $p in
        1) toggle_service_cron "natssh-ws" "/usr/bin/systemctl restart natssh-ws" "WebSocket" ;;
        2) toggle_service_cron "natssh-udpgw" "/usr/bin/systemctl restart 'natssh-udpgw@*'" "UDP Gateway" ;;
        3) toggle_service_cron "nginx" "/usr/bin/systemctl restart nginx" "Nginx Reverse Proxy" ;;
        4) toggle_script_cron "apply_speed" "/root/natssh/apply_speed.sh" "Apply Speed Limit" ;;
        5) toggle_script_cron "generate_cdn_geo" "/root/natssh/generate_cdn_geo.sh" "Generate CDN Geo" ;;
        6) toggle_reboot_cron ;;
        0) echo -e "${YELLOW}Dibatalkan.${NC};;
        *) echo -e "${RED}Pilihan tidak valid!${NC};;
    esac
}

toggle_service_cron() {
    local svc_name="$1"
    local restart_cmd="$2"
    local svc_label="$3"

    if crontab -l 2>/dev/null | grep -q "systemctl.*restart.*${svc_name}"; then
        echo -e "${YELLOW}${svc_label} sudah aktif di jadwal restart:${NC}"
        crontab -l | grep "systemctl.*restart.*${svc_name}"
        echo ""
        read -p "Hapus jadwal restart ${svc_label}? (y/N): " h
        if [[ "$h" =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null | grep -v "systemctl.*restart.*${svc_name}") | crontab -
            echo -e "${GREEN}Jadwal restart ${svc_label} dihapus.${NC}"
        else
            echo -e "${YELLOW}Jadwal restart ${svc_label} tetap aktif.${NC}"
        fi
    else
        echo -e "${YELLOW}${svc_label} belum ada jadwal restart.${NC}"
        echo ""
        echo "Pilih jadwal:"
        echo "1. Setiap jam"
        echo "2. Setiap 6 jam"
        echo "3. Setiap 12 jam"
        echo "4. Setiap hari jam 04:00"
        echo "5. Custom"
        echo -e "${RED}0. Batal${NC}"
        read -p "Pilih (0-5): " sp
        case $sp in
            1) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 * * * * ${restart_cmd} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${svc_label}: setiap jam.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            2) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 */6 * * * ${restart_cmd} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${svc_label}: setiap 6 jam.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            3) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 */12 * * * ${restart_cmd} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${svc_label}: setiap 12 jam.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            4) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 4 * * * ${restart_cmd} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${svc_label}: setiap hari jam 04:00.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            5)
                read -p "Masukkan cron (contoh: 0 4 * * *): " cron
                if [ -z "$cron" ]; then
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                elif [[ ! "$cron" =~ ^[0-9*/,\-]+([[:space:]]+[0-9*/,\-]+){4} ]]; then
                    echo -e "${RED}Gagal: format cron tidak valid!${NC}"
                else
                    read -p "Lanjut? (y/N): " y
                    if [[ "$y" =~ ^[Yy]$ ]]; then
                        (crontab -l 2>/dev/null; echo "${cron} ${restart_cmd} >/dev/null 2>&1") | crontab -
                        echo -e "${GREEN}${svc_label}: jadwal custom tersimpan.${NC}"
                    else
                        echo -e "${YELLOW}Dibatalkan.${NC}"
                    fi
                fi
                ;;
            0) echo -e "${YELLOW}Dibatalkan.${NC};;
            *) echo -e "${RED}Pilihan tidak valid!${NC};;
        esac
    fi
}
toggle_script_cron() {
    local script_name="$1"
    local script_path="$2"
    local script_label="$3"

    if crontab -l 2>/dev/null | grep -q "${script_path}"; then
        echo -e "${YELLOW}${script_label} sudah aktif di jadwal cron:${NC}"
        crontab -l | grep "${script_path}"
        echo ""
        read -p "Hapus jadwal cron ${script_label}? (y/N): " h
        if [[ "$h" =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null | grep -v "${script_path}") | crontab -
            echo -e "${GREEN}Jadwal cron ${script_label} dihapus.${NC}"
        else
            echo -e "${YELLOW}Jadwal cron ${script_label} tetap aktif.${NC}"
        fi
    else
        echo -e "${YELLOW}${script_label} belum ada jadwal cron.${NC}"
        echo ""
        echo "Pilih jadwal:"
        echo "1. Setiap jam"
        echo "2. Setiap 6 jam"
        echo "3. Setiap 12 jam"
        echo "4. Setiap hari jam 03:00"
        echo "5. Custom"
        echo -e "${RED}0. Batal${NC}"
        read -p "Pilih (0-5): " sp
        case $sp in
            1) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 * * * * ${script_path} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${script_label}: setiap jam.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            2) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 */6 * * * ${script_path} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${script_label}: setiap 6 jam.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            3) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 */12 * * * ${script_path} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${script_label}: setiap 12 jam.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            4) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 3 * * * ${script_path} >/dev/null 2>&1") | crontab - && echo -e "${GREEN}${script_label}: setiap hari jam 03:00.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            5)
                read -p "Masukkan cron (contoh: 0 4 * * *): " cron
                if [ -z "$cron" ]; then
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                elif [[ ! "$cron" =~ ^[0-9*/,\-]+([[:space:]]+[0-9*/,\-]+){4} ]]; then
                    echo -e "${RED}Gagal: format cron tidak valid!${NC}"
                else
                    read -p "Lanjut? (y/N): " y
                    if [[ "$y" =~ ^[Yy]$ ]]; then
                        (crontab -l 2>/dev/null; echo "${cron} ${script_path} >/dev/null 2>&1") | crontab -
                        echo -e "${GREEN}${script_label}: jadwal custom tersimpan.${NC}"
                    else
                        echo -e "${YELLOW}Dibatalkan.${NC}"
                    fi
                fi
                ;;
            0) echo -e "${YELLOW}Dibatalkan.${NC};;
            *) echo -e "${RED}Pilihan tidak valid!${NC};;
        esac
    fi
}

toggle_reboot_cron() {
    if crontab -l 2>/dev/null | grep -q "/usr/sbin/reboot"; then
        echo -e "${YELLOW}Jadwal reboot sudah aktif:${NC}"
        crontab -l 2>/dev/null | grep "/usr/sbin/reboot"
        echo ""
        read -p "Hapus jadwal reboot? (y/N): " h
        if [[ "$h" =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null | grep -v "/usr/sbin/reboot") | crontab -
            echo -e "${GREEN}Jadwal reboot dihapus.${NC}"
        else
            echo -e "${YELLOW}Jadwal reboot tetap aktif.${NC}"
        fi
    else
        echo -e "${YELLOW}Belum ada jadwal reboot.${NC}"
        echo ""
        echo "Pilih jadwal:"
        echo "1. Setiap hari 03:00"
        echo "2. Setiap hari 04:00"
        echo "3. Setiap 12 jam"
        echo "4. Custom"
        echo -e "${RED}0. Batal${NC}"
        read -p "Pilih (0-4): " sp
        case $sp in
            1) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 3 * * * /usr/sbin/reboot >/dev/null 2>&1") | crontab - && echo -e "${GREEN}Jadwal reboot: setiap hari 03:00.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            2) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 4 * * * /usr/sbin/reboot >/dev/null 2>&1") | crontab - && echo -e "${GREEN}Jadwal reboot: setiap hari 04:00.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            3) read -p "Lanjut? (y/N): " y; if [[ "$y" =~ ^[Yy]$ ]]; then (crontab -l 2>/dev/null; echo "0 */12 * * * /usr/sbin/reboot >/dev/null 2>&1") | crontab - && echo -e "${GREEN}Jadwal reboot: setiap 12 jam.${NC}"; else echo -e "${YELLOW}Dibatalkan.${NC}"; fi;;
            4)
                read -p "Masukkan cron (contoh: 0 4 * * *): " cron
                if [ -z "$cron" ]; then
                    echo -e "${YELLOW}Dibatalkan.${NC}"
                elif [[ ! "$cron" =~ ^[0-9*/,\-]+([[:space:]]+[0-9*/,\-]+){4} ]]; then
                    echo -e "${RED}Gagal: format cron tidak valid!${NC}"
                else
                    read -p "Lanjut? (y/N): " y
                    if [[ "$y" =~ ^[Yy]$ ]]; then
                        (crontab -l 2>/dev/null; echo "${cron} /usr/sbin/reboot >/dev/null 2>&1") | crontab -
                        echo -e "${GREEN}Jadwal reboot custom tersimpan.${NC}"
                    else
                        echo -e "${YELLOW}Dibatalkan.${NC}"
                    fi
                fi
                ;;
            0) echo -e "${YELLOW}Dibatalkan.${NC};;
            *) echo -e "${RED}Pilihan tidak valid!${NC};;
        esac
    fi
}

conf_maxtotal() {
    # batas koneksi serentak jembatan (NATSSH_MAX_TOTAL di config/.env)
    if [ -f "${DIR}/config/.env" ] && grep -q "^NATSSH_MAX_TOTAL=" "${DIR}/config/.env"; then
        cur=$(grep "^NATSSH_MAX_TOTAL=" "${DIR}/config/.env" | cut -d= -f2)
    else
        cur=150
    fi
    local peak=$(grep -o "total=[0-9]*" "$(dirname "${BASH_SOURCE[0]}")/ws.log" 2>/dev/null | cut -d= -f2 | sort -n | tail -1)
    echo -e "Batas koneksi serentak (NATSSH_MAX_TOTAL) : ${YELLOW}${cur}${NC} slot"
    echo -e "Puncak pemakaian sejauh ini        : ${GREEN}${peak:-0}${NC} slot${NC}"
    read -p "Nilai baru (10-200, 0 = batal): " n
    [ "$n" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 10 ] || [ "$n" -gt 200 ]; then
        echo -e "${RED}Gagal: harus angka 10-200!${NC}"
        return
    fi
    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^NATSSH_MAX_TOTAL=" "${DIR}/config/.env"; then
            sed -i "s/^NATSSH_MAX_TOTAL=.*/NATSSH_MAX_TOTAL=$n/" "${DIR}/config/.env"
        else
            echo "NATSSH_MAX_TOTAL=$n" >> "${DIR}/config/.env"
        fi
    else
        echo "NATSSH_MAX_TOTAL=$n" > "${DIR}/config/.env"
    fi
    muat_env
    echo -e "${YELLOW}Restart natssh-ws — koneksi aktif terputus 2-3 detik...${NC}"
    read -p "Yakin restart? Koneksi aktif akan terputus (y/N): " cfr2
    if [[ ! "$cfr2" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        return
    fi
    systemctl restart natssh-ws
    sleep 1
    systemctl is-active --quiet natssh-ws &&         echo -e "${GREEN}SUKSES! NATSSH_MAX_TOTAL kini $n slot.${NC}" || \
        echo -e "${RED}Service gagal start! Cek: journalctl -u natssh-ws -n 20${NC}"
}

conf_maxperip() {
    # batas koneksi serentak per IP (NATSSH_MAX_PER_IP di config/.env)
    if [ -f "${DIR}/config/.env" ] && grep -q "^NATSSH_MAX_PER_IP=" "${DIR}/config/.env"; then
        cur=$(grep "^NATSSH_MAX_PER_IP=" "${DIR}/config/.env" | cut -d= -f2)
    else
        cur=10
    fi
    echo -e "Batas koneksi per IP (NATSSH_MAX_PER_IP)  : ${YELLOW}${cur}${NC} koneksi"
    echo -e "Catatan: jika pakai nginx reverse proxy, IP asli klien dibaca lewat header X-Forwarded-For."
    read -p "Nilai baru (1-100, 0 = batal): " n
    [ "$n" == "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt 100 ]; then
        echo -e "${RED}Gagal: harus angka 1-100!${NC}"
        return
    fi
    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^NATSSH_MAX_PER_IP=" "${DIR}/config/.env"; then
            sed -i "s/^NATSSH_MAX_PER_IP=.*/NATSSH_MAX_PER_IP=$n/" "${DIR}/config/.env"
        else
            echo "NATSSH_MAX_PER_IP=$n" >> "${DIR}/config/.env"
        fi
    else
        echo "NATSSH_MAX_PER_IP=$n" > "${DIR}/config/.env"
    fi
    muat_env
    echo -e "${YELLOW}Restart natssh-ws — koneksi aktif terputus 2-3 detik...${NC}"
    read -p "Yakin restart? Koneksi aktif akan terputus (y/N): " cfr3
    if [[ ! "$cfr3" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        return
    fi
    systemctl restart natssh-ws
    sleep 1
    systemctl is-active --quiet natssh-ws &&         echo -e "${GREEN}SUKSES! NATSSH_MAX_PER_IP kini $n koneksi/IP.${NC}" || \
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
                maxlog=$(grep "^MAX_LOGIN=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2)
                maxlog=${maxlog:-5}
                cat > /etc/issue.net <<BEOF
<br>
<center>
<p align="center">
<font color="cyan">╔═══════════════════════╗</font><br>
<font color="yellow"><b>⚡ PREMIUM VPN SERVICE ⚡</b></font><br>
<font color="cyan">╠═══════════════════════╣</font><br>
<font color="green">✅ KONEKSI BERHASIL</font><br>
<font color="orange">🌍 Server : Indonesia — Premium</font><br>
<font color="aqua">🚀 Speed : up 100 Mbps</font><br>
<font color="lime">📱 Maksimal $maxlog Perangkat/Akun</font><br>
<font color="orange">⚔ Auto-Kill AKTIF</font><br>
<font color="white">──────────────────</font><br>
<font color="red">⛔ Dilarang: Torrent · DDoS · Data Waster · Hack</font><br>
<font color="grey">🛡 Support : </font><font color="magenta"><a href="https://wa.me/6281223711096?text=Halo%2C%20saya%20ingin%20membeli%20layanan%20SSH%2FVPN.%20Bisa%20info%20paket%20dan%20harganya%3F" target="_blank" rel="noopener">+6281223711096</a></font><br>
<font color="cyan">╚═══════════════════════╝</font><br>
<font color="green"><b>═══ SELAMAT MENIKMATI ═══</b></font><br>
</p>
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

conf_ip() {
    while true; do
        local ip_private=""
        local ip_public=""

        # Ambil IP private (eth0 atau antarmuka utama)
        if command -v ip >/dev/null 2>&1; then
            ip_private=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            if [ -z "$ip_private" ]; then
                ip_private=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            fi
        fi

        # Ambil IP public (coba ifconfig.me, fallback ipify)
        ip_public=$(curl -s -m 5 ifconfig.me 2>/dev/null)
        [ -z "$ip_public" ] && ip_public=$(curl -s -m 5 api.ipify.org 2>/dev/null)
        [ -z "$ip_public" ] && ip_public="tidak diketahui"

        echo -e "${YELLOW}---- KONFIGURASI IP & HIDE IP ----${NC}"
        echo -e "IP Private : ${GREEN}${ip_private:-tidak diketahui}${NC}"
        echo -e "IP Publik  : ${GREEN}${ip_public}${NC}"
        if grep -q "^HIDE_IP=1" "${DIR}/config/.env" 2>/dev/null; then
            echo -e "Hide IP    : ${GREEN}ON (IP disembunyikan di kartu akun)${NC}"
        else
            echo -e "Hide IP    : ${RED}OFF (IP ditampilkan di kartu akun)${NC}"
        fi
        echo ""
        echo "1. Toggle Hide IP"
        echo -e "${RED}0. Kembali${NC}"
        read -p "Pilih (0-1): " p
        case $p in
            1) conf_ip_toggle ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
    done
}

conf_ip_toggle() {
    if grep -q "^HIDE_IP=1" "${DIR}/config/.env" 2>/dev/null; then
        new_val=0
        pesan="NONAKTIF"
    else
        new_val=1
        pesan="AKTIF"
    fi

    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^HIDE_IP=" "${DIR}/config/.env"; then
            sed -i "s|^HIDE_IP=[01]|HIDE_IP=$new_val|" "${DIR}/config/.env"
        else
            echo "HIDE_IP=$new_val" >> "${DIR}/config/.env"
        fi
    else
        echo "HIDE_IP=$new_val" > "${DIR}/config/.env"
    fi
    muat_env
    echo -e "${GREEN}SUKSES! Hide IP kini ${pesan}.${NC}"
    pause
}

conf_suspend_minutes() {
    local cur=${SUSPEND_MINUTES}
    cur=${cur:-15}
    echo -e "${YELLOW}---- DURASI SUSPEND (autokill) ----${NC}"
    echo -e "Durasi saat ini: ${GREEN}${cur} menit${NC}"
    read -p "Durasi baru (1-1440 menit, kosong=batal): " v
    [ -z "$v" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 1440 ]; then
        echo -e "${RED}Nilai tidak valid!${NC}"; return
    fi
    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^SUSPEND_MINUTES=" "${DIR}/config/.env"; then
            sed -i "s|^SUSPEND_MINUTES=.*|SUSPEND_MINUTES=$v|" "${DIR}/config/.env"
        else
            echo "SUSPEND_MINUTES=$v" >> "${DIR}/config/.env"
        fi
    else
        echo "SUSPEND_MINUTES=$v" > "${DIR}/config/.env"
    fi
    muat_env
    echo -e "${GREEN}Durasi suspend diubah menjadi ${v} menit.${NC}"
}

conf_reboot_schedule() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   ATUR JADWAL REBOOT${NC}"
        garis
        echo "Jadwal reboot saat ini (cron):"
        crontab -l 2>/dev/null | grep "reboot" || echo "  (tidak ada jadwal reboot)"
        garis
        printf "  %-3s %-46s\\n" "1." "Setiap hari 03:00"
        printf "  %-3s %-46s\\n" "2." "Setiap hari 04:00"
        printf "  %-3s %-46s\\n" "3." "Setiap 12 jam"
        printf "  %-3s %-46s\\n" "4." "Custom cron"
        printf "  %-3s %-46s\\n" "5." "Hapus jadwal reboot"
        echo -e "${RED}  0.  Kembali${NC}"
        read -p "Pilih (0-5): " p || return
        case $p in
            1)
                read -p "Lanjut? (y/N): " y
                [[ "$y" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                crontab -l 2>/dev/null | grep -v "reboot" | crontab -
                (crontab -l 2>/dev/null; echo "0 3 * * * /usr/sbin/reboot") | crontab -
                echo -e "${GREEN}Jadwal reboot: setiap hari 03:00${NC}"
                pause
                ;;
            2)
                read -p "Lanjut? (y/N): " y
                [[ "$y" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                crontab -l 2>/dev/null | grep -v "reboot" | crontab -
                (crontab -l 2>/dev/null; echo "0 4 * * * /usr/sbin/reboot") | crontab -
                echo -e "${GREEN}Jadwal reboot: setiap hari 04:00${NC}"
                pause
                ;;
            3)
                read -p "Lanjut? (y/N): " y
                [[ "$y" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                crontab -l 2>/dev/null | grep -v "reboot" | crontab -
                (crontab -l 2>/dev/null; echo "0 */12 * * * /usr/sbin/reboot") | crontab -
                echo -e "${GREEN}Jadwal reboot: setiap 12 jam${NC}"
                pause
                ;;
            4)
                read -p "Masukkan cron expression (contoh: 0 2 * * *): " cexp
                [ -z "$cexp" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; continue; }
                crontab -l 2>/dev/null | grep -v "reboot" | crontab -
                (crontab -l 2>/dev/null; echo "$cexp /usr/sbin/reboot") | crontab -
                echo -e "${GREEN}Jadwal reboot diatur: $cexp${NC}"
                pause
                ;;
            5)
                crontab -l 2>/dev/null | grep -v "reboot" | crontab -
                echo -e "${GREEN}Jadwal reboot dihapus.${NC}"
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; pause ;;
        esac
    done
}

conf_test_ping() {
    clear
    garis
    echo -e "${YELLOW}   DIAGNOSA KONEKSI JARINGAN${NC}"
    garis

    # ── 1. ICMP Ping ──
    echo -e "${CYAN}--- PING (ICMP) ---${NC}"
    for host in 1.1.1.1 8.8.8.8 10.20.0.1; do
        if ping -c 2 -W 3 "$host" >/dev/null 2>&1; then
            echo -e "Ping $host : ${GREEN}OK${NC}"
        else
            echo -e "Ping $host : ${RED}timeout${NC}"
        fi
    done
    echo ""

    # ── 2. DNS Resolution ──
    echo -e "${CYAN}--- DNS RESOLUTION ---${NC}"
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup google.com >/dev/null 2>&1; then
            echo -e "DNS google.com   : ${GREEN}OK${NC}"
        else
            echo -e "DNS google.com   : ${RED}gagal${NC}"
        fi
    elif command -v dig >/dev/null 2>&1; then
        if dig +short google.com >/dev/null 2>&1; then
            echo -e "DNS google.com   : ${GREEN}OK${NC}"
        else
            echo -e "DNS google.com   : ${RED}gagal${NC}"
        fi
    else
        echo -e "DNS              : ${YELLOW}tidak ada nslookup/dig${NC}"
    fi
    echo ""

    # ── 3. TCP Port Check ──
    echo -e "${CYAN}--- TCP PORT CHECK ---${NC}"
    declare -a ports=(443 80)
    for port in "${ports[@]}"; do
        if command -v nc >/dev/null 2>&1; then
            if nc -zv -w 3 1.1.1.1 "$port" >/dev/null 2>&1; then
                echo -e "Port $port (1.1.1.1) : ${GREEN}OK${NC}"
            else
                echo -e "Port $port (1.1.1.1) : ${RED}timeout${NC}"
            fi
        else
            echo -e "Port $port        : ${YELLOW}nc tidak terpasang${NC}"
            break
        fi
    done
    echo ""

    # ── 4. HTTP/HTTPS ──
    echo -e "${CYAN}--- HTTP/HTTPS ---${NC}"
    if curl -s -o /dev/null --connect-timeout 5 --max-time 10 https://1.1.1.1 >/dev/null 2>&1; then
        echo -e "HTTPS 1.1.1.1      : ${GREEN}OK${NC}"
    else
        echo -e "HTTPS 1.1.1.1      : ${RED}gagal${NC}"
    fi
    if curl -s -o /dev/null --connect-timeout 5 --max-time 10 http://1.1.1.1 >/dev/null 2>&1; then
        echo -e "HTTP 1.1.1.1       : ${GREEN}OK${NC}"
    else
        echo -e "HTTP 1.1.1.1       : ${RED}gagal${NC}"
    fi
    echo ""

    # ── 5. Traceroute (optional, singkat) ──
    echo -e "${CYAN}--- TRACEROUTE (1.1.1.1) ---${NC}"
    if command -v traceroute >/dev/null 2>&1; then
        traceroute -m 8 -w 2 -q 1 1.1.1.1 2>/dev/null | head -12 || echo -e "${RED}traceroute gagal${NC}"
    elif command -v tracepath >/dev/null 2>&1; then
        tracepath -m 8 1.1.1.1 2>/dev/null | head -12 || echo -e "${RED}tracepath gagal${NC}"
    else
        echo -e "${YELLOW}traceroute/tracepath tidak terpasang${NC}"
    fi
    echo ""

    garis
    echo -e "${YELLOW}Catatan:${NC}"
    echo -e "  - Gateway 10.20.0.1 mungkin tidak merespons ICMP (blokir), tapi HTTP/TCP tetap bisa."
    echo -e "  - Jangan diagnosa masalah koneksi jika hanya ICMP yang timeout."
    echo -e "  - Port 443/80 = HTTPS/HTTP publik."
}


conf_keepalive() {
    clear; garis
    echo -e "${YELLOW}   TOGGLE KEEPALIVE SSH${NC}"; garis
    if grep -qE "^[[:space:]]*ClientAliveInterval" /etc/ssh/sshd_config; then echo -e "Status: ${GREEN}AKTIF${NC}"; else echo -e "Status: ${RED}NONAKTIF${NC}"; fi
    echo "1. Aktifkan"; echo "2. Nonaktifkan"; echo -e "${RED}0. Kembali${NC}"
    read -p "Pilih (0-2): " k || return
    case $k in
        1)
            grep -qE "^[#[:space:]]*ClientAliveInterval" /etc/ssh/sshd_config && sed -i 's/^[#[:space:]]*ClientAliveInterval.*/ClientAliveInterval 30/' /etc/ssh/sshd_config || echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
            grep -qE "^[#[:space:]]*ClientAliveCountMax" /etc/ssh/sshd_config && sed -i 's/^[#[:space:]]*ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config || echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            echo -e "${GREEN}Keepalive SSH AKTIF.${NC}" ;;
        2)
            sed -i "/^[#[:space:]]*ClientAliveInterval/d" /etc/ssh/sshd_config
            sed -i "/^[#[:space:]]*ClientAliveCountMax/d" /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            echo -e "${YELLOW}Keepalive SSH NONAKTIF.${NC}" ;;
        0) return ;;
        *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
    esac
    pause
}

conf_heartbeat() {
    clear; garis
    echo -e "${YELLOW}   TOGGLE HEARTBEAT WS (TCP keepalive)${NC}"; garis
    if [ "${NATSSH_TCP_HEARTBEAT}" = "0" ]; then echo -e "Status: ${RED}NONAKTIF${NC}"; else echo -e "Status: ${GREEN}AKTIF (default)${NC}"; fi
    echo "1. Aktifkan"; echo "2. Nonaktifkan"; echo -e "${RED}0. Kembali${NC}"
    read -p "Pilih (0-2): " k || return
    case $k in
        1)
            if [ -f "${DIR}/config/.env" ]; then
                if grep -q "^NATSSH_TCP_HEARTBEAT=" "${DIR}/config/.env"; then
                    sed -i 's/^NATSSH_TCP_HEARTBEAT=.*/NATSSH_TCP_HEARTBEAT=1/' "${DIR}/config/.env"
                else
                    echo "NATSSH_TCP_HEARTBEAT=1" >> "${DIR}/config/.env"
                fi
            else
                echo "NATSSH_TCP_HEARTBEAT=1" > "${DIR}/config/.env"
            fi
            muat_env
            systemctl daemon-reload
            systemctl restart natssh-ws.service
            echo -e "${GREEN}Heartbeat WS AKTIF.${NC}" ;;
        2)
            if [ -f "${DIR}/config/.env" ]; then
                if grep -q "^NATSSH_TCP_HEARTBEAT=" "${DIR}/config/.env"; then
                    sed -i 's/^NATSSH_TCP_HEARTBEAT=.*/NATSSH_TCP_HEARTBEAT=0/' "${DIR}/config/.env"
                else
                    echo "NATSSH_TCP_HEARTBEAT=0" >> "${DIR}/config/.env"
                fi
            else
                echo "NATSSH_TCP_HEARTBEAT=0" > "${DIR}/config/.env"
            fi
            muat_env
            systemctl daemon-reload
            systemctl restart natssh-ws.service
            echo -e "${YELLOW}Heartbeat WS NONAKTIF.${NC}" ;;
        0) return ;;
        *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
    esac
    pause
}

conf_nginx_port() {
    conf_file="/etc/nginx/sites-available/natssh-ws"
    if [ -f "${DIR}/config/.env" ] && grep -q "^NGINX_REVERSE_PORT=" "${DIR}/config/.env"; then
        cur=$(grep "^NGINX_REVERSE_PORT=" "${DIR}/config/.env" | cut -d= -f2)
    elif [ -f "$conf_file" ]; then
        cur=$(grep -E 'listen .*ssl' "$conf_file" | head -1 | grep -oE '[0-9]+' | head -1)
    else
        cur=""
    fi
    echo -e "Port nginx saat ini: ${YELLOW}${cur:-tidak diketahui}${NC}"
    echo -e "${YELLOW}Ketik 0 atau kosong untuk batal.${NC}"
    read -p "Port nginx baru: " new_port
    if [ -z "$new_port" ] || [ "$new_port" = "0" ]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}Gagal: port harus angka 1-65535!${NC}"
        pause
        return
    fi
    if ss -tln | grep -q ":$new_port "; then
        echo -e "${RED}Gagal: port $new_port sedang dipakai proses lain!${NC}"
        pause
        return
    fi
    echo -e "${YELLOW}Restart nginx — koneksi aktif terputus 2-3 detik...${NC}"
    read -p "Yakin restart nginx? Koneksi aktif akan terputus (y/N): " cfr
    if [[ ! "$cfr" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi
    sed -i "s/listen [0-9]* ssl;/listen $new_port ssl;/" "$conf_file"
    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^NGINX_REVERSE_PORT=" "${DIR}/config/.env"; then
            sed -i "s/^NGINX_REVERSE_PORT=.*/NGINX_REVERSE_PORT=$new_port/" "${DIR}/config/.env"
        else
            echo "NGINX_REVERSE_PORT=$new_port" >> "${DIR}/config/.env"
        fi
    else
        echo "NGINX_REVERSE_PORT=$new_port" > "${DIR}/config/.env"
    fi
    muat_env
    systemctl restart nginx
    sleep 1
    systemctl is-active --quiet nginx && \
        echo -e "${GREEN}SUKSES! Nginx kini listen di port $new_port.${NC}" || \
        echo -e "${RED}Service gagal start! Cek: journalctl -u nginx -n 20${NC}"
    pause
}

port_direct() {
    # Port SSH Direct (raw TCP listener di ws.py) — baca dari config/.env
    if [ -f "${DIR}/config/.env" ]; then
        grep "^NATSSH_SSH_DIRECT_PORT=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2
    fi
}

port_nginx_stream() {
    # Port Nginx Stream (TCP listener untuk SSH direct) — baca dari config/.env
    if [ -f "${DIR}/config/.env" ]; then
        grep "^NGINX_STREAM_PORT=" "${DIR}/config/.env" 2>/dev/null | cut -d= -f2
    fi
}

conf_port_direct() {
    unit=/etc/systemd/system/natssh-ws.service
    if [ ! -f "$unit" ]; then
        echo -e "${RED}Gagal: $unit tidak ditemukan.${NC}"
        pause
        return
    fi
    cur_port=$(port_direct 2>/dev/null || echo "-")
    echo -e "Port SSH Direct saat ini: ${YELLOW}${cur_port}${NC}"
    echo -e "${YELLOW}Ketik 0 atau kosong untuk batal.${NC}"
    read -p "Port SSH Direct baru: " new_port
    if [ -z "$new_port" ] || [ "$new_port" = "0" ]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}Gagal: port harus angka 1-65535!${NC}"
        pause
        return
    elif ss -tln | grep -q ":$new_port "; then
        echo -e "${RED}Gagal: port $new_port sedang dipakai proses lain!${NC}"
        pause
        return
    fi
    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^NATSSH_SSH_DIRECT_PORT=" "${DIR}/config/.env"; then
            sed -i "s/^NATSSH_SSH_DIRECT_PORT=.*/NATSSH_SSH_DIRECT_PORT=$new_port/" "${DIR}/config/.env"
        else
            echo "NATSSH_SSH_DIRECT_PORT=$new_port" >> "${DIR}/config/.env"
        fi
    else
        echo "NATSSH_SSH_DIRECT_PORT=$new_port" > "${DIR}/config/.env"
    fi
    muat_env
    echo -e "${YELLOW}Restart natssh-ws — koneksi aktif terputus 2-3 detik...${NC}"
    read -p "Yakin restart? Koneksi aktif akan terputus (y/N): " cfr
    if [[ ! "$cfr" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi
    systemctl restart natssh-ws
    sleep 1
    if systemctl is-active --quiet natssh-ws; then
        echo -e "${GREEN}SUKSES! SSH Direct kini di port $new_port.${NC}"
        # Update nginx stream proxy_pass ke port direct baru
        stconf="/etc/nginx/stream.conf"
        if [ -f "$stconf" ]; then
            sed -i "s|proxy_pass 127.0.0.1:[0-9]*;|proxy_pass 127.0.0.1:$new_port;|" "$stconf"
            if nginx -t >/dev/null 2>&1 && systemctl restart nginx; then
                echo -e "${GREEN}Nginx Stream diupdate forward ke port $new_port.${NC}"
            else
                echo -e "${RED}Nginx gagal restart! Cek: journalctl -u nginx -n 20${NC}"
            fi
        fi
    else
        echo -e "${RED}Service gagal start! Cek: journalctl -u natssh-ws -n 20${NC}"
    fi
    pause
}

conf_toggle_ssh_direct() {
    unit=/etc/systemd/system/natssh-ws.service
    if [ ! -f "$unit" ]; then
        echo -e "${RED}Gagal: $unit tidak ditemukan.${NC}"
        pause
        return
    fi
    if grep -q "^NATSSH_SSH_DIRECT_ENABLED=1" "${DIR}/config/.env" 2>/dev/null; then
        new_val=0
        pesan="NONAKTIF"
    else
        new_val=1
        pesan="AKTIF"
    fi
    echo -e "SSH Direct saat ini: $([ "$new_val" = "1" ] && echo -e "${RED}NONAKTIF${NC}" || echo -e "${GREEN}AKTIF${NC}")"
    echo -e "${YELLOW}Akan diubah menjadi: ${GREEN}${pesan}${NC}"
    echo -e "${RED}PERINGATAN: Semua koneksi aktif akan terputus!${NC}"
    read -p "Yakin toggle SSH Direct? Koneksi aktif akan terputus (y/N): " cfr
    if [[ ! "$cfr" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi
    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^NATSSH_SSH_DIRECT_ENABLED=" "${DIR}/config/.env"; then
            sed -i "s/^NATSSH_SSH_DIRECT_ENABLED=[01]/NATSSH_SSH_DIRECT_ENABLED=$new_val/" "${DIR}/config/.env"
        else
            echo "NATSSH_SSH_DIRECT_ENABLED=$new_val" >> "${DIR}/config/.env"
        fi
    else
        echo "NATSSH_SSH_DIRECT_ENABLED=$new_val" > "${DIR}/config/.env"
    fi
    muat_env
    echo -e "${YELLOW}Restart natssh-ws — koneksi aktif terputus 2-3 detik...${NC}"
    systemctl restart natssh-ws
    sleep 1
    if systemctl is-active --quiet natssh-ws; then
        echo -e "${GREEN}SUKSES! SSH Direct kini ${pesan}.${NC}"
    else
        echo -e "${RED}Service gagal start! Cek: journalctl -u natssh-ws -n 20${NC}"
    fi
    pause
}

conf_nginx_stream_port() {
    conf_file="/etc/nginx/stream.conf"
    if [ -f "${DIR}/config/.env" ] && grep -q "^NGINX_STREAM_PORT=" "${DIR}/config/.env"; then
        cur=$(grep "^NGINX_STREAM_PORT=" "${DIR}/config/.env" | cut -d= -f2)
    elif [ -f "$conf_file" ]; then
        cur=$(grep -E 'listen [0-9]+' "$conf_file" | head -1 | grep -oE '[0-9]+' | head -1)
    else
        cur=""
    fi
    echo -e "Port Nginx Stream saat ini: ${YELLOW}${cur:-tidak diketahui}${NC}"
    echo -e "${YELLOW}Ketik 0 atau kosong untuk batal.${NC}"
    read -p "Port Nginx Stream baru: " new_port
    if [ -z "$new_port" ] || [ "$new_port" = "0" ]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}Gagal: port harus angka 1-65535!${NC}"
        pause
        return
    fi
    if ss -tln | grep -q ":$new_port "; then
        echo -e "${RED}Gagal: port $new_port sedang dipakai proses lain!${NC}"
        pause
        return
    fi
    echo -e "${YELLOW}Restart nginx — koneksi aktif terputus 2-3 detik...${NC}"
    read -p "Yakin restart nginx? Koneksi aktif akan terputus (y/N): " cfr
    if [[ ! "$cfr" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        pause
        return
    fi
    sed -i "s/listen [0-9]*;/listen $new_port;/" "$conf_file"
    if [ -f "${DIR}/config/.env" ]; then
        if grep -q "^NGINX_STREAM_PORT=" "${DIR}/config/.env"; then
            sed -i "s/^NGINX_STREAM_PORT=.*/NGINX_STREAM_PORT=$new_port/" "${DIR}/config/.env"
        else
            echo "NGINX_STREAM_PORT=$new_port" >> "${DIR}/config/.env"
        fi
    else
        echo "NGINX_STREAM_PORT=$new_port" > "${DIR}/config/.env"
    fi
    muat_env
    systemctl restart nginx
    sleep 1
    systemctl is-active --quiet nginx && \
        echo -e "${GREEN}SUKSES! Nginx Stream kini listen di port $new_port.${NC}" || \
        echo -e "${RED}Service gagal start! Cek: journalctl -u nginx -n 20${NC}"
    pause
}


menu_conf() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   KONFIGURASI SISTEM${NC}"
        garis
        echo -e "${CYAN}  -- Domain/IP --${NC}"
        printf "  %-3s %-46s\n" "1." "Domain/Host"
        printf "  %-3s %-46s\n" "2." "IP Address"
        echo -e "${CYAN}  -- Layanan --${NC}"
        printf "  %-3s %-46s\n" "3." "Kontrol SSH WS"
        printf "  %-3s %-46s\n" "4." "Kontrol SSH Direct"
        printf "  %-3s %-46s\n" "5." "Kontrol UDPGW"
        printf "  %-3s %-46s\n" "6." "Kontrol Nginx"
        echo -e "${CYAN}  -- Batas --${NC}"
        printf "  %-3s %-46s\n" "7." "Login per Akun"
        printf "  %-3s %-46s\n" "8." "Koneksi Serentak"
        printf "  %-3s %-46s\n" "9." "Koneksi per IP"
        printf "  %-3s %-46s\n" "10." "Limit Speed"
        echo -e "${CYAN}  -- Lainnya --${NC}"
        printf "  %-3s %-46s\n" "11." "Penjadwalan"
        printf "  %-3s %-46s\n" "12." "Banner Pelanggan"
        printf "  %-3s %-46s\n" "13." "Durasi Suspend"
        printf "  %-3s %-46s\n" "14." "Test Ping"
        read -p "Pilih (0-14): " p || exit 0
        case $p in
            1) conf_domain ;;
            2) conf_ip ;;
            3) conf_service ;;
            4) conf_service_direct ;;
            5) conf_udpgw_service ;;
            6) conf_nginx_service ;;
            7) conf_maxlogin ;;
            8) conf_maxtotal ;;
            9) conf_maxperip ;;
            10) conf_speed ;;
            11) conf_restart_schedule ;;
            12) conf_banner ;;
            13) conf_suspend_minutes ;;
            14) conf_test_ping ;;
            0) return ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
        esac
        [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$p" != "2" ] && [ "$p" != "3" ] && [ "$p" != "4" ] && [ "$p" != "5" ] && [ "$p" != "6" ] && [ "$p" != "7" ] && [ "$p" != "8" ] && [ "$p" != "9" ] && [ "$p" != "10" ] && [ "$p" != "11" ] && [ "$p" != "12" ] && pause
    done
}

#!/bin/bash
# NATSSH Menu v4.0 — utama 4 kategori + submenu
# Konvensi: akun jualan = shell /bin/false; 1 sesi tunnel = 2 proses sshd (hitungan /2)

# ══════════ KONFIGURASI WAKTU ══════════
# Semua tampilan waktu ke user pakai WIB (GMT+7)
export TZ=Asia/Jakarta

RED='\u001b[0;31m'
GREEN='\u001b[0;32m'
YELLOW='\u001b[0;33m'
CYAN='\u001b[0;36m'
NC='\u001b[0m'

# Direktori natssh (portabel jika dipindah)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Muat konfigurasi terpusat dari config/.env (jika ada)
if [ -f "${DIR}/config/.env" ]; then
    set -a
    . "${DIR}/config/.env"
    set +a
fi


garis() { echo -e "${GREEN}======================================${NC}"; }
pause()  { echo ""; read -r -p "Tekan Enter untuk kembali..." _ || true; }
# catatan: JANGAN read -n 1 — sisakan newline di buffer, read berikutnya can baris kosong = "batal" palsu

# ══════════ AKUN ══════════













# ══════════ MONITORING ══════════







# ══════════ BACKUP ══════════

# Direktori backup terpusat
BACKUP_DIR="/root/natssh_backup"


conf_domain_cf_edit() {
    # domain CloudFront (jalur AWS) utk kartu akun; DOMAIN_CF di .env — opsional
    local cur=${DOMAIN_CF}
    echo -e "Domain CloudFront saat ini: ${YELLOW}${cur:-BELUM DIATUR (baris tak tampil di kartu)}${NC}"
    read -p "Domain CloudFront baru (kosong = hapus/sembunyikan, 0 = batal): " h
    [ "$h" = "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if [ -z "$h" ]; then
        if [ -f "${DIR}/config/.env" ]; then
            if grep -q "^DOMAIN_CF=" "${DIR}/config/.env"; then
                sed -i "/^DOMAIN_CF=/d" "${DIR}/config/.env"
            fi
        fi
        muat_env
        echo -e "${GREEN}Domain CloudFront dihapus — baris 'Domain CF' tak tampil di kartu.${NC}"
    elif ! [[ "$h" =~ ^[a-zA-Z0-9.-]{3,100}(:[0-9]+)?$ ]]; then
        echo -e "${RED}Gagal: format domain salah (contoh: dabcdefgh.cloudfront.net)!${NC}"
    else
        if [ -f "${DIR}/config/.env" ]; then
            if grep -q "^DOMAIN_CF=" "${DIR}/config/.env"; then
                sed -i "s|^DOMAIN_CF=.*|DOMAIN_CF=$h|" "${DIR}/config/.env"
            else
                echo "DOMAIN_CF=$h" >> "${DIR}/config/.env"
            fi
        else
            echo "DOMAIN_CF=$h" > "${DIR}/config/.env"
        fi
        muat_env
        echo -e "${GREEN}Domain CloudFront tersimpan: $h — muncul di baris 'Domain CF' kartu akun.${NC}"
    fi
}


# Ekstraksi root domain menggunakan Public Suffix List (unduh dari publicsuffix.org)
extract_root_domain() {
    local domain="$1"
    local psl_file="$2"
    local parts count best_len line trimmed
    local best_suffix="" best_len=0

    # Hitung jumlah label domain (titik + 1)
    local ddots="${domain//[^.]/}"
    parts=${#ddots}
    parts=$((parts + 1))

    local line_count=0
    while IFS= read -r line; do
        line_count=$((line_count + 1))
        # Progress tiap 2000 baris
        if [ $((line_count % 2000)) -eq 0 ]; then
            echo -e "${YELLOW}   ... memproses baris ke-$line_count${NC}" >&2
        fi

        # Trim whitespace (bash only, tidak pakai sed)
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        line="$trimmed"

        [[ -z "$line" || "$line" == \/\/ ]] && continue

        # Hilangkan leading *. dari wildcard rules
        if [[ "$line" == \*.* ]]; then
            line="${line#*.}"
        fi

        # Lewati exceptions (!rule)
        [[ "$line" == !* ]] && continue
        [[ -z "$line" ]] && continue

        # Hitung jumlah label suffix (titik + 1)
        local sdots="${line//[^.]/}"
        count=${#sdots}
        count=$((count + 1))

        # Cek apakah domain cocok dengan suffix (sama atau diakhiri dengan .suffix)
        if [[ "$domain" == "$line" || "$domain" == *".$line" ]]; then
            if [ "$count" -gt "$best_len" ] && [ "$parts" -gt "$count" ]; then
                best_suffix="$line"
                best_len="$count"
            fi
        fi
    done < "$psl_file"

    echo -e "${GREEN}   Selesai memproses $line_count baris PSL${NC}" >&2

    if [ -n "$best_suffix" ]; then
        # Ekstrak root domain: hilangkan label di depan sampai tersisa best_len label
        local start=$((parts - best_len))
        local remaining="$domain"
        local idx=1
        while [ $idx -lt $start ]; do
            remaining="${remaining#*.}"
            idx=$((idx + 1))
        done
        echo "$remaining"
        return 0
    fi
    return 1
}

# Pemeriksaan acme.sh (pasang otomatis jika belum ada)
cek_acme_sh() {
    echo -e "\n[*] Memeriksa acme.sh..."
    if [ -x "$HOME/.acme.sh/acme.sh" ]; then
        acme_version=$("$HOME/.acme.sh/acme.sh" --version 2>/dev/null | head -1)
        echo -e "${GREEN}acme.sh sudah terinstal: ${acme_version:-versi tidak terbaca}, lewati instalasi.${NC}"
    else
        echo -e "${YELLOW}acme.sh belum terpasang. Memasang acme.sh...${NC}"
        curl https://get.acme.sh | sh -s email=admin@example.com
    fi

    if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
        echo -e "${RED}acme.sh tidak dapat dieksekusi. Terbit ulang sertifikat dibatalkan.${NC}"
        return 1
    fi
    acme_version=$("$HOME/.acme.sh/acme.sh" --version 2>/dev/null | head -1)
    if [ -z "$acme_version" ]; then
        echo -e "${RED}Gagal menjalankan acme.sh. Periksa koneksi internet.${NC}"
        return 1
    fi
    echo -e "${GREEN}acme.sh siap: $acme_version${NC}"
    return 0
}

# Muat variabel dari config/.env (jika ada)
muat_env() {
    if [ -f "${DIR}/config/.env" ]; then
        set -a
        . "${DIR}/config/.env"
        set +a
        echo -e "${GREEN}Variabel .env dimuat.${NC}"
    fi
}

# Terbitkan ulang sertifikat SSL via acme.sh (Cloudflare DNS challenge)
terbitkan_ulang_sertifikat() {
    local ssl_domain root_domain
    ssl_domain=${DOMAIN}
    if [ -z "$ssl_domain" ]; then
        echo -e "${RED}Domain/Host kosong di .env! Tidak dapat menerbitkan sertifikat.${NC}"
        return 1
    fi

    echo -e "\n[*] Mengecek Public Suffix List..."
    PSL_FILE="${DIR}/config/public_suffix_list.dat"
    root_domain=""
    if [ -s "$PSL_FILE" ]; then
        echo -e "${GREEN}PSL sudah tersedia di $PSL_FILE, lewati unduhan.${NC}"
    else
        echo -e "[*] Mengunduh Public Suffix List..."
        if wget -q "https://publicsuffix.org/list/public_suffix_list.dat" -O "$PSL_FILE" 2>/dev/null; then
            echo -e "${GREEN}PSL tersimpan di $PSL_FILE.${NC}"
        else
            echo -e "${YELLOW}Gagal unduh Public Suffix List, pakai fallback .env${NC}"
        fi
    fi

    if [ -s "$PSL_FILE" ]; then
        root_domain=$(extract_root_domain "$ssl_domain" "$PSL_FILE")
        if [ -z "$root_domain" ]; then
            echo -e "${YELLOW}Public Suffix List tidak dapat menentukan root domain, pakai fallback .env${NC}"
            root_domain="$ssl_domain"
        fi
    fi

    if [ -z "$root_domain" ]; then
        echo -e "${YELLOW}PSL tidak tersedia, pakai fallback .env${NC}"
        root_domain="$ssl_domain"
    fi

    # Validasi suffix
    if [ "$root_domain" = "$ssl_domain" ]; then
        echo -e "${YELLOW}Peringatan: Suffix domain '${ssl_domain}' tidak ditemukan dalam Public Suffix List.${NC}"
        echo -e "${YELLOW}Sertifikat SSL mungkin tidak valid untuk domain dengan suffix tidak dikenal.${NC}"
        read -p "Lanjutkan terbitkan sertifikat untuk ${root_domain}? (y/N): " confirm_suffix
        if [[ ! "$confirm_suffix" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Terbit ulang sertifikat dibatalkan.${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}Root domain untuk sertifikat: ${root_domain}${NC}"

    # Pemeriksaan acme.sh
    if ! cek_acme_sh; then
        return 1
    fi

    # Muat .env
    muat_env

    # Cek kredensial Cloudflare
    if [ -z "${CF_Token}" ] && [ -z "${CF_Key}" ]; then
        echo -e "${YELLOW}Pilih jenis kredensial Cloudflare:${NC}"
        echo -e "  1) API Token"
        echo -e "  2) API Key + Email"
        read -p "Pilihan (1-2, 0 = batal): " cf_pilih
        case "$cf_pilih" in
            1)
                read -p "Masukkan Cloudflare API Token: " CF_Token
                CF_Token="${CF_Token}"
                ;;
            2)
                read -p "Masukkan Cloudflare API Key: " CF_Key
                read -p "Masukkan Cloudflare Account Email: " CF_Email
                CF_Key="${CF_Key}"
                CF_Email="${CF_Email}"
                ;;
            0|"")
                echo -e "${RED}Dibatalkan.${NC}"; return 1
                ;;
            *)
                echo -e "${RED}Pilihan tidak valid.${NC}"; return 1
                ;;
        esac
    fi

    # Simpan kredensial ke config/.env
    if [ -n "${CF_Token}" ]; then
        if [ -f "${DIR}/config/.env" ]; then
            if grep -q "^CF_Token=" "${DIR}/config/.env"; then
                sed -i "s|^CF_Token=.*|CF_Token=${CF_Token}|" "${DIR}/config/.env"
            else
                echo "CF_Token=${CF_Token}" >> "${DIR}/config/.env"
            fi
        else
            echo "CF_Token=${CF_Token}" > "${DIR}/config/.env"
        fi
        echo -e "${GREEN}Cloudflare API Token disimpan ke config/.env${NC}"
    fi

    if [ -n "${CF_Key}" ]; then
        if [ -f "${DIR}/config/.env" ]; then
            if grep -q "^CF_Key=" "${DIR}/config/.env"; then
                sed -i "s|^CF_Key=.*|CF_Key=${CF_Key}|" "${DIR}/config/.env"
            else
                echo "CF_Key=${CF_Key}" >> "${DIR}/config/.env"
            fi
        else
            echo "CF_Key=${CF_Key}" > "${DIR}/config/.env"
        fi
        if [ -n "${CF_Email}" ]; then
            if [ -f "${DIR}/config/.env" ]; then
                if grep -q "^CF_Email=" "${DIR}/config/.env"; then
                    sed -i "s|^CF_Email=.*|CF_Email=${CF_Email}|" "${DIR}/config/.env"
                else
                    echo "CF_Email=${CF_Email}" >> "${DIR}/config/.env"
                fi
            else
                echo "CF_Email=${CF_Email}" > "${DIR}/config/.env"
            fi
            echo -e "${GREEN}Cloudflare API Key + Email disimpan ke config/.env${NC}"
        fi
    fi
    muat_env

    if [ -z "$CF_Token" ] && [ -z "${CF_Key}" ]; then
        echo -e "${RED}Kredensial Cloudflare tidak diisi. Terbit ulang sertifikat dibatalkan.${NC}"
        return 1
    fi

    echo -e "\n[*] Memeriksa perintah idn (untuk domain internasional)..."
    if ! command -v idn >/dev/null 2>&1; then
        echo -e "${YELLOW}idn belum terpasang. Memasang...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y idn
        elif command -v apk >/dev/null 2>&1; then
            apk add idn
        else
            echo -e "${RED}Gagal memasang idn (paket manager tidak didukung).${NC}"
        fi
    fi
    if ! command -v idn >/dev/null 2>&1; then
        echo -e "${RED}idn tidak tersedia, sertifikat untuk domain IDN mungkin gagal.${NC}"
    else
        echo -e "${GREEN}idn siap.${NC}"
    fi

    echo -e "\n[*] Menerbitkan sertifikat SSL via acme.sh (Cloudflare DNS challenge)..."
    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "*.${root_domain}" -d "${root_domain}" \
        --cert-file /etc/nginx/ssl/natssh.pem \
        --key-file /etc/nginx/ssl/natssh_key.pem \
        --fullchain-file /etc/nginx/ssl/natssh_fullchain.pem \
        --reloadcmd "systemctl reload nginx" || {
        echo -e "${RED}Gagal menerbitkan sertifikat SSL. Sertifikat lama tetap dipakai.${NC}"
        return 1
    }

    echo -e "${GREEN}Sertifikat SSL berhasil diperbarui untuk ${root_domain}.${NC}"
    echo -e "${GREEN}Nginx akan di-reload otomatis oleh acme.sh reloadcmd.${NC}"
    return 0
}

conf_domain() {
    # satu pintu domain: Cloudflare (biasa) + CloudFront — dua-duanya ke kartu akun
    while true; do
        local cur curcf
        cur=${DOMAIN}
        curcf=${DOMAIN_CF}
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
        [ "$p" != "0" ] && pause
    done
}

conf_domain_edit() {
    # host/domain Cloudflare di kartu akun; DOMAIN di .env (fallback: IP publik)
    local cur=${DOMAIN}
    echo -e "Host kartu akun saat ini: ${YELLOW}${cur:-OTOMATIS (IP publik)}${NC}"
    read -p "Domain/host baru (kosong = otomatis IP, 0 = batal): " h
    [ "$h" = "0" ] && { echo -e "${YELLOW}Dibatalkan.${NC}"; return; }
    if [ -z "$h" ]; then
        if [ -f "${DIR}/config/.env" ]; then
            if grep -q "^DOMAIN=" "${DIR}/config/.env"; then
                sed -i "/^DOMAIN=/d" "${DIR}/config/.env"
            fi
        fi
        muat_env
        echo -e "${GREEN}Host kembali otomatis (IP publik terdeteksi saat buat akun).${NC}"
    elif ! [[ "$h" =~ ^[a-zA-Z0-9.-]{3,100}(:[0-9]+)?$ ]]; then
        echo -e "${RED}Gagal: format domain/host salah (contoh: vpn.example.com)!${NC}"
    else
        if [ -f "${DIR}/config/.env" ]; then
            if grep -q "^DOMAIN=" "${DIR}/config/.env"; then
                sed -i "s|^DOMAIN=.*|DOMAIN=$h|" "${DIR}/config/.env"
            else
                echo "DOMAIN=$h" >> "${DIR}/config/.env"
            fi
        else
            echo "DOMAIN=$h" > "${DIR}/config/.env"
        fi
        muat_env
        echo -e "${GREEN}Domain tersimpan: $h — dipakai otomatis di kartu akun berikutnya.${NC}"
        echo ""
        read -p "Terbitkan ulang sertifikat SSL untuk domain ini sekarang? (y/N): " terbit_ssl
        if [[ "$terbit_ssl" =~ ^[Yy]$ ]]; then
            terbitkan_ulang_sertifikat
        else
            echo -e "${YELLOW}Sertifikat tidak ditampilkan ulang. Jalankan kembali nanti lewat menu ini.${NC}"
        fi
    fi
}


























promo_menu() {
    while true; do
        clear
        garis
        echo -e "${YELLOW}   PROMOSI BANNER${NC}"
        garis
        # status ringkas
        _n_sched=0; _n_active=0
        if [ -f /root/natssh/config/promo/promo_schedule.conf ] && [ -s /root/natssh/config/promo/promo_schedule.conf ]; then
            while IFS='|' read -r _s _st _d _iv _en _jd; do
                [ -z "$_s" ] && continue
                _n_sched=$((_n_sched+1))
                [ "$_en" = "1" ] || continue
                _end=$((_st + _d*86400))
                _now=$(date +%s)
                [ "$_now" -ge "$_st" ] && [ "$_now" -le "$_end" ] && _n_active=$((_n_active+1))
            done < /root/natssh/config/promo/promo_schedule.conf
        fi
        echo -e "  Jadwal: ${CYAN}${_n_sched}${NC}  |  Aktif sekarang: ${GREEN}${_n_active}${NC}"
        garis
        printf "  %-3s %-46s\n" "1." "Buat/Edit Slot Promo"
        printf "  %-3s %-46s\n" "2." "Jadwalkan Promo"
        printf "  %-3s %-46s\n" "3." "Ubah Jadwal Promo"
        printf "  %-3s %-46s\n" "4." "Aktifkan/Nonaktifkan Jadwal"
        printf "  %-3s %-46s\n" "5." "Status Promo"
        printf "  %-3s %-46s\n" "6." "Hapus Jadwal Promo (restore banner)"
        echo -e "${RED}  0.  Kembali ke Menu Utama${NC}"
        read -p "Pilih (0-6): " p || exit 0
        case $p in
            1)
                mkdir -p /root/natssh/banners
                echo -e "${CYAN}--- SLOT PROMO ---${NC}"
                echo "Slot tersedia:"
                i=1; for f in /root/natssh/banners/*.txt; do [ -f "$f" ] || continue; echo "  $i. $(basename "$f" .txt)"; i=$((i+1)); done
                [ $i -eq 1 ] && echo "  (belum ada slot)"
                echo ""
                echo "1. Buat/Edit Slot"
                echo "2. Hapus Slot"
                echo -e "${RED}0. Kembali${NC}"
                read -p "Pilih (0-2): " sub
                [ "$sub" = "0" ] && continue
                case $sub in
                    1)
                        read -p "Nomor slot existing atau nama baru (0=batal): " slot
                        [ "$slot" = "0" ] && continue
                        if [[ "$slot" =~ ^[0-9]+$ ]]; then
                            slot=$(ls -1 /root/natssh/banners/*.txt 2>/dev/null | sed -n "${slot}p" | xargs -r basename 2>/dev/null | sed 's/\.txt$//')
                            [ -z "$slot" ] && { echo -e "${RED}Nomor tidak valid${NC}"; pause; continue; }
                        fi
                        [[ "$slot" =~ ^[a-zA-Z0-9_-]{1,24}$ ]] || { echo -e "${RED}Nama tidak valid${NC}"; pause; continue; }
                        if [ -f "/root/natssh/banners/${slot}.txt" ]; then
                            read -p "Slot '$slot' sudah ada — timpa? (y/N): " t
                            [[ "$t" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                        fi
                        ${EDITOR:-nano} "/root/natssh/banners/${slot}.txt"
                        ;;
                    2)
                        i=1; for f in /root/natssh/banners/*.txt; do [ -f "$f" ] || continue; echo "  $i. $(basename "$f" .txt)"; i=$((i+1)); done
                        [ $i -eq 1 ] && { echo -e "${YELLOW}Tidak ada slot untuk dihapus.${NC}"; pause; continue; }
                        read -p "Nomor slot hapus (0=batal): " deln
                        [ "$deln" = "0" ] && continue
                        delname=$(ls -1 /root/natssh/banners/*.txt 2>/dev/null | sed -n "${deln}p" | xargs -r basename 2>/dev/null | sed 's/\.txt$//')
                        [ -z "$delname" ] && { echo -e "${RED}Nomor tidak valid${NC}"; pause; continue; }
                        read -p "Yakin hapus slot '$delname'? (y/N): " y
                        if [[ "$y" =~ ^[Yy]$ ]]; then
                            rm -f "/root/natssh/banners/${delname}.txt"
                            echo -e "${GREEN}Slot '$delname' dihapus.${NC}"
                            # Hapus jadwal yang mereferensi slot ini
                            if [ -f /root/natssh/config/promo/promo_schedule.conf ] && grep -q "^${delname}|" /root/natssh/config/promo/promo_schedule.conf 2>/dev/null; then
                                tmp=$(mktemp)
                                grep -v "^${delname}|" /root/natssh/config/promo/promo_schedule.conf > "$tmp"
                                mv "$tmp" /root/natssh/config/promo/promo_schedule.conf
                                echo -e "${YELLOW}Jadwal slot '$delname' juga dihapus.${NC}"
                            fi
                        else
                            echo -e "${YELLOW}Dibatalkan.${NC}"
                        fi
                        ;;
                    *) echo -e "${RED}Pilihan tidak valid!${NC}" ;;
                esac
                ;;
            2)
                echo "Slot tersedia:"
                i=1; for f in /root/natssh/banners/*.txt; do [ -f "$f" ] || continue; echo "  $i. $(basename "$f" .txt)"; i=$((i+1)); done
                read -p "Nomor slot (0=batal): " slot
                [ "$slot" = "0" ] && continue
                if [[ "$slot" =~ ^[0-9]+$ ]]; then
                    slot=$(ls -1 /root/natssh/banners/*.txt 2>/dev/null | sed -n "${slot}p" | xargs -r basename 2>/dev/null | sed 's/\.txt$//')
                fi
                [ -f "/root/natssh/banners/${slot}.txt" ] || { echo -e "${RED}Slot tidak ada${NC}"; pause; continue; }
                read -p "Durasi promo (hari, 0=batal): " dh
                [ "$dh" = "0" ] && continue
                [ -z "$dh" ] && { echo -e "${RED}Durasi kosong (batal)${NC}"; pause; continue; }
                if ! [[ "$dh" =~ ^[0-9]+$ ]] || [ "$dh" -lt 1 ]; then
                    echo -e "${RED}Durasi harus angka >= 1!${NC}"; pause; continue
                fi
                read -p "Interval disconnect (menit, 0=batal): " iv
                [ "$iv" = "0" ] && continue
                [ -z "$iv" ] && { echo -e "${RED}Interval kosong (batal)${NC}"; pause; continue; }
                if ! [[ "$iv" =~ ^[0-9]+$ ]] || [ "$iv" -lt 1 ]; then
                    echo -e "${RED}Interval harus angka >= 1!${NC}"; pause; continue
                fi
                read -p "Jeda sesi (default 30s; suffix m=menit, s=detik; 0=tanpa jeda): " jd
                [ "$jd" = "0" ] && jd="0"
                [ -z "$jd" ] && jd="30"
                # parse suffix
                if [[ "$jd" =~ ^[0-9]+m$ ]]; then
                    jd_sec=$(( ${jd%m} * 60 ))
                elif [[ "$jd" =~ ^[0-9]+s$ ]]; then
                    jd_sec=${jd%s}
                elif [[ "$jd" =~ ^[0-9]+$ ]]; then
                    jd_sec=$jd
                else
                    echo -e "${RED}Format jeda tidak valid!${NC}"; pause; continue
                fi
                # list akun target
                mapfile -t ACCS < <(awk -F: '$7=="/bin/false"{print $1}' /etc/passwd | while read -r u; do [ -d "/home/$u" ] && echo "$u"; done)
                echo "Akun target tersedia:"
                for i in "${!ACCS[@]}"; do echo "  $((i+1)). ${ACCS[$i]}"; done
                read -p "Pilih nomor akun (pisah spasi, 0=batal): " tg
                [ "$tg" = "0" ] && continue
                [ -z "$tg" ] && { echo -e "${RED}Target kosong (batal)${NC}"; pause; continue; }
                selected=""
                for t in $tg; do
                    if [[ "$t" =~ ^[0-9]+$ ]]; then
                        idx=$((t-1))
                        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#ACCS[@]}" ]; then
                            selected="$selected ${ACCS[$idx]}"
                        else
                            echo -e "${RED}Nomor $t di luar daftar, dilewati.${NC}"
                        fi
                    else
                        if id "$t" &>/dev/null; then
                            selected="$selected $t"
                        else
                            echo -e "${RED}Username '$t' tidak ditemukan, dilewati.${NC}"
                        fi
                    fi
                done
                tg=$(echo "$selected" | xargs)
                [ -z "$tg" ] && { echo -e "${RED}Target tidak valid (batal)${NC}"; pause; continue; }
                s=$(date +%s)
                new_end=$((s + dh*86400))
                echo "${slot}|${s}|${dh}|${iv}|1|${jd_sec}|${tg}" >> /root/natssh/config/promo/promo_schedule.conf
                echo -e "${GREEN}Target: $tg${NC}"
                echo -e "${GREEN}Jeda sesi: ${jd_sec}s${NC}"
                # auto-enable cron promo_rotate jika belum ada
                if ! crontab -l 2>/dev/null | grep -q "promo_rotate.sh"; then
                    (crontab -l 2>/dev/null; echo "*/1 * * * * /root/natssh/promo_rotate.sh") | crontab -
                    echo -e "${GREEN}Cron promo_rotate diaktifkan.${NC}"
                fi
                echo -e "${GREEN}Jadwal disimpan.${NC}"
                ;;
            3)
                now=$(date +%s)
                echo -e "${YELLOW}=== JADWAL PROMO (pilih untuk ubah) ===${NC}"
                echo ""
                if [ -f /root/natssh/config/promo/promo_schedule.conf ] && [ -s /root/natssh/config/promo/promo_schedule.conf ]; then
                    i=1
                    while IFS='|' read -r slot start days interval enabled jeda targets; do
                        [ -z "$slot" ] && continue
                        jeda=${jeda:-0}
                        end=$((start + days*86400))
                        start_str=$(date -d "@$start" '+%d/%m %H:%M')
                        end_str=$(date -d "@$end" '+%d/%m %H:%M')
                        echo -e "  ${CYAN}$i.${NC} ${YELLOW}$slot${NC}  |  durasi: ${days}h  |  interval: ${interval}m  |  jeda: ${jeda}s  |  $start_str → $end_str"
                        i=$((i+1))
                    done < /root/natssh/config/promo/promo_schedule.conf
                else
                    echo -e "  ${YELLOW}Tidak ada jadwal yang tersimpan.${NC}"
                fi
                echo ""
                read -p "Nomor baris ubah (0=batal): " ln
                [ "$ln" = "0" ] && continue
                line=$(sed -n "${ln}p" /root/natssh/config/promo/promo_schedule.conf 2>/dev/null)
                [ -z "$line" ] && { echo -e "${RED}Baris tidak ada${NC}"; pause; continue; }
                IFS='|' read -r oldslot oldstart olddays oldiv olden oldjeda oldtargets <<< "$line"
                oldjeda=${oldjeda:-0}
                oldend=$((oldstart + olddays*86400))
                oldstart_str=$(date -d "@$oldstart" '+%d/%m/%Y %H:%M')
                oldend_str=$(date -d "@$oldend" '+%d/%m/%Y %H:%M')
                echo -e "${CYAN}--- Jadwal Lama ---${NC}"
                echo -e "  Slot     : ${YELLOW}$oldslot${NC}"
                echo -e "  Durasi   : ${olddays} hari"
                echo -e "  Interval : ${oldiv} menit"
                echo -e "  Periode  : $oldstart_str → $oldend_str"
                echo -e "  Status   : $([ "$olden" = "1" ] && echo "${GREEN}aktif${NC}" || echo "${RED}nonaktif${NC}")"
                echo -e "  Jeda sesi: ${oldjeda}s"
                echo -e "  Target   : ${YELLOW}${oldtargets:-—}${NC}"
                echo ""
                echo -e "${CYAN}--- Slot Tersedia ---${NC}"
                i=1; for f in /root/natssh/banners/*.txt; do [ -f "$f" ] || continue; echo -e "  ${CYAN}$i.${NC} $(basename "$f" .txt)"; i=$((i+1)); done
                echo ""
                read -p "Slot baru (Enter=tetap, 0=batal): " slot
                [ "$slot" = "0" ] && continue
                [ -z "$slot" ] && slot="$oldslot"
                if [[ "$slot" =~ ^[0-9]+$ ]]; then
                    slot=$(ls -1 /root/natssh/banners/*.txt 2>/dev/null | sed -n "${slot}p" | xargs -r basename 2>/dev/null | sed 's/\.txt$//')
                fi
                [ -f "/root/natssh/banners/${slot}.txt" ] || { echo -e "${RED}Slot tidak ada${NC}"; pause; continue; }
                read -p "Durasi baru (hari, Enter=tetap): " dh
                [ -z "$dh" ] && dh="$olddays"
                if ! [[ "$dh" =~ ^[0-9]+$ ]] || [ "$dh" -lt 1 ]; then
                    echo -e "${RED}Durasi harus angka >= 1!${NC}"; pause; continue
                fi
                read -p "Interval baru (menit, Enter=tetap): " iv
                [ -z "$iv" ] && iv="$oldiv"
                read -p "Jeda sesi baru (Enter=tetap, suffix m/s): " jd
                if [ -z "$jd" ]; then
                    jd_sec="$oldjeda"
                elif [ "$jd" = "0" ]; then
                    jd_sec="0"
                elif [[ "$jd" =~ ^[0-9]+m$ ]]; then
                    jd_sec=$(( ${jd%m} * 60 ))
                elif [[ "$jd" =~ ^[0-9]+s$ ]]; then
                    jd_sec=${jd%s}
                elif [[ "$jd" =~ ^[0-9]+$ ]]; then
                    jd_sec=$jd
                else
                    echo -e "${RED}Format jeda tidak valid!${NC}"; pause; continue
                fi
                if ! [[ "$iv" =~ ^[0-9]+$ ]] || [ "$iv" -lt 1 ]; then
                    echo -e "${RED}Interval harus angka >= 1!${NC}"; pause; continue
                fi
                mapfile -t ACCS < <(awk -F: '$7=="/bin/false"{print $1}' /etc/passwd | while read -r u; do [ -d "/home/$u" ] && echo "$u"; done)
                echo "Akun target tersedia:"; for i in "${!ACCS[@]}"; do echo "  $((i+1)). ${ACCS[$i]}"; done
                read -p "Target baru (nomor/nama, Enter=tetap): " tg
                if [ -n "$tg" ]; then
                    selected=""
                    for t in $tg; do
                        if [[ "$t" =~ ^[0-9]+$ ]]; then
                            idx=$((t-1))
                            [ "$idx" -ge 0 ] && [ "$idx" -lt "${#ACCS[@]}" ] && selected="$selected ${ACCS[$idx]}"
                        else
                            if id "$t" &>/dev/null; then
                                selected="$selected $t"
                            else
                                echo -e "${RED}Username '$t' tidak ditemukan, dilewati.${NC}"
                            fi
                        fi
                    done
                    tg=$(echo "$selected" | xargs)
                    [ -z "$tg" ] && { echo -e "${RED}Target tidak valid${NC}"; pause; continue; }
                else
                    tg="${oldtargets:-}"
                fi
                new="${slot}|${oldstart}|${dh}|${iv}|${olden:-1}|${jd_sec}|${tg}"
                tmp=$(mktemp)
                awk -v n="$ln" -v r="$new" 'NR==n{print r; next} {print}' /root/natssh/config/promo/promo_schedule.conf > "$tmp" && mv "$tmp" /root/natssh/config/promo/promo_schedule.conf
                echo -e "${GREEN}Jadwal diubah: $new${NC}"
                echo -e "${GREEN}Target: $tg${NC}"
                ;;
            4)
                now=$(date +%s)
                echo "=== JADWAL PROMO ==="
                echo ""
                if [ -f /root/natssh/config/promo/promo_schedule.conf ] && [ -s /root/natssh/config/promo/promo_schedule.conf ]; then
                    i=1
                    while IFS='|' read -r slot start days interval enabled jeda targets; do
                        [ -z "$slot" ] && continue
                        jeda=${jeda:-0}
                        end=$((start + days*86400))
                        start_str=$(date -d "@$start" '+%d/%m %H:%M')
                        end_str=$(date -d "@$end" '+%d/%m %H:%M')
                        if [ "$enabled" = "1" ]; then
                            if [ "$now" -ge "$start" ] && [ "$now" -le "$end" ]; then
                                status="${GREEN}● AKTIF${NC}"
                            elif [ "$now" -lt "$start" ]; then
                                status="${YELLOW}◐ TERJADWAL${NC}"
                            else
                                status="${RED}● BERAKHIR${NC}"
                            fi
                        else
                            status="${RED}○ NONAKTIF${NC}"
                        fi
                        _tg_disp="${targets:-—}"
                        echo -e "  ${CYAN}$i.${NC} ${YELLOW}$slot${NC}  |  durasi: ${days}h  |  interval: ${interval}m  |  jeda: ${jeda}s  |  $start_str → $end_str  |  $status  |  target: ${_tg_disp}"
                        i=$((i+1))
                    done < /root/natssh/config/promo/promo_schedule.conf
                    echo ""
                else
                    echo -e "  ${YELLOW}Tidak ada jadwal yang tersimpan.${NC}"
                fi
                echo ""
                read -p "Nomor baris toggle (0=batal): " ln
                [ "$ln" = "0" ] && continue
                line=$(sed -n "${ln}p" /root/natssh/config/promo/promo_schedule.conf 2>/dev/null)
                [ -z "$line" ] && { echo -e "${RED}Baris tidak ada${NC}"; pause; continue; }
                # toggle field 5
                new=$(echo "$line" | awk -F'|' '{if($5=="1") $5="0"; else $5="1"; print $1"|"$2"|"$3"|"$4"|"$5"|"$6"|"$7}')
                # replace line
                tmp=$(mktemp)
                awk -v n="$ln" -v r="$new" 'NR==n{print r; next} {print}' /root/natssh/config/promo/promo_schedule.conf > "$tmp" && mv "$tmp" /root/natssh/config/promo/promo_schedule.conf
                toggled_slot=$(echo "$new" | cut -d'|' -f1)
                toggled_state=$(echo "$new" | cut -d'|' -f5)
                if [ "$toggled_state" = "1" ]; then
                    echo -e "${GREEN}Jadwal '$toggled_slot' DIAKTIFKAN.${NC}"
                    # Aktifkan cron promo_rotate jika belum ada
                    if ! crontab -l 2>/dev/null | grep -q "promo_rotate.sh"; then
                        (crontab -l 2>/dev/null; echo "*/1 * * * * /root/natssh/promo_rotate.sh") | crontab -
                        echo -e "${GREEN}Cron promo_rotate diaktifkan.${NC}"
                    fi
                else
                    echo -e "${YELLOW}Jadwal '$toggled_slot' DINONAKTIFKAN.${NC}"
                fi
                ;;

            5)
                echo -e "${CYAN}=== STATUS PROMO ===${NC}"
                echo ""
                # Jadwal
                if [ -f /root/natssh/config/promo/promo_schedule.conf ] && [ -s /root/natssh/config/promo/promo_schedule.conf ]; then
                    echo -e "${YELLOW}Jadwal Promo:${NC}"
                    now=$(date +%s)
                    i=1
                    while IFS='|' read -r slot start days interval enabled jeda targets; do
                        [ -z "$slot" ] && continue
                        jeda=${jeda:-0}
                        end=$((start + days*86400))
                        start_str=$(date -d "@$start" '+%d/%m/%Y %H:%M')
                        end_str=$(date -d "@$end" '+%d/%m/%Y %H:%M')
                        if [ "$enabled" = "1" ]; then
                            if [ "$now" -ge "$start" ] && [ "$now" -le "$end" ]; then
                                status="${GREEN}AKTIF${NC}"
                            elif [ "$now" -lt "$start" ]; then
                                status="${YELLOW}TERJADWAL${NC}"
                            else
                                status="${RED}BERAKHIR${NC}"
                            fi
                        else
                            status="${RED}NONAKTIF${NC}"
                        fi
                        _tg_disp="${targets:-—}"
                        echo -e "  $i. ${CYAN}$slot${NC} | $start_str s/d $end_str | Interval: ${interval}m | Jeda: ${jeda}s | $status  |  target: ${_tg_disp}"
                        i=$((i+1))
                    done < /root/natssh/config/promo/promo_schedule.conf
                else
                    echo -e "  ${YELLOW}(tidak ada jadwal)${NC}"
                fi
                echo ""
                # Target per-slot
                _has_target=0
                if [ -f /root/natssh/config/promo/promo_schedule.conf ]; then
                    while IFS='|' read -r _ps _pst _pd _piv _pen _pjd; do
                        [ -z "$_ps" ] && continue
                        if [ -f /root/natssh/config/promo/promo_targets_${_ps}.conf ] && [ -s /root/natssh/config/promo/promo_targets_${_ps}.conf ]; then
                            [ "$_has_target" -eq 0 ] && echo -e "${YELLOW}Target Akun (per slot):${NC}"
                            _slot_has_target=0
                            while read -r u; do
                                u=$(echo "$u" | xargs)
                                [ -z "$u" ] && continue
                                [ "$_slot_has_target" -eq 0 ] && echo -e "  Slot ${CYAN}$_ps${NC}:"
                                _slot_has_target=1
                                _has_target=1
                                echo -e "    - ${CYAN}$u${NC}"
                            done < /root/natssh/config/promo/promo_targets_${_ps}.conf
                        fi
                    done < /root/natssh/config/promo/promo_schedule.conf
                fi
                echo ""
                # Backup
                if [ -f /root/natssh/banners/.default_backup ]; then
                    echo -e "${YELLOW}Backup Banner Default:${NC} ${GREEN}TERSIMPAN${NC} ($(stat -c '%y' /root/natssh/banners/.default_backup | cut -d. -f1))"
                else
                    echo -e "${YELLOW}Backup Banner Default:${NC} ${RED}BELUM ADA${NC}"
                fi
                echo ""
                # Log promo terakhir
                if [ -f /root/natssh/logs/promo.log ]; then
                    echo -e "${YELLOW}Log Terakhir:${NC}"
                    tail -20 /root/natssh/logs/promo.log | while read line; do echo "  $line"; done
                fi
                ;;
6)
                # restore banner default - selalu restore
                now=$(date +%s)
                echo -e "${YELLOW}=== JADWAL PROMO (pilih untuk hapus) ===${NC}"
                echo ""
                if [ -f /root/natssh/config/promo/promo_schedule.conf ] && [ -s /root/natssh/config/promo/promo_schedule.conf ]; then
                    i=1
                    while IFS='|' read -r slot start days interval enabled jeda targets; do
                        [ -z "$slot" ] && continue
                        jeda=${jeda:-0}
                        end=$((start + days*86400))
                        start_str=$(date -d "@$start" '+%d/%m %H:%M')
                        end_str=$(date -d "@$end" '+%d/%m %H:%M')
                        if [ "$enabled" = "1" ]; then
                            if [ "$now" -ge "$start" ] && [ "$now" -le "$end" ]; then
                                status="${GREEN}● AKTIF${NC}"
                            elif [ "$now" -lt "$start" ]; then
                                status="${YELLOW}◐ TERJADWAL${NC}"
                            else
                                status="${RED}● BERAKHIR${NC}"
                            fi
                        else
                            status="${RED}○ NONAKTIF${NC}"
                        fi
                        _tg_disp="${targets:-—}"
                        echo -e "  ${CYAN}$i.${NC} ${YELLOW}$slot${NC}  |  durasi: ${days}h  |  interval: ${interval}m  |  jeda: ${jeda}s  |  $start_str → $end_str  |  $status  |  target: ${_tg_disp}"
                        i=$((i+1))
                    done < /root/natssh/config/promo/promo_schedule.conf
                else
                    echo -e "  ${YELLOW}Tidak ada jadwal yang tersimpan.${NC}"
                fi
                echo ""
                read -p "Nomor baris hapus (0=batal, all=semua): " ln
                [ "$ln" = "0" ] && continue
                if [ "$ln" = "all" ]; then
                    read -p "Yakin hapus SEMUA jadwal? (y/N): " y
                    [[ "$y" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                    : > /root/natssh/config/promo/promo_schedule.conf
                    rm -f /root/natssh/.promo_last_run
                    echo -e "${GREEN}Semua jadwal dihapus.${NC}"
                else
                    _target_line=$(sed -n "${ln}p" /root/natssh/config/promo/promo_schedule.conf 2>/dev/null)
                    _target_slot=$(echo "$_target_line" | cut -d'|' -f1)
                    read -p "Yakin hapus jadwal '$_target_slot'? (y/N): " y
                    [[ "$y" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Dibatalkan.${NC}"; pause; continue; }
                    tmp=$(mktemp)
                    awk -v n="$ln" 'NR!=n{print}' /root/natssh/config/promo/promo_schedule.conf > "$tmp" && mv "$tmp" /root/natssh/config/promo/promo_schedule.conf
                    echo -e "${GREEN}Jadwal '$_target_slot' dihapus.${NC}"
                fi
                # restore banner hanya jika tidak ada promo aktif lain
                _has_active=0
                if [ -f /root/natssh/config/promo/promo_schedule.conf ]; then
                    while IFS='|' read -r _s _st _d _iv _en _jd; do
                        [ -z "$_s" ] && continue
                        [ "$_en" = "1" ] || continue
                        _end=$((_st + _d*86400))
                        if [ "$(date +%s)" -ge "$_st" ] && [ "$(date +%s)" -le "$_end" ]; then
                            _has_active=1; break
                        fi
                    done < /root/natssh/config/promo/promo_schedule.conf
                fi
                if [ "$_has_active" = "0" ]; then
                    _backup_tmp="/tmp/issue_banner_backup_$(date +%s)"
                    if [ -f /etc/issue.net ]; then
                        cp /etc/issue.net "$_backup_tmp"
                    fi
                    if [ -f /root/natssh/banners/.default_backup ]; then
                        cp /root/natssh/banners/.default_backup /etc/issue.net
                    elif [ -f /root/natssh/banners/default.txt ]; then
                        cp /root/natssh/banners/default.txt /etc/issue.net
                    elif [ -f "$_backup_tmp" ]; then
                        cp "$_backup_tmp" /etc/issue.net 2>/dev/null || true
                    fi
                    echo -e "${GREEN}Banner restored to default.${NC}"
                else
                    echo -e "${YELLOW}Masih ada promo aktif lain — banner tidak di-restore.${NC}"
                fi
                echo "$(date '+%F %T') PROMO CANCEL restore" >> /root/natssh/logs/promo.log
                ;;
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
    echo "3. Promosi Banner           (promo otomatis via banner)"
    echo "4. Backup & Restore"
    echo "5. Konfigurasi Sistem       (batas login/port)"
    echo -e "${RED}0. Keluar${NC}"
    garis
    read -p "Pilih menu (0-4): " menu || exit 0
    case $menu in
        1) menu_akun ;;
        2) menu_monitor ;;
        3) promo_menu ;;
        4) menu_backup ;;
        5) menu_conf ;;
        0) echo "Keluar dari menu."; break ;;
        *) echo -e "${RED}Pilihan tidak valid!${NC}"; pause ;;
    esac
done
