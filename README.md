# 🚀 NATSSH - Proxy SSH WebSocket & Manajemen Lengkap (Khusus VPS NAT)

NATSSH adalah ekosistem manajemen VPN SSH yang dirancang khusus untuk lingkungan **VPS NAT** dengan keterbatasan port. Proyek ini membungkus koneksi OpenSSH bawaan Linux ke dalam lalu lintas WebSocket (WS) agar dapat melewati proksi Cloudflare (Awan Oranye), tanpa perlu menginstal dependensi berat seperti Dropbear atau Stunnel yang sering bentrok dengan port panel Xray (misalnya 3X-UI).

> 🔄 **Perubahan arsitektur terbaru:** Stunnel4 (terminator TLS lama) telah diganti oleh **Nginx Reverse Proxy**. Nginx sekarang menangani terminate TLS di port publik dan mentransfer lalu lintas plain WebSocket ke `ws.py` di localhost. Alasan: stunnel menyamakan semua klien sebagai `127.0.0.1` sehingga fitur `MAX_PER_IP` tidak berfungsi; Nginx mengirim header `X-Forwarded-For` dan `X-Forwarded-Port` sehingga IP asli klien tetap terbaca oleh `ws.py`.

## ✨ Fitur Unggulan

*   **Bypass Cloudflare (`ws.py` v2):** Menjembatani port NAT eksternal ke SSH lokal (port 22) dengan **rate-limit banjir pra-autentikasi** (default 10 koneksi/IP, 30 total; env `NATSSH_MAX_PER_IP`/`NATSSH_MAX_TOTAL`) — banjir scanner dari internet ditahan sebelum menyentuh `sshd` (mencegah insiden *MaxStartups throttling* yang membuat SSH "mati"). Koneksi, penolakan, dan kegagalan dicatat di `ws.log` dengan rotasi otomatis 500KB.
*   **TLS Termination via Nginx:** Nginx terminate TLS di port publik (port stunnel lama) dan forward plain WS ke `ws.py` di `127.0.0.1:<NATSSH_WS_PORT>`. Sertifikat TLS diterbitkan melalui **Cloudflare API (acme.sh, DNS challenge)** dan disimpan di `/etc/nginx/ssl/natssh.{crt,key}`.
*   **Menu Manajemen v4.0 (`menu.sh`):** Antarmuka terminal interaktif — buat akun, **browser daftar akun** (suspend/unsuspend/perpanjang/hapus di satu tempat, dengan konfirmasi + catatan audit), monitoring online/autokill/sistem, backup portabel, dan konfigurasi sistem.
*   **Kartu Akun Siap Salin:** Setiap akun baru menampilkan blok DETAIL AKUN — Domain Cloudflare + Domain CloudFront (bila diatur), IP, Port WS, daftar port CDN, username/password, tanggal kedaluwarsa, dan limit perangkat.
*   **Sistem Backup Portabel:** Mengekstrak seluruh akun aktif beserta kata sandi terenkripsinya menjadi satu skrip mandiri (`backup_akun_ssh.sh`, mode 700) yang siap di-*restore* di VPS mana pun.
*   **Autokill Cerdas (`autokill.sh`):** Cron tiap 1 menit, menendang multi-login melebihi batas (`MAX_LOGIN` via env, default 5). Hitungan perangkat = jumlah proses `sshd: user` (milik user) LANGSUNG — pasangan `[priv]` milik root dibuang oleh filter. Sesi hantu (proses hidup tapi soket bridge mati) dibersihkan `reap.py` sebelum penghitungan. Akun yang melebihi batas otomatis **disuspend 15 menit** (`usermod -L` + catat expiry) dan **di-unsuspend otomatis** oleh `unsuspend.sh` tiap 1 menit. Username panjang (hingga 32 karakter) tetap terbaca (fix truncation `ps -ef`).
*   **Audit Lengkap:** Tiga jalur tercatat di `autokill.log` — tendangan autokill, HAPUS manual, dan AUTO-CLEAN akun kedaluwarsa.
*   **Banner SSH Fleksibel:** Edit via nano/vi, reset ke template (baris "Maksimal N Perangkat" otomatis sinkron dengan limit), plus **slot simpan/muat/hapus** (`banners/`).
*   **Hide IP (Konfigurasi Sistem):** Toggle untuk menyembunyikan IP publik pada kartu akun baru (menu Konfigurasi item 9). Status disimpan di `hide_ip.conf` (server-local, tidak di-track git) dan otomatis dibersihkan saat uninstall.
*   **Speed Limiting SSH:** Pembatasan bandwidth per akun menggunakan qdisc (HTB/TBF + fq_codel) dengan burst, dicek via `tc classes`. Menu menampilkan status limit saat ini.
*   **Auto-restart Terjadwal:** Installer menambahkan restart otomatis `natssh-ws` pukul 03:00 (cron/systemd) untuk stabilitas.
*   **High Availability:** Terintegrasi penuh dengan `systemd` (Environment-aware, auto-start, auto-restart).
*   **Instalasi Interaktif:** `install.sh` menanyakan port NAT & batas perangkat; port disetel via `Environment=` systemd (bukan edit source), unduhan tervalidasi.

