#!/usr/bin/env python3
"""Sanding waktu sesi sshd user <-> koneksi bridge natssh.

Input stdin : baris "user <start_epoch>" per sesi sshd (dari menu.sh ws_peruser).
Argumen    : conns.json lalu ws.log (fallback pra-patch).
Output     : per user -> sesi + IP asli + aplikasi + durasi + trafik.
Username SSH tak terbaca jembatan (terenkripsi post-KEX): korelasi -2..+10 dtk,
label kemungkinan.
"""
import datetime
import json
import re
import sys
import time

now = time.time()
conn_file, log_file = sys.argv[1], sys.argv[2]

pool = []
try:
    d = json.load(open(conn_file))
    for c in d.get("live", []):
        pool.append({**c, "_live": True})
    for c in d.get("last", []):
        pool.append({**c, "_live": False})
except (OSError, ValueError):
    pass

logconns = []  # fallback pra-patch: (start_epoch, ip, ua)
try:
    for line in open(log_file):
        m = re.match(
            r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) JEMBAT (\S+) \(edge=(\S+), ua='([^']*)'",
            line,
        )
        if m:
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp()
            logconns.append((t, m.group(2), m.group(4)))
except OSError:
    pass

raw = [ln.split() for ln in sys.stdin.read().splitlines() if ln.strip()]
counts: dict[str, int] = {}
for u, _ in raw:
    counts[u] = counts.get(u, 0) + 1
seen: set[int] = set()
cur = None
for user, ep in [(u, int(e)) for u, e in raw]:
    ep = int(ep)
    if user != cur:
        cur = user
        seen = set()
        print(f"{user} ({counts[user]} sesi)")
        print("  WAKTU     IP ASLI            APLIKASI             DURASI  UP/DOWN MB     STATUS")
    best = None
    bd = 99
    for c in pool:
        if id(c) in seen:
            continue
        dsec = ep - c["start"]
        if -2 <= dsec <= 10 and abs(dsec) < bd:
            bd = abs(dsec)
            best = c
    ip = ua = info = None
    if best:
        seen.add(id(best))
        st = best["start"]
        end = now if best["_live"] else best.get("end", st)
        m = int((end - st) // 60)
        s = int((end - st) % 60)
        info = (
            f"{m}m{s:02d}s  up {best['up']/1048576:.1f}MB  down {best['down']/1048576:.1f}MB  "
            + ("LIVE" if best["_live"] else "selesai " + time.strftime("%H:%M", time.localtime(end)))
        )
        ip, ua = best["ip"], best["ua"]
    else:
        for t, rip, rua in logconns:
            dsec = ep - t
            if -2 <= dsec <= 10 and abs(dsec) < bd:
                bd = abs(dsec)
                ip, ua = rip, rua
    if info:
        trafik = f"{best['up']/1048576:.1f}/{best['down']/1048576:.1f}"
        durasi = f"{m}m{s:02d}s"
        status = "LIVE" if best["_live"] else "selesai " + time.strftime("%H:%M", time.localtime(end))
        line = (f"  {time.strftime('%H:%M:%S', time.localtime(ep))}  {ip:<15}  "
                f"{(ua or '-')[:19]:<19}  {durasi:>6}  {trafik:>9}  {status}")
    else:
        line = (f"  {time.strftime('%H:%M:%S', time.localtime(ep))}  {ip or '?-':<15}  "
                f"{(ua or '(tanpa UA/tak via CF)')[:19]:<19}"
                f"{'pra-patch: durasi/trafik tak tersedia':>42}")
    print(line)
