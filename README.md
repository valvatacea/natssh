# 🚀 NATSSH - Proxy SSH WebSocket & Manajemen Lengkap (Khusus VPS NAT)

NATSSH adalah ekosistem manajemen VPN SSH yang dirancang khusus untuk lingkungan **VPS NAT** dengan keterbatasan port. Proyek ini membungkus koneksi OpenSSH bawaan Linux ke dalam lalu lintas WebSocket (WS) agar dapat melewati proksi Cloudflare (Awan Oranye), tanpa perlu menginstal dependensi berat seperti Dropbear atau Stunnel yang sering bentrok dengan port panel Xray (misalnya 3X-UI).

## ✨ Fitur Unggulan

*   **Bypass Cloudflare (`ws.py` v2):** Menjembatani port NAT eksternal ke SSH lokal (port 22) dengan **rate-limit banjir pra-autentikasi** (default 10 koneksi/IP, 30 total; env `NATSSH_MAX_PER_IP`/`NATSSH_MAX_TOTAL`) — banjir scanner dari internet ditahan sebelum menyentuh `sshd` (mencegah insiden *MaxStartups throttling* yang membuat SSH "mati"). Koneksi, penolakan, dan kegagalan dicatat di `ws.log` dengan rotasi otomatis 500KB.
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

---

## 🛠️ Prasyarat

1. VPS Linux (Ubuntu/Debian) dengan akses **Root**.
2. Minimal memiliki **1 Port NAT kosong** (untuk jalur masuk proksi Cloudflare).
3. Domain yang sudah terhubung ke Cloudflare.

---

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

**Catatan saat instalasi:** Skrip akan meminta **Port NAT kosong** (pastikan sudah di-forward oleh provider) dan **batas perangkat per akun** (default 5). Port disetel via `Environment=NATSSH_WS_PORT` di unit systemd — aman diubah kapan pun lewat menu tanpa menyentuh source.

### Konfigurasi Cloudflare (Origin Rules)

Agar koneksi bisa menembus jaringan Cloudflare:

1. Masuk ke dashboard Cloudflare -> Domain Anda -> **Rules** -> **Origin Rules**.
2. Buat aturan baru (*Create Rule*).
3. **Field:** `Hostname` | **Operator:** `equals` | **Value:** `ssh.domainanda.com`
4. **Action:** `Rewrite to...` isi dengan port NAT yang Anda masukkan saat instalasi tadi (Contoh: `20864`).
5. Pastikan DNS Record `ssh.domainanda.com` berstatus **Proxied (Awan Oranye)**.

---

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
| `host.conf` | Domain di kartu akun | host = IP publik |
| `ip.conf` | IP di kartu akun | auto-detect via ifconfig.me |
| `port.conf` | Port Cloudflare di kartu akun | default 2086 |
| `banners/` | Slot banner tersimpan | — |

---

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

---

## 🗑️ Cara Uninstall

Jika Anda ingin mencopot pemasangan NATSSH dari server Anda, cukup jalankan:

```bash
sudo bash uninstall.sh
```

Skrip ini akan menghentikan *service*, menghapus konfigurasi port, membersihkan penjadwalan Cronjob, dan memberikan opsi untuk menghapus direktori *source code*.

---

*Dibuat dan dioptimalkan secara khusus untuk ekosistem VPS NAT berbasis IPv4 Shared.*
