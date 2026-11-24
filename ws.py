"""NATSSH ws.py v2 — jembatan SSH-over-WebSocket dengan rate-limit & log.

Perbaikan atas v1: banjir koneksi pra-auth dari internet (via Cloudflare)
dulu diteruskan langsung ke sshd sampai MaxStartups throttling → SSH "mati"
31 menit (insiden 2026-11-01 12:49). Kini banjir ditahan di lapisan ini:
maks MAX_PER_IP koneksi concurrent per IP dan MAX_TOTAL keseluruhan;
sisanya ditutup sebelum menyentuh sshd, dan dicatat.
"""

import collections
import itertools
import json
import os
import socket
import threading
import time

# Muat konfigurasi dari config/.env (jika ada) sebagai fallback
_env_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config", ".env")
if os.path.exists(_env_file):
    with open(_env_file) as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _key, _val = _line.split("=", 1)
                os.environ.setdefault(_key.strip(), _val.strip())

WS_PORT = int(os.environ.get("NATSSH_WS_PORT", "20865"))  # port publik NAT (Cloudflare)
SSH_PORT = int(os.environ.get("NATSSH_SSH_PORT", "22"))   # sshd lokal
MAX_PER_IP = int(os.environ.get("NATSSH_MAX_PER_IP", "10"))
MAX_TOTAL = int(os.environ.get("NATSSH_MAX_TOTAL", "30"))
IDLE_TIMEOUT = int(os.environ.get("NATSSH_IDLE_TIMEOUT", "300"))  # detik tanpa data -> putuskan
TCP_HEARTBEAT = os.environ.get("NATSSH_TCP_HEARTBEAT", "1") == "1"  # heartbeat TCP
MAX_CONN_AGE = int(os.environ.get("NATSSH_MAX_CONN_AGE", "3600"))  # maks usia koneksi (detik), 0 = nonaktif
MAX_LOG_SIZE = 512_000  # 500 KB, selaras autokill.sh
SSH_DIRECT_PORT = int(os.environ.get("NATSSH_SSH_DIRECT_PORT", "20169"))  # port listener SSH direct (raw TCP)
SSH_DIRECT_ENABLED = os.environ.get("NATSSH_SSH_DIRECT_ENABLED", "0") == "1"  # nyalakan listener SSH direct
PROXY_PROTOCOL = os.environ.get("NATSSH_PROXY_PROTOCOL", "0") == "1"  # terima header PROXY dari nginx stream

LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "ws.log")

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


def _admit(ip: str, via_cdn: bool = False) -> bool:
    # via_cdn: per-IP disisihkan — semua klien CDN berbagi beberapa edge IP
    # (CloudFront=AWS 52/99.x, Cloudflare=104/172.64-71.x); hanya dihitung MAX_TOTAL.
    global _total
    with _lock:
        if _total >= MAX_TOTAL:
            return False
        if not via_cdn:
            n = _per_ip.get(ip, 0)
            if n >= MAX_PER_IP:
                return False
            _per_ip[ip] = n + 1
        _total += 1
        return True


def _release(ip: str, via_cdn: bool = False) -> None:
    global _total
    with _lock:
        if not via_cdn:
            n = _per_ip.get(ip, 1) - 1
            if n <= 0:
                _per_ip.pop(ip, None)
            else:
                _per_ip[ip] = n
        _total = max(0, _total - 1)


_CONNS = {}                      # conn_id -> state koneksi live
_SEQ = itertools.count(1)
_LAST = collections.deque(maxlen=100)   # 100 koneksi terakhir selesai
_last_dump = 0.0
CONNS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "conns.json")
PENDING_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "pending_sess.json")


def _dump():
    global _last_dump
    with _lock:
        data = json.dumps({"live": list(_CONNS.values()), "last": list(_LAST)})
        _last_dump = time.time()
    tmp = CONNS_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(data)
        os.replace(tmp, CONNS_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        _log("GAGAL dump conns.json (retry ok)")


def _maybe_dump():
    if time.time() - _last_dump > 2.5:
        _dump()


def _header(req: str, name: str) -> str:
    """Ambil nilai header HTTP dari paket upgrade; case-insensitive."""
    for line in req.split("\r\n"):
        if ":" in line:
            k, v = line.split(":", 1)
            if k.strip().lower() == name.lower():
                return v.strip()
    return ""


def _parse_proxy_protocol(sock):
    """Baca header PROXY protocol v1 dari nginx stream; kembalikan (ip, port) klien asli atau None."""
    if not PROXY_PROTOCOL:
        return None
    try:
        line = b""
        while True:
            ch = sock.recv(1)
            if not ch:
                return None
            line += ch
            if line.endswith(b"\r\n"):
                break
            if len(line) > 108:
                return None
        text = line.decode("ascii", errors="ignore").strip()
        parts = text.split(" ")
        if len(parts) >= 5 and parts[0] == "PROXY" and parts[1] == "TCP4":
            return parts[2], int(parts[4])
    except OSError:
        return None
    return None

def forward(src, dst, conn=None, field=None):
    """Salur satu arah; tutup dua-duanya saat satu arah berhenti.
    conn/field opsional: menghitung byte lewat (statistik trafik per koneksi)."""
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.send(data)
            if conn is not None:
                with _lock:
                    conn[field] += len(data)
                _maybe_dump()
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
    conn = None
    cid = 0
    via_cdn = False
    admitted = False
    try:
        buf = client_socket.recv(8192)                      # RAW (bytes): utk diteruskan
        request = buf.decode("utf-8", errors="ignore")     # hanya utk deteksi header
    except OSError:
        try:
            client_socket.close()
        except OSError:
            pass
        return
    if "HTTP" in request:
        try:
            client_socket.send(b"HTTP/1.1 101 Switching Protocols\r\n"
                              b"Upgrade: websocket\r\n"
                              b"Connection: Upgrade\r\n\r\n")
        except OSError:
            pass
    # Cloudflare -> CF-Connecting-IP; CloudFront (AWS) -> X-Forwarded-For;
    # UA = aplikasi klien (Dark Tunnel/injektor dkk.)
    xff = _header(request, "X-Forwarded-For")
    real_ip = (_header(request, "CF-Connecting-IP")
               or (xff.split(",")[0].strip() if xff else "")
               or ip)
    via_cdn = real_ip != ip
    # Edge IP untuk label CDN: IP yang menghubungi nginx (terjaring di X-Forwarded-For
    # terakhir yang ditambahkan nginx = IP Cloudflare/CloudFront yang masuk ke VPS).
    edge = ip
    if xff:
        for cand in reversed([x.strip() for x in xff.split(",")]):
            if cand and cand not in ("127.0.0.1", "localhost", "::1"):
                edge = cand
                break
    ua = _header(request, "User-Agent")[:200]
    # Port asli klien dari header X-Forwarded-Port (dikirim nginx reverse proxy)
    port_ws = _header(request, "X-Forwarded-Port") or str(WS_PORT)
    # geo gratis dari CDN: CloudFront -> CloudFront-Viewer-City/Country; Cloudflare -> CF-IPCountry
    city = _header(request, "CloudFront-Viewer-City")[:32]
    cc = _header(request, "CloudFront-Viewer-Country") or _header(request, "CF-IPCountry")
    if os.environ.get("NATSSH_DEBUG_REQ"):
        _log(f"DEBUG-REQ {ip}: {request[:800]!r}")
    if not _admit(real_ip, via_cdn):
        try:
            cur = _per_ip.get(real_ip, 0)
            _log(f"TOLAK {real_ip} (edge={edge}, per-ip={cur}, total={_total}, limit {MAX_PER_IP}/{MAX_TOTAL})")
        finally:
            try:
                client_socket.close()
            except OSError:
                pass
        return
    admitted = True
    try:
        ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_socket.settimeout(10)
        ssh_socket.connect(("127.0.0.1", SSH_PORT))
        ssh_socket.settimeout(None)
        if "HTTP" not in request and buf:
            # klien raw-SSH (tanpa upgrade HTTP): paket pertama masih di RAW buffer
            # — WAJIB diteruskan apa adanya (decode/re-encode str = merusak bytes)
            ssh_socket.sendall(buf)
        # idle-timeout dua arah: soket diem IDLE_TIMEOUT detik -> putus, slot lepas
        client_socket.settimeout(IDLE_TIMEOUT)
        ssh_socket.settimeout(IDLE_TIMEOUT)
        # TCP keepalive: bantu mencegah idle drop di jaringan/edge
        if TCP_HEARTBEAT:
            for sock in (client_socket, ssh_socket):
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                    if hasattr(socket, "TCP_KEEPIDLE"):
                        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 30)
                    if hasattr(socket, "TCP_KEEPINTVL"):
                        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
                    if hasattr(socket, "TCP_KEEPCNT"):
                        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
                except OSError:
                    pass
        cdn = _header(request, "X-CDN") or "Langsung"
        _log(f"JEMBAT {real_ip} (edge={edge}, ua='{ua}', total={_total})")
        conn = {"start": round(time.time(), 3), "ip": real_ip, "edge": edge,
                "ua": ua, "city": city, "cc": cc, "cdn": cdn, "port_ws": port_ws,
                "up": 0, "down": 0, "alasan": "natural"}
        with _lock:
            cid = next(_SEQ)
            _CONNS[cid] = conn
        _dump()
        t_back = threading.Thread(target=forward,
                                  args=(ssh_socket, client_socket, conn, "down"), daemon=True)
        t_back.start()
        forward(client_socket, ssh_socket, conn, "up")   # blok sampai koneksi selesai
        t_back.join(timeout=5)
    except OSError as exc:
        _log(f"GAGAL {ip}: {exc}")
        try:
            client_socket.close()
        except OSError:
            pass
    finally:
        if conn is not None:
            with _lock:
                _LAST.append({**conn, "end": round(time.time(), 3)})
                _CONNS.pop(cid, None)
            _dump()
            # catat pending untuk audit real-time
            try:
                with _lock:
                    pending=[]
                    if os.path.exists(PENDING_FILE):
                        try:
                            with open(PENDING_FILE) as f: pending=json.load(f)
                        except Exception:
                            pending=[]
                    # rotasi: buang pending >5 menit
                    nowt=time.time()
                    pending=[p for p in pending if nowt - p.get("start",nowt) <= 300]
                    pending.append({**conn, "end": round(time.time(),3)})
                    pending=pending[-200:]
                    tmp=PENDING_FILE+".tmp"
                    with open(tmp,"w") as f: json.dump(pending,f)
                    os.replace(tmp,PENDING_FILE)
            except Exception:
                pass
        if admitted:
            _release(real_ip, via_cdn)


def handle_direct_client(client_socket, peer_ip):
    """Handler untuk SSH direct via listener TCP polos (bukan WebSocket).

    Klien kirim banner SSH-2.0 langsung, tidak ada upgrade HTTP.
    Jika PROXY_PROTOCOL aktif, baca header PROXY dari nginx stream untuk IP asli.
    """
    global _total
    conn = None
    cid = 0
    admitted = False
    real_ip = peer_ip
    try:
        if PROXY_PROTOCOL:
            pp = _parse_proxy_protocol(client_socket)
            if pp:
                real_ip = pp[0]
        try:
            buf = client_socket.recv(8192)
        except OSError:
            try:
                client_socket.close()
            except OSError:
                pass
            return
        if not buf:
            try:
                client_socket.close()
            except OSError:
                pass
            return
        if not _admit(real_ip, False):
            try:
                cur = _per_ip.get(real_ip, 0)
                _log(f"TOLAK-DIRECT {real_ip} (peer={peer_ip}, per-ip={cur}, total={_total})")
            finally:
                try:
                    client_socket.close()
                except OSError:
                    pass
            return
        admitted = True
        try:
            ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            ssh_socket.settimeout(10)
            ssh_socket.connect(("127.0.0.1", SSH_PORT))
            ssh_socket.settimeout(None)
            ssh_socket.sendall(buf)  # kirim banner SSH klien apa adanya
            client_socket.settimeout(IDLE_TIMEOUT)
            ssh_socket.settimeout(IDLE_TIMEOUT)
            if TCP_HEARTBEAT:
                for sock in (client_socket, ssh_socket):
                    try:
                        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                        if hasattr(socket, "TCP_KEEPIDLE"):
                            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 30)
                        if hasattr(socket, "TCP_KEEPINTVL"):
                            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
                        if hasattr(socket, "TCP_KEEPCNT"):
                            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
                    except OSError:
                        pass
            _log(f"DIRECT {real_ip} (peer={peer_ip}, total={_total})")
            conn = {"start": round(time.time(), 3), "ip": real_ip, "edge": peer_ip,
                    "ua": "ssh-direct", "city": "", "cc": "", "cdn": "Langsung",
                    "port_ws": str(SSH_DIRECT_PORT), "up": 0, "down": 0, "alasan": "natural"}
            with _lock:
                cid = next(_SEQ)
                _CONNS[cid] = conn
            _dump()
            t_back = threading.Thread(target=forward,
                                      args=(ssh_socket, client_socket, conn, "down"), daemon=True)
            t_back.start()
            forward(client_socket, ssh_socket, conn, "up")
            t_back.join(timeout=5)
        except OSError as exc:
            _log(f"GAGAL-DIRECT {peer_ip}: {exc}")
            try:
                client_socket.close()
            except OSError:
                pass
    finally:
        if conn is not None:
            with _lock:
                _LAST.append({**conn, "end": round(time.time(), 3)})
                _CONNS.pop(cid, None)
            _dump()
        if admitted:
            _release(real_ip, False)


def accept_direct():
    """Loop accept listener SSH direct di port SSH_DIRECT_PORT (127.0.0.1 saja)."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", SSH_DIRECT_PORT))
    server.listen(64)
    _log(f"mulai direct: ssh={SSH_DIRECT_PORT} -> sshd {SSH_PORT}")
    while True:
        try:
            client, addr = server.accept()
            threading.Thread(target=handle_direct_client,
                             args=(client, addr[0]), daemon=True).start()
        except OSError as exc:
            _log(f"ACCEPT-DIRECT ERROR: {exc}")
            time.sleep(1)
        except Exception as exc:
            _log(f"ACCEPT-DIRECT ERROR: {exc}")
            time.sleep(1)


def _watchdog():
    """Bunuh koneksi yang melebihi MAX_CONN_AGE agar slot tidak menempel selamanya."""
    while True:
        time.sleep(60)
        if MAX_CONN_AGE <= 0:
            continue
        now = time.time()
        with _lock:
            stale = [cid for cid, c in _CONNS.items() if now - c.get("start", now) > MAX_CONN_AGE]
        for cid in stale:
            try:
                with _lock:
                    c = _CONNS.pop(cid, None)
                    if c is not None:
                        c["end"] = round(time.time(), 3)
                        c["alasan"] = "watchdog_timeout"
                        _LAST.append(c)
                _dump()
                _log(f"WATCHDOG hapus koneksi usia > {MAX_CONN_AGE}s cid={cid}")
            except Exception:
                pass


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", WS_PORT))
    server.listen(64)
    _log(f"mulai: ws={WS_PORT} -> ssh lokal {SSH_PORT}, limit {MAX_PER_IP}/ip, {MAX_TOTAL} total")
    t_wd = threading.Thread(target=_watchdog, daemon=True)
    t_wd.start()
    if SSH_DIRECT_ENABLED:
        t_direct = threading.Thread(target=accept_direct, daemon=True)
        t_direct.start()
    while True:
        try:
            client, addr = server.accept()
            threading.Thread(target=handle_client, args=(client, addr[0]), daemon=True).start()
        except OSError as exc:
            _log(f"ACCEPT ERROR: {exc}")
            time.sleep(1)
        except Exception as exc:
            _log(f"ACCEPT ERROR: {exc}")
            time.sleep(1)


if __name__ == "__main__":
    main()