## 🏗️ Arsitektur Sistem

```
Klien (HP / PC)
    │ HTTPS/WSS (TLS)
    ▼
Cloudflare (Origin Rule → Port NAT VPS)
    │
    ▼
Nginx Reverse Proxy  ──┬── listen 0.0.0.0:<PORT_TLS> ssl
                       │   ssl_certificate /etc/nginx/ssl/natssh.crt
                       │   ssl_certificate_key /etc/nginx/ssl/natssh.key
                       │   proxy_pass http://127.0.0.1:<PORT_BACKEND>
                       │   X-Forwarded-For, X-Real-IP, X-Forwarded-Port
    │ plain WS (localhost)
    ▼
ws.py (natssh-ws.service) ──► sshd (port 22)
```

| Komponen | Port | Catatan |
|---|---|---|
| Nginx (TLS publik) | Port stunnel lama (contoh: `20885` / `20975`) | Terminator TLS, forward ke backend |
| ws.py (backend) | `127.0.0.1:<NATSSH_WS_PORT>` (contoh: `20185` / `20195`) | Plain WS, hanya bind localhost |
| sshd | `127.0.0.1:22` | OpenSSH bawaan Linux |

Port stunnel lama dan port backend ditetapkan saat instalasi melalui `install.sh` dan disimpan di `Environment=` unit systemd (`natssh-ws.service`).

## 🛠️ Prasyarat

1. VPS Linux (Ubuntu/Debian) dengan akses **Root**.
2. Minimal memiliki **1 Port NAT kosong** (untuk jalur masuk proksi Cloudflare).
3. Domain yang sudah terhubung ke Cloudflare.
4. Nginx akan dipasang otomatis oleh installer sebagai terminator TLS (tidak perlu stunnel).

## 📥 Panduan Instalasi (Satu Klik)

Jalankan rangkaian perintah berikut di terminal VPS Anda:

```bash
# 1. Unduh repositori
git clone https://github.com/valvatacea/natssh.git

# 2. Masuk ke dalam direktori
cd natssh

# 3. Jalankan skrip instalasi
sudo bash install.sh
```

**Catatan saat instalasi:** Skrip akan meminta **Domain/Host (wajib diisi)**, **Port NAT kosong** (pastikan sudah di-forward oleh provider) dan **batas perangkat per akun** (default 5). Domain disimpan ke `config/host.conf`; root domain diekstraksi melalui **Public Suffix List** (fallback ke `host.conf` jika gagal). Port disetel via `Environment=NATSSH_WS_PORT` di unit systemd — aman diubah kapan pun lewat menu tanpa menyentuh source.

Installer juga akan:
- Memasang acme.sh otomatis (jika belum ada)
- Muat variabel dari `config/.env` (jika ada) — termasuk `CF_Token` / `CF_Key`
- Meminta Cloudflare API Token untuk DNS challenge (jika tidak ada di env atau `.env`)
- Menerbitkan sertifikat TLS wildcard via acme.sh (Cloudflare API)
- Memasang Nginx sebagai reverse proxy TLS
- Menulis konfigurasi Nginx ke `/etc/nginx/sites-available/natssh-ws`
- Menghapus Stunnel4 bila masih terpasang (migrasi otomatis)

### Konfigurasi Cloudflare (Origin Rules)

Agar koneksi bisa menembus jaringan Cloudflare:

1. Masuk ke dashboard Cloudflare -> Domain Anda -> **Rules** -> **Origin Rules**.
2. Buat aturan baru (*Create Rule*).
3. **Field:** `Hostname` | **Operator:** `equals` | **Value:** `ssh.domainanda.com`
4. **Action:** `Rewrite to...` isi dengan port NAT yang Anda masukkan saat instalasi tadi (Contoh: `20864`).
5. Pastikan DNS Record `ssh.domainanda.com` berstatus **Proxied (Awan Oranye)**.

### Konfigurasi Nginx Reverse Proxy (TLS)

Contoh hasil generate installer (port disesuaikan otomatis):

```nginx
server {
    listen 20885 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/natssh.crt;
    ssl_certificate_key /etc/nginx/ssl/natssh.key;

    location / {
        proxy_pass http://127.0.0.1:20185;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

Nginx diaktifkan melalui symlink:
```bash
ln -sf /etc/nginx/sites-available/natssh-ws /etc/nginx/sites-enabled/natssh-ws
rm -f /etc/nginx/sites-enabled/default
systemctl enable --now nginx
```

## 🖥️ Penggunaan (Menu Manajemen)

Setelah terinstal, Anda dapat memanggil menu manajemen kapan saja dengan mengetik:

```bash
./menu.sh
```

*(Pastikan Anda berada di dalam folder tempat Anda menginstal skrip ini, atau gunakan path lengkap `/root/natssh/menu.sh`)*

**Struktur Menu (v4.0):**

```
1. Manajemen Akun
   1. Buat Akun SSH Baru        → kartu DETAIL AKUN siap-salin
   2. Daftar Akun (browser)     → pilih nomor/username, lalu:
                                 1 Suspend · 2 Unsuspend · 3 Perpanjang · 4 Hapus
                                 (semua berkonfirmasi; perpanjang dihitung DARI
                                  tanggal expired, sisa pelanggan tidak hangus)
   3. Auto-Clean                → hapus akun kedaluwarsa + catat audit
2. Monitoring & Log             → user online (perangkat nyata), autokill manual,
                                  riwayat, RAM/CPU/disk
3. Backup & Restore             → ekspor portabel (hash password, mode 700)
4. Konfigurasi Sistem
   1. Atur Batas Login          → cron + banner + kartu akun sinkron otomatis
   2. Ubah Port WebSocket       → cek bentrok, injeksi Environment systemd
   3. Ubah Domain/Host           → host.conf (kosong = auto IP publik)
   4. Ubah Banner Pelanggan     → edit / reset / slot simpan-muat-hapus
   5. Speed Limit SSH            → atur/cek pembatasan bandwidth (HTB/TBF)
   9. Hide IP                   → toggle sembunyikan IP pada kartu akun baru
```

**File konfigurasi opsional** (semua bisa lewat menu):

| File | Isi | Bila kosong |
|---|---|---|
| `host.conf` | Domain/Host di kartu akun (wajib diisi saat install; root domain diekstraksi via PSL untuk sertifikat) | host = IP publik |
| `ip.conf` | IP di kartu akun | auto-detect via ifconfig.me |
| `port.conf` | Port Cloudflare di kartu akun | default 2086 |
| `hide_ip.conf` | Toggle sembunyikan IP kartu akun | IP ditampilkan |
| `banners/` | Slot banner tersimpan | — |

## 📱 Contoh Konfigurasi Klien (DarkTunnel / HTTP Custom)

Gunakan format berikut pada aplikasi VPN di ponsel pintar Anda:

*   **SSH Host / Target:** `ssh.domainanda.com`
*   **SSH Port:** `443` *(Port HTTPS standar Cloudflare, BUKAN port NAT Anda)*
*   **Username & Password:** Sesuai dengan yang Anda buat di `menu.sh`.
*   **SNI (Server Name Indication):** `ssh.domainanda.com`
*   **Payload WebSocket / HTTP:**

```text
    GET / HTTP/1.1[crlf]Host: ssh.domainanda.com[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]

```

## 🔍 Verifikasi Instalasi

Setelah instalasi, pastikan semua layanan berjalan:

```bash
# Nginx (TLS publik)
systemctl is-active nginx
ss -tlnp | grep nginx

# Backend ws.py
systemctl is-active natssh-ws
ss -tlnp | grep python3

# Uji handshake WebSocket over TLS (harus balas HTTP 101)
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  --max-time 5 https://127.0.0.1:<PORT_TLS>/
```

## 🗑️ Cara Uninstall

Jika Anda ingin mencopot pemasangan NATSSH dari server Anda, cukup jalankan:

```bash
sudo bash uninstall.sh
```

Skrip ini akan menghentikan *service*, menghapus konfigurasi port, membersihkan penjadwalan Cronjob, dan memberikan opsi untuk menghapus direktori *source code*. Nginx dan sertifikat TLS juga akan dibersihkan.

## 🔄 Migrasi Stunnel → Nginx

Jika VPS Anda masih menggunakan Stunnel4 sebagai terminator TLS:

1. Matikan dan hapus stunnel4: `systemctl stop stunnel4 && apt-get purge -y stunnel4 && rm -rf /etc/stunnel`
2. Pasang Nginx dan buat sertifikat TLS baru di `/etc/nginx/ssl/`
3. Buat konfigurasi Nginx reverse proxy (lihat contoh di atas) dengan port listen = port stunnel lama
4. Restart Nginx dan `natssh-ws`
5. Verifikasi dengan `curl` (harus balas HTTP 101)

## 📄 Lisensi

Distribusikan di bawah lisensi MIT. Lihat file `LICENSE` untuk detail.

---

*Dibuat dan dioptimalkan secara khusus untuk ekosistem VPS NAT berbasis IPv4 Shared. Terintegrasi dengan Cloudflare sebagai proksi awalan.*