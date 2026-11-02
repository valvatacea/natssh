#!/usr/bin/env python3
"""Sanding waktu sesi sshd user <-> koneksi bridge natssh.

Input stdin : baris "user <start_epoch>" per sesi sshd (dari menu.sh ws_peruser).
Argumen    : conns.json lalu ws.log (fallback pra-patch).
Output     : per user bernomor -> baris sesi (IP asli, aplikasi, durasi, trafik,
             status, jalur CDN) + rekap live/total. Username SSH tak terbaca
             jembatan (terenkripsi post-KEX): korelasi -2..+10 dtk, kemungkinan.
"""
import datetime
import json
import os
import re
import sys
import time

os.environ["TZ"] = "Asia/Jakarta"
time.tzset()  # semua waktu tampil WIB (GMT+7)

C_CYAN = "\033[36m"
C_WHITE = "\033[37m"
C_DIM = "\033[2m"
C_RESET = "\033[0m"

now = time.time()
conn_file, log_file = sys.argv[1], sys.argv[2]
audit_file = sys.argv[3] if len(sys.argv) > 3 else None

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


def cdn_label(edge: str) -> str:
    # ponytail: heuristik rentang edge umum; upgrade ke daftar resmi bila perlu
    if edge.startswith(("52.", "99.", "18.", "13.32", "13.33", "3.5")):
        return "CloudFront"
    if edge.startswith(("104.", "172.64", "172.68", "172.69", "172.70", "172.71",
                        "188.114", "162.158", "141.101", "108.162", "190.93", "103.2")):
        return "Cloudflare"
    return f"proxy {edge}"


matched: list = []


def recap() -> None:
    if not matched:
        return
    live = sum(1 for c in matched if c["_live"])
    up = sum(c["up"] for c in matched) / 1048576
    down = sum(c["down"] for c in matched) / 1048576
    print(f"   {C_DIM}rekap: {live} live · total {up:.1f}\u2191{down:.1f}\u2193 MB{C_RESET}")
    matched.clear()


AUDIT_RE = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) SELESAI user=(\S+) ip=(\S+) "
    r"edge=(\S+) cc=(\S+) city=(\S+) dur=(\S+) up=([\d.-]+) down=([\d.-]+) ua=(.*)$"
)

riwayat = []
if audit_file:
    try:
        for ln in open(audit_file):
            m = AUDIT_RE.match(ln.rstrip("\n"))
            if m:
                riwayat.append(m.groups())
    except OSError:
        pass

raw = [ln.split() for ln in sys.stdin.read().splitlines() if ln.strip()]
counts: dict[str, int] = {}
for u, _ in raw:
    counts[u] = counts.get(u, 0) + 1

import itertools

users_order = []
for u, _ in raw:
    if u not in users_order:
        users_order.append(u)
uidx = itertools.count(1)   # offline dgn riwayat ikut bernomor lanjut

groups: dict[str, list] = {}   # riwayat dikelompokkan per akun
for r in riwayat:
    groups.setdefault(r[1], []).append(r)


def grup_riwayat(user):
    rows = groups.get(user)
    if not rows:
        return
    print(f"   {C_DIM}── riwayat {user}: {len(rows)} sesi (5 terakhir) ──{C_RESET}")
    for t, u, ip, edge, cc, city, dur, up, down, ua in rows[-5:]:
        jalur = f" {C_DIM}[{cdn_label(edge)}]{C_RESET}" if edge not in ("-", "") else ""
        geo = f" {C_DIM}{city}{(' ' + cc) if cc != '-' else ''}{C_RESET}" if city != "-" else ""
        print(f"     {t[11:]}   {ip:<16} {(ua or '-')[:14]:<14} {dur:>7} "
              f"{up}\u2191{down}\u2193{C_RESET}{jalur}{geo}")

seen: set[int] = set()
cur = None
for user, ep in [(u, int(e)) for u, e in raw]:
    if user != cur:
        recap()
        if cur is not None:
            grup_riwayat(cur)
        cur = user
        seen = set()
        print(f"{C_CYAN}{next(uidx)}\033[0m\033[1m) {user} ({counts[user]} sesi)\033[0m")

    wt = time.strftime("%H:%M:%S", time.localtime(ep))
    # kandidat dalam jendela; utamakan koneksi LIVE, seri = kedekatan waktu
    best = None
    bkey = None
    for c in pool:
        if id(c) in seen:
            continue
        dsec = ep - c["start"]
        if -2 <= dsec <= 10:
            key = (0 if c["_live"] else 1, abs(dsec))
            if bkey is None or key < bkey:
                bkey = key
                best = c

    if best and not best["_live"]:
        best = None   # koneksi sudah selesai -> jangan duplikat riwayat di seksi live
    if best:
        seen.add(id(best))
        matched.append(best)
        st = best["start"]
        end = now if best["_live"] else best.get("end", st)
        m = int((end - st) // 60)
        s = int((end - st) % 60)
        durasi = f"{m}m{s:02d}s"
        if best["_live"]:
            status = "\033[32mLIVE\033[0m"
        else:
            status = f"\033[33mselesai {time.strftime('%H:%M', time.localtime(end))}\033[0m"
        jalur = ""
        if best.get("edge") and best["ip"] != best["edge"]:
            jalur = f"  {C_DIM}[{cdn_label(best['edge'])}]{C_RESET}"
        geo = ""
        if best.get("city") or best.get("cc"):
            geo = f"  {C_DIM}{best.get('city') or ''}{(' ' + best['cc']) if best.get('cc') else ''}{C_RESET}"
        line = (f"   {wt} {C_WHITE}{best['ip']:<16}\033[0m{(best['ua'] or '-')[:14]:<14}"
                f"{durasi:>7} {best['up']/1048576:.1f}\u2191{best['down']/1048576:.1f}\u2193 {status}{jalur}{geo}")
    else:
        ip = ua = None
        bd = 99
        for t, rip, rua in logconns:
            dsec = ep - t
            if -2 <= dsec <= 10 and abs(dsec) < bd:
                bd = abs(dsec)
                ip, ua = rip, rua
        line = (f"   {wt}  {C_WHITE}{(ip or '?-'):<15}\033[0m {(ua or '(tanpa UA)')[:18]:<18}"
                f"  {C_DIM}(sesi basi/pra-patch: koneksi sudah lepas){C_RESET}")
    print(line)

recap()
if cur is not None:
    grup_riwayat(cur)

# akun offline yg punya riwayat — tetap tampil sbg blok bernomor sendiri
online = set(users_order)
for u in sorted(groups, key=lambda x: groups[x][-1][0], reverse=True):
    if u in online:
        continue
    print(f"{C_CYAN}{next(uidx)}{C_RESET}{C_BOLD}) {u} (offline){C_RESET}")
    grup_riwayat(u)
