# Plan: Rewrite ws.py ke Async (asyncio)

**Branch:** `rewrite/async-ws-py`  
**Status:** Rencana saja — belum ada implementasi  
**Tujuan:** Migrasi `ws.py` dari model threading (blocking socket, satu thread per klien) ke asyncio (event loop, non-blocking I/O) agar lebih hemat memori dan scalable untuk banyak klien.

---

## 1. Latar Belakang

Saat ini `ws.py` menggunakan model **threading**:
- Setiap koneksi klien WebSocket/SSH Direct = satu thread OS (`threading.Thread`)
- I/O blocking (`socket.recv`, `socket.send`)
- OS kernel mengelola jadwal thread (preemptive)
- Setiap thread memakan stack memori (biasanya 1–8 MB)
- Banyak klien = banyak thread = banyak context switching

Model asyncio:
- Satu thread, satu event loop
- Non-blocking I/O (`await` pada socket operasi)
- Program mengelola jadwal task sendiri (cooperative)
- Tiap koneksi cuma objek kecil di memori, bukan thread OS
- Bisa menangani ribuan–puluhan ribu koneksi sekaligus di satu thread

---

## 2. Fitur yang Harus Tetap Berfungsi (Non-Negotiable)

Semua fitur existing di `ws.py` harus masih ada setelah rewrite:

| No | Fitur | Deskripsi |
|----|-------|-----------|
| 1 | WebSocket listener | `WS_PORT`, accept klien, upgrade HTTP ke WebSocket |
| 2 | SSH Direct listener | `SSH_DIRECT_PORT`, `SSH_DIRECT_ENABLED`, listener TCP polos |
| 3 | Proxy Protocol | `PROXY_PROTOCOL`, baca header PROXY dari nginx stream |
| 4 | Rate limiting | `MAX_PER_IP`, `MAX_TOTAL`, tolak klien yang melebihi batas |
| 5 | TCP keepalive | `TCP_KEEPALIVE` / `NATSSH_TCP_KEEPALIVE` |
| 6 | Idle timeout | `IDLE_TIMEOUT` / `NATSSH_IDLE_TIMEOUT` |
| 7 | Max connection age | `MAX_CONN_AGE` via watchdog |
| 8 | Logging | `LOG_FILE`, rotasi manual 500KB, format log sama |
| 9 | Connection dump | `conns.json`, `pending_sess.json`, state koneksi live |
| 10 | Forward duplex | Salur data dua arah (klien ↔ sshd) |
| 11 | `.env` loading | Baca `config/.env` saat startup sebagai fallback env |
| 12 | systemd compatible | Bisa dijalankan via `natssh-ws.service` tanpa modifikasi unit |

---

## 3. Arsitektur Baru (Async)

### 3.1 Event Loop Tunggal

```python
import asyncio

async def main():
    # Buat server WebSocket
    ws_server = await asyncio.start_server(
        handle_client, "127.0.0.1", WS_PORT
    )
    
    # Buat server SSH Direct (opsional)
    direct_server = None
    if SSH_DIRECT_ENABLED:
        direct_server = await asyncio.start_server(
            handle_direct_client, "127.0.0.1", SSH_DIRECT_PORT
        )
    
    # Jalankan watchdog
    watchdog_task = asyncio.create_task(_watchdog())
    
    # Jalankan kedua server selamanya
    async with ws_server, (direct_server if direct_server else nullcontext()):
        await asyncio.gather(
            ws_server.serve_forever(),
            direct_server.serve_forever() if direct_server else asyncio.sleep(0),
            watchdog_task,
        )
```

### 3.2 handle_client (WebSocket)

Ganti `threading.Thread` menjadi `asyncio.Task`:
- `client_socket.recv(8192)` → `await loop.sock_recv(client_socket, 8192)` atau pakai `StreamReader`
- `ssh_socket.connect(...)` → `await loop.sock_connect()` atau `asyncio.open_connection()`
- Loop forward → `asyncio.create_task()` untuk arah downstream, `await` untuk arah upstream

### 3.3 handle_direct_client (SSH Direct)

Sama pola dengan `handle_client`, tapi tanpa HTTP upgrade. PROXY Protocol dibaca lewat `await loop.sock_recv()`.

### 3.4 forward (Duplex Proxy)

```python
async def forward(src, dst, conn=None, field=None):
    try:
        while True:
            data = await loop.sock_recv(src, 4096)
            if not data:
                break
            await loop.sock_sendall(dst, data)
            if conn is not None:
                async with lock:
                    conn[field] += len(data)
                await maybe_dump()
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        src.close()
        dst.close()
```

### 3.5 State Management (Thread-Safe → Async-Safe)

- `_lock` (`threading.Lock`) → `asyncio.Lock()`
- `_per_ip`, `_total`, `_CONNS`, `_LAST` — diakses hanya dalam event loop, tidak perlu lock ekstra kecuali ada task yang saling modifikasi
- `_dump()` — write file secara sinkron (kecil, 500KB maks, cepat), atau pakai `loop.run_in_executor()` jika takut blokir

---

## 4. Perubahan Per File

### 4.1 `ws.py` (Rewrite total)

- Impor `asyncio`, `contextlib.nullcontext`
- Hapus `threading`, `itertools` (ganti dengan `asyncio.Task`)
- Ganti semua `socket.recv`/`send` blocking dengan `await loop.sock_recv`/`sock_sendall`
- Ganti `threading.Lock` dengan `asyncio.Lock`
- Ganti `threading.Thread` dengan `asyncio.create_task`
- `main()` menjadi `async def main()`
- `accept_direct()` dihapus, diganti dengan `asyncio.start_server` untuk SSH Direct

### 4.2 `menu.sh` (Tidak perlu perubahan, tapi verifikasi)

- `conf_port()` dan `conf_heartbeat()` tulis ke `.env` — sudah OK
- `ws.py` dibaca `.env` saat startup — sudah OK
- Tidak ada referensi langsung ke threading di `menu.sh`

### 4.3 `install.sh` (Tidak perlu perubahan)

- Systemd unit `natssh-ws.service` tetap memanggil `python3 /root/natssh/ws.py`
- Tidak ada parameter khusus threading

### 4.4 `autokill.sh` (Tidak perlu perubahan)

- Tidak bergantung pada implementasi internal `ws.py`

---

## 5. Risiko dan Mitigasi

| Risiko | Dampak | Mitigasi |
|--------|--------|----------|
| `asyncio` tidak support operation blocking di event loop | Event loop macet, semua klien terputus | Jangan panggil I/O sinkron berhari lama di event loop; pakai `run_in_executor` untuk file I/O besar |
| `ws.py` saat ini dipakai production | Rewrite gagal bisa putus semua klien | Uji di branch `rewrite/async-ws-py` dulu, baru merge ke `main` setelah stabil |
| Kode async lebih kompleks debugging | Susah melacak bug race condition | Gunakan `asyncio.Lock` konsisten, log semua task yang dibuat |
| File I/O logging blokir event loop | Log sering ditulis bisa sedikit menunda | Rotasi log 500KB sudah kecil, risiko rendah |

---

## 6. Checklist Implementasi (Tahap Demi Tahap)

- [ ] Buat branch `rewrite/async-ws-py` (SELESAI)
- [ ] Tulis ulang `ws.py` ke asyncio (todo)
- [ ] `python3 -m py_compile ws.py` — syntax OK (todo)
- [ ] Jalankan `ws.py` secara manual di terminal, cek listener WS dan Direct (todo)
- [ ] Coba koneksi WebSocket klien ke `ws.py` baru (todo)
- [ ] Coba koneksi SSH Direct (jika `SSH_DIRECT_ENABLED=1`) (todo)
- [ ] Verifikasi rate limiting masih bekerja (todo)
- [ ] Verifikasi log dan `conns.json` masih tertulis (todo)
- [ ] Restart `natssh-ws.service` via systemd, cek `systemctl status` (todo)
- [ ] Commit ke branch `rewrite/async-ws-py` (todo)
- [ ] Uji di valvatacea (scp + restart service) (todo)
- [ ] Merge ke `main` setelah stabil di kedua mesin (todo)

---

## 7. Estimasi Waktu

- Rewrite `ws.py`: 2–4 jam
- Testing manual: 1–2 jam
- Testing di valvatacea: 30 menit
- Total: 4–7 jam (bisa dibagi beberapa sesi)

---

## 8. Catatan

- Jangan hapus `ws.py` versi threading sebelum rewrite async stabil dan diuji di production.
- Simpan backup `ws.py` versi lama di branch ini atau tag git sebelum overwrite.
- Jika async terlalu kompleks, fallback: pertahankan threading tetapi perbaiki bottleneck yang ada (misal kurangi stack size thread, tuning `MAX_TOTAL`).
