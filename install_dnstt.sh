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

default_ns="t.${domain}"
read -p "Masukkan DNSTT NS (kosongkan untuk ${default_ns}): " ns
ns=${ns:-$default_ns}
ns=$(echo "$ns" | xargs)
if [ -z "$ns" ]; then
    echo -e "${RED}DNSTT NS wajib diisi.${NC}"
    exit 1
fi
if ! [[ "$ns" =~ ^[a-zA-Z0-9.-]{3,100}$ ]]; then
    echo -e "${RED}Format NS salah.${NC}"
    exit 1
fi

echo -e "\\n[*] DNSTT NS: ${GREEN}${ns}${NC}"
echo -e "${YELLOW}Pastikan DNS record sudah dibuat:${NC}"
echo -e "  A  : tns.${domain} -> IP VPS"
echo -e "  NS : ${ns} -> tns.${domain}"

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
if ! git clone --depth 1 https://www.bamsoftware.com/git/dnstt.git /tmp/dnstt-build >/dev/null 2>&1; then
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
echo -e "${GREEN}DNSTT NS dan PubKey disimpan ke .env${NC}"

echo -e "\\n[*] Membuat service systemd DNSTT..."
cat > /etc/systemd/system/natssh-dnstt.service <<EOF
[Unit]
Description=NATSSH DNSTT Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${DIR}/dnstt
ExecStart=/usr/local/bin/dnstt-server -udp :5300 -privkey-file ${DIR}/dnstt/server.key ${ns} 127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now natssh-dnstt.service >/dev/null 2>&1
sleep 1
if systemctl is-active --quiet natssh-dnstt.service; then
    echo -e "${GREEN}Service natssh-dnstt aktif.${NC}"
else
    echo -e "${RED}Service natssh-dnstt gagal start. Cek: journalctl -u natssh-dnstt -n 20${NC}"
    exit 1
fi

# Bersihkan build
rm -rf /tmp/dnstt-build
if [ "$INSTALLED_GO" = "1" ]; then
    rm -rf /usr/local/go
    echo -e "${GREEN}Go yang diinstall installer dihapus (build sukses).${NC}"
fi
# Pertahankan git untuk fitur lain.

echo -e "\\n${CYAN}================================================${NC}"
echo -e "${GREEN} DNSTT SERVER SELESAI ${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "NS      : ${YELLOW}${ns}${NC}"
echo -e "PubKey  : ${YELLOW}${pubkey}${NC}"
echo -e "Service : ${YELLOW}natssh-dnstt${NC}"
echo -e "Client  : dnstt-client -udp 1.1.1.1:53 -pubkey-file server.pub ${ns} 127.0.0.1:8000"
echo -e "${YELLOW}Jangan lupa buat DNS record NS: ${ns} -> tns.${domain}${NC}"