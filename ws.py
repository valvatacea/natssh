"""NATSSH ws.py v2 — jembatan SSH-over-WebSocket dengan rate-limit & log.

Perbaikan atas v1: banjir koneksi pra-auth dari internet (via Cloudflare)
dulu diteruskan langsung ke sshd sampai MaxStartups throttling → SSH "mati"
31 menit (insiden 2026-11-01 12:49). Kini banjir ditahan di lapisan ini:
maks MAX_PER_IP koneksi concurrent per IP dan MAX_TOTAL keseluruhan;
sisanya ditutup sebelum menyentuh sshd, dan dicatat.
"""

import os
import socket
import threading
import time

WS_PORT = int(os.environ.get("NATSSH_WS_PORT", "20865"))  # port publik NAT (Cloudflare)
SSH_PORT = int(os.environ.get("NATSSH_SSH_PORT", "22"))   # sshd lokal
MAX_PER_IP = int(os.environ.get("NATSSH_MAX_PER_IP", "10"))
MAX_TOTAL = int(os.environ.get("NATSSH_MAX_TOTAL", "30"))
IDLE_TIMEOUT = int(os.environ.get("NATSSH_IDLE_TIMEOUT", "300"))  # detik tanpa data -> putuskan
MAX_LOG_SIZE = 512_000  # 500 KB, selaras autokill.sh

LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ws.log")

_lock = threading.Lock()
_per_ip: dict[str, int] = {}
_total = 0


def _log(msg: str) -> None:
    """Log ringkas + rotasi manual; kegagalan logging tak boleh menjatuhkan jembatan."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg + "\n")
        if os.path.getsize(LOG_FILE) > MAX_LOG_SIZE:
            with open(LOG_FILE, "w") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " log dibersihkan (cap 500KB)\n")
    except OSError:
        pass


def _admit(ip: str) -> bool:
    global _total
    with _lock:
        n = _per_ip.get(ip, 0)
        if _total >= MAX_TOTAL or n >= MAX_PER_IP:
            return False
        _per_ip[ip] = n + 1
        _total += 1
        return True


def _release(ip: str) -> None:
    global _total
    with _lock:
        n = _per_ip.get(ip, 1) - 1
        if n <= 0:
            _per_ip.pop(ip, None)
        else:
            _per_ip[ip] = n
        _total = max(0, _total - 1)


def forward(src, dst):
    """Salur satu arah; tutup dua-duanya saat satu arah berhenti."""
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.send(data)
    except OSError:
        pass
    finally:
        try:
            src.close()
            dst.close()
        except OSError:
            pass


def handle_client(client_socket, ip):
    global _total
    if not _admit(ip):
        try:
            cur = _per_ip.get(ip, 0)
            _log(f"TOLAK {ip} (per-ip={cur}, total={_total}, limit {MAX_PER_IP}/{MAX_TOTAL})")
        finally:
            try:
                client_socket.close()
            except OSError:
                pass
        return
    try:
        request = client_socket.recv(4096).decode("utf-8", errors="ignore")
        if "HTTP" in request:
            client_socket.send(b"HTTP/1.1 101 Switching Protocols\r\n"
                              b"Upgrade: websocket\r\n"
                              b"Connection: Upgrade\r\n\r\n")
        ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_socket.settimeout(10)
        ssh_socket.connect(("127.0.0.1", SSH_PORT))
        ssh_socket.settimeout(None)
        # idle-timeout dua arah: soket diem IDLE_TIMEOUT detik -> putus, slot lepas
        client_socket.settimeout(IDLE_TIMEOUT)
        ssh_socket.settimeout(IDLE_TIMEOUT)
        _log(f"JEMBAT {ip} (total={_total})")
        t_back = threading.Thread(target=forward,
                                  args=(ssh_socket, client_socket), daemon=True)
        t_back.start()
        forward(client_socket, ssh_socket)   # blok sampai koneksi selesai
        t_back.join(timeout=5)
    except OSError as exc:
        _log(f"GAGAL {ip}: {exc}")
        try:
            client_socket.close()
        except OSError:
            pass
    finally:
        _release(ip)


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", WS_PORT))
    server.listen(64)
    _log(f"mulai: ws={WS_PORT} -> ssh lokal {SSH_PORT}, limit {MAX_PER_IP}/ip, {MAX_TOTAL} total")
    while True:
        client, addr = server.accept()
        threading.Thread(target=handle_client, args=(client, addr[0]), daemon=True).start()


if __name__ == "__main__":
    main()
