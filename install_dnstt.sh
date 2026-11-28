#!/bin/bash
# Installer terpisah untuk DNSTT server (SSH over DNS)
# Dipanggil dari install.sh natssh atau dijalankan manual dari folder natssh.

set -u

RED='\\u001b[0;31m'
GREEN='\\u001b[0;32m'
YELLOW='\\u001b[0;33m'
CYAN='\\u001b[0;36m'
NC='\\u001b[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DIR}/config/.env"

env_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$ENV_FILE")"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

muat_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        . "$ENV_FILE"
        set +a
    fi
}

if [ "${EUID}" -ne 0 ]; then
    echo -e "${RED}Jalankan sebagai root.${NC}"
    exit 1
fi

muat_env

# Idempotensi: jangan reinstall tanpa konfirmasi
if [ -f /etc/systemd/system/natssh-dnstt.service ] || [ -n "${DNSTT_NS:-}" ] || [ -n "${DNSTT_PUBKEY:-}" ] || [ -n "${DNSTT_DOMAIN:-}" ]; then
    echo -e "${YELLOW}Peringatan: DNSTT sudah terinstal.${NC}"
    read -p "Lanjutkan reinstall? Config dan keypair akan ditimpa. (y/N): " reinstall_confirm
    if [[ ! "$reinstall_confirm" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Instalasi dibatalkan.${NC}"
        exit 0
    fi
fi

# Backup .env untuk rollback jika gagal
ENV_BACKUP=0
if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "${ENV_FILE}.dnstt.bak"
    ENV_BACKUP=1
fi
_rollback_env_dnstt() {
    if [ "$?" -ne 0 ] && [ "$ENV_BACKUP" -eq 1 ] && [ -f "${ENV_FILE}.dnstt.bak" ]; then
        cp "${ENV_FILE}.dnstt.bak" "$ENV_FILE"
        rm -f "${ENV_FILE}.dnstt.bak"
        echo -e "${RED}Rollback: .env dikembalikan ke versi sebelumnya.${NC}"
    fi
}
trap '_rollback_env_dnstt' EXIT

domain="${1:-}"
if [ -z "$domain" ]; then
    if [ -n "${DOMAIN:-}" ]; then
        domain="$DOMAIN"
    else
        read -p "Masukkan Domain/Host dasar (contoh: id1.xenonblue.qzz.io): " domain
    fi
fi
domain=$(echo "$domain" | xargs)
if [ -z "$domain" ]; then
    echo -e "${RED}Domain wajib diisi.${NC}"
    exit 1
fi

dnstt_domain="$domain"
env_set "DNSTT_DOMAIN" "$dnstt_domain"

read -p "Masukkan DNSTT NS (wajib, kosong = edit nanti di menu.sh): " ns
ns=$(echo "$ns" | xargs)
if [ -n "$ns" ] && ! [[ "$ns" =~ ^[a-zA-Z0-9.-]{3,100}$ ]]; then
    echo -e "${RED}Format NS salah.${NC}"
    exit 1
fi

echo -e "\\n[*] DNSTT Domain: ${GREEN}${dnstt_domain}${NC}"
if [ -z "$ns" ]; then
    echo -e "${YELLOW}Peringatan: NS kosong. DNSTT tidak akan berjalan sampai NS diisi.${NC}"
    echo -e "${YELLOW}Isi NS lewat menu.sh atau jalankan ulang installer.${NC}"
else
    echo -e "[*] DNSTT NS: ${GREEN}${ns}${NC}"
    echo -e "${YELLOW}Pastikan DNS record sudah dibuat:${NC}"
    echo -e "  A  : ${dnstt_domain} -> IP VPS"
    echo -e "  NS : ${ns} -> ${dnstt_domain}"
fi

# Cek port 53
if ss -tuln 2>/dev/null | grep -q ':53 '; then
    echo -e "${YELLOW}Peringatan: port 53 sudah dipakai service lain. Redirect mungkin konflik.${NC}"
fi

echo -e "\\n[*] Menginstal dependensi firewall..."
apt-get update >/dev/null 2>&1
apt-get install -y iptables iptables-persistent >/dev/null 2>&1
mkdir -p /etc/iptables

echo -e "[*] Membuka dan redirect UDP 53 -> 5300..."
iptables -C INPUT -p udp --dport 53 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport 53 -j ACCEPT
iptables -C INPUT -p udp --dport 5300 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport 5300 -j ACCEPT
IFACE="${IFACE:-$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)}"
IFACE="${IFACE:-eth0}"
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 53 -j REDIRECT --to-port 5300 >/dev/null 2>&1 || \
    iptables -t nat -I PREROUTING -i "$IFACE" -p udp --dport 53 -j REDIRECT --to-port 5300
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

# Install Go jika belum ada
INSTALLED_GO=0
if ! command -v go >/dev/null 2>&1; then
    echo -e "\\n[*] Go belum terpasang. Mengunduh Go..."
    GO_VER="1.22.5"
    GO_TAR="/tmp/go${GO_VER}.linux-amd64.tar.gz"
    wget -q "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -O "$GO_TAR"
    if [ ! -s "$GO_TAR" ]; then
        echo -e "${RED}Gagal mengunduh Go.${NC}"
        exit 1
    fi
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GO_TAR"
    export PATH="/usr/local/go/bin:$PATH"
    INSTALLED_GO=1
    rm -f "$GO_TAR"
    if ! command -v go >/dev/null 2>&1; then
        echo -e "${RED}Go gagal terpasang.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Go terpasang.${NC}"
else
    echo -e "${GREEN}Go sudah terpasang, lewati instalasi.${NC}"
fi

echo -e "\\n[*] Mengunduh dan build DNSTT..."
rm -rf /tmp/dnstt-build
if ! git clone https://www.bamsoftware.com/git/dnstt.git /tmp/dnstt-build >/dev/null 2>&1; then
    echo -e "${RED}Gagal clone DNSTT.${NC}"
    exit 1
fi
cd /tmp/dnstt-build/dnstt-server
if ! go build; then
    echo -e "${RED}Gagal build DNSTT server.${NC}"
    exit 1
fi
if [ ! -x /tmp/dnstt-build/dnstt-server/dnstt-server ]; then
    echo -e "${RED}Binary DNSTT server tidak ditemukan.${NC}"
    exit 1
fi
cd - >/dev/null

mkdir -p "${DIR}/dnstt"
cp /tmp/dnstt-build/dnstt-server/dnstt-server "${DIR}/dnstt/dnstt-server-bin" 2>/dev/null || true
install -m 0755 /tmp/dnstt-build/dnstt-server/dnstt-server /usr/local/bin/dnstt-server

echo -e "\\n[*] Generate keypair DNSTT..."
cd "${DIR}/dnstt"
/usr/local/bin/dnstt-server -gen-key -privkey-file server.key -pubkey-file server.pub >/dev/null 2>&1
if [ ! -s server.key ] || [ ! -s server.pub ]; then
    echo -e "${RED}Gagal generate keypair DNSTT.${NC}"
    exit 1
fi
pubkey=$(tr -d '[:space:]' < server.pub)
if ! [[ "$pubkey" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo -e "${YELLOW}Public key bukan hex 64 char, simpan path file sebagai fallback.${NC}"
    pubkey="${DIR}/dnstt/server.pub"
fi

env_set "DNSTT_NS" "$ns"
env_set "DNSTT_PUBKEY" "$pubkey"
echo -e "${GREEN}DNSTT Domain, NS, dan PubKey disimpan ke .env${NC}"

if [ -z "$ns" ]; then
    echo -e "${YELLOW}Service natssh-dnstt tidak dibuat karena NS kosong.${NC}"
    systemctl stop natssh-dnstt >/dev/null 2>&1 || true
    systemctl disable natssh-dnstt >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/natssh-dnstt.service
    systemctl daemon-reload >/dev/null 2>&1 || true
else
    echo -e "\\n[*] Membuat config Nginx SNI untuk Xray..."
    mkdir -p /etc/nginx/stream.d
    if [ ! -f /etc/nginx/stream.conf ]; then
        cat > /etc/nginx/stream.conf <<EOF
stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
    fi

    read -p "VMess SNI domain (kosong skip): " vmess_domain
    read -p "VMess port [10001]: " vmess_port
    vmess_port=${vmess_port:-10001}
    read -p "VLESS SNI domain (kosong skip): " vless_domain
    read -p "VLESS port [10002]: " vless_port
    vless_port=${vless_port:-10002}
    read -p "Trojan SNI domain (kosong skip): " trojan_domain
    read -p "Trojan port [10003]: " trojan_port
    trojan_port=${trojan_port:-10003}

    {
        echo "map \$ssl_preread_server_name \$dnstt_backend {"
        [ -n "$vmess_domain" ] && echo "    ${vmess_domain}   127.0.0.1:${vmess_port};"
        [ -n "$vless_domain" ] && echo "    ${vless_domain}   127.0.0.1:${vless_port};"
        [ -n "$trojan_domain" ] && echo "    ${trojan_domain}  127.0.0.1:${trojan_port};"
        echo "    default            127.0.0.1:22;"
        echo "}"
        echo ""
        echo "server {"
        echo "    listen 127.0.0.1:9000;"
        echo "    proxy_pass \$dnstt_backend;"
        echo "    ssl_preread on;"
        echo "}"
    } > /etc/nginx/stream.d/dnstt.conf

    if ! nginx -t >/dev/null 2>&1; then
        echo -e "${RED}Config nginx invalid. Hapus dnstt.conf.${NC}"
        rm -f /etc/nginx/stream.d/dnstt.conf
    else
        systemctl restart nginx >/dev/null 2>&1 || true
        echo -e "${GREEN}Config Nginx SNI DNSTT dibuat.${NC}"
    fi

    echo -e "\\n[*] Membuat service systemd DNSTT..."
    cat > /etc/systemd/system/natssh-dnstt.service <<EOF
[Unit]
Description=NATSSH DNSTT Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${DIR}/dnstt
ExecStart=/usr/local/bin/dnstt-server -udp :5300 -privkey-file ${DIR}/dnstt/server.key ${ns} 127.0.0.1:9000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable natssh-dnstt.service >/dev/null 2>&1
    systemctl restart natssh-dnstt.service >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet natssh-dnstt.service; then
        echo -e "${GREEN}Service natssh-dnstt aktif.${NC}"
    else
        echo -e "${RED}Service natssh-dnstt gagal start. Cek: journalctl -u natssh-dnstt -n 20${NC}"
        exit 1
    fi
fi

# Bersihkan build
rm -rf /tmp/dnstt-build
if [ "$INSTALLED_GO" = "1" ]; then
    rm -rf /usr/local/go
    echo -e "${GREEN}Go yang diinstall installer dihapus (build sukses).${NC}"
fi
# Tandai sukses agar rollback tidak aktif
if [ "$ENV_BACKUP" -eq 1 ]; then
    rm -f "${ENV_FILE}.dnstt.bak"
fi
trap - EXIT

# Pertahankan git untuk fitur lain.

echo -e "\\n${CYAN}================================================${NC}"
echo -e "${GREEN} DNSTT SERVER SELESAI ${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "NS      : ${YELLOW}${ns}${NC}"
echo -e "PubKey  : ${YELLOW}${pubkey}${NC}"
echo -e "Service : ${YELLOW}natssh-dnstt${NC}"
echo -e "Client  : dnstt-client -udp 1.1.1.1:53 -pubkey-file server.pub ${ns} 127.0.0.1:8000"
echo -e "${YELLOW}Jangan lupa buat DNS record: A ${dnstt_domain} -> IP VPS; NS ${ns} -> ${dnstt_domain}${NC}"