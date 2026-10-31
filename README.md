# 🚀 NATSSH - SSH WebSocket Proxy & Manajemen Lengkap (Khusus VPS NAT)

NATSSH adalah ekosistem manajemen VPN SSH murni yang dirancang secara khusus untuk lingkungan **VPS NAT** yang memiliki keterbatasan port. Proyek ini membungkus koneksi OpenSSH bawaan Linux menjadi lalu lintas WebSocket (WS) agar dapat melewati proksi Cloudflare (Awan Oranye), tanpa harus menginstal dependensi berat seperti Dropbear atau Stunnel yang sering membentrokkan port pada panel Xray (seperti 3X-UI).

## ✨ Fitur Unggulan

*   **Bypass Cloudflare (`ws.py`):** Skrip Python ringan yang menjembatani port NAT eksternal ke port SSH lokal (Port 22).
*   **Menu Manajemen v3.0 (`menu.sh`):** Antarmuka terminal interaktif dengan 13 opsi fitur untuk mengelola akun (Buat, Hapus, Perpanjang, Suspend, Auto-Clean, dll).
*   **Sistem Backup Portabel:** Mengekstrak seluruh akun aktif beserta kata sandi terenkripsinya menjadi satu file script mandiri (`backup_akun_ssh.sh`) yang siap di-*restore* di VPS mana pun.
*   **Autokill Cerdas (`autokill.sh`):** Memonitor via Cronjob dan memutus otomatis klien yang melakukan *multi-login*. Dilengkapi dengan sistem rotasi log (maksimal 500KB) agar penyimpanan VPS tidak penuh.
*   **Banner SSH Otomatis:** Menampilkan pesan peringatan/sapaan khusus saat klien berhasil terhubung.
*   **High Availability:** Terintegrasi penuh dengan `systemd`, sehingga layanan Proxy WebSocket akan otomatis menyala ulang (*auto-start*) meskipun VPS baru saja di-*reboot*.
*   **Instalasi Satu Klik:** Skrip `install.sh` interaktif yang mengurus semua pengaturan secara otomatis.

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

**Catatan saat instalasi:** Skrip akan meminta Anda untuk memasukkan **Port NAT Kosong**. Pastikan Anda memasukkan port yang sudah Anda buka di panel provider VPS Anda.

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

**Daftar Fitur Menu:**
1. Buat Akun SSH Baru
2. Hapus Akun SSH
3. Perpanjang Masa Aktif Akun
4. Cek Daftar Semua Akun SSH & Kedaluwarsa
5. Kunci Akun Sementara (Suspend)
6. Buka Kunci Akun (Unsuspend)
7. Bersihkan Semua Akun Kedaluwarsa (Auto-Clean)
8. Cek User Yang Sedang Login
9. Autokill (Tendang Multi-Login Manual)
10. Cek Riwayat Autokill (Log File)
11. Info RAM & CPU VPS
12. Backup Data Akun (Ekspor Portabel)
13. Keluar

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