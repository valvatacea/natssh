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
C_BOLD = "\033[1m"
C_DIM = "\033[2m"
C_RESET = "\033[0m"

now = time.time()
conn_file, log_file = sys.argv[1], sys.argv[2]
audit_file = sys.argv[3] if len(sys.argv) > 3 else None
suspend_file = sys.argv[4] if len(sys.argv) > 4 else "/root/natssh/logs/suspended_history.log"

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
    return "-" if edge in ("127.0.0.1", "localhost", "::1") else f"proxy {edge}"


matched: list = []


def recap(user=None) -> None:
    # rekap PER AKUN: sesi live + seluruh riwayat tercatat (audit) — profil trafik utuh
    if not matched and not (user and groups.get(user)):
        return
    live_n = sum(1 for c in matched if c["_live"])
    lup = sum(c["up"] for c in matched) / 1048576
    ldown = sum(c["down"] for c in matched) / 1048576
    bag = []
    if matched:
        bag.append(f"{live_n} live (live {lup:.1f}\u2191{ldown:.1f}\u2193)")
    if user and groups.get(user):
        rows = groups[user]
        rup = sum(float(r[7]) for r in rows if r[7] not in ("-", ""))
        rdown = sum(float(r[8]) for r in rows if r[8] not in ("-", ""))
        bag.append(f"riwayat {len(rows)} sesi ({rup:.1f}\u2191{rdown:.1f}\u2193)")
    if bag:
        print(f"   {C_DIM}rekap: {' · '.join(bag)} MB{C_RESET}")
    matched.clear()


AUDIT_RE = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) SELESAI user=(\S+) ip=(\S+) "
    r"edge=(\S+) cc=(\S+) city=(\S+) dur=(\S+) up=([\d.-]+) down=([\d.-]+) ua=(.*?)(?:cdn=(\S+))?(?: port_ws=(\S+))?(?: alasan=(\S+))?$"
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

# riwayat suspend/unsuspend per akun
suspend_events: dict[str, list] = {}
try:
    for ln in open(suspend_file):
        m = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) - (SUSPEND|UNSPEND): (\S+)", ln)
        if m:
            suspend_events.setdefault(m.group(3), []).append((m.group(1), m.group(2)))
except OSError:
    pass


def grup_riwayat(user):
    rows = groups.get(user)
    if not rows:
        pass
    # print session rows if any
    if rows:
        print(f"   {C_DIM}── riwayat {user}: {len(rows)} sesi (5 terakhir) ──{C_RESET}")
        for r in rows[-5:]:
            t, u, ip, edge, cc, city, dur, up, down, ua = r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]
            cdn = r[10] if len(r) > 10 else "-"
            port_ws = r[11] if len(r) > 11 else "-"
            alasan = r[12] if len(r) > 12 else "-"
            # cdn: prioritas field dari log, fallback heuristik edge
            _cdn = cdn if cdn and cdn != "-" else (cdn_label(edge) if edge and edge != "-" else "")
            jalur = f" {C_DIM}[{_cdn}]{C_RESET}" if _cdn and _cdn != "-" else ""
            geo = f" {C_DIM}{city}{(' ' + cc) if cc != '-' else ''}{C_RESET}" if city != "-" or cc != "-" else ""
            port_info = f" {C_DIM}ws:{port_ws}{C_RESET}" if port_ws and port_ws != "-" else ""
            print(f"     {t[11:]}   {ip:<16} {dur:>7} "
                  f"{up}\u2191{down}\u2193{C_RESET}{jalur}{geo}{port_info}")
            print(f"              {C_DIM}UA: {ua or '-'}{C_RESET}")
            print(f"              {C_DIM}Alasan: {alasan}{C_RESET}")
    # suspend/unsuspend events
    evs = suspend_events.get(user)
    if evs:
        print(f"   {C_DIM}── suspend/unsuspend {user}: {len(evs)} kejadian (5 terakhir) ──{C_RESET}")
        for t, kind in evs[-5:]:
            print(f"     {t[11:]}   {kind}")
            # tampilkan detail sesi terkait dari audit_sess.log (jika ada)
            try:
                ev_ts = datetime.datetime.strptime(t, "%Y-%m-%d %H:%M:%S").timestamp()
            except ValueError:
                ev_ts = None
            if ev_ts is not None:
                for r in groups.get(user, []):
                    try:
                        r_ts = datetime.datetime.strptime(r[0], "%Y-%m-%d %H:%M:%S").timestamp()
                    except ValueError:
                        continue
                    if abs(r_ts - ev_ts) <= 120:
                        print(f"       {C_DIM}-> {r[2]} {r[9][:40]} dur={r[6]} up={r[7]} down={r[8]}{C_RESET}")

seen: set[int] = set()
cur = None
for user, ep in [(u, int(e)) for u, e in raw]:
    if user != cur:
        recap(cur)
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
            status = f"\033[32mLIVE\033[0m \033[33m{time.strftime('%H:%M', time.localtime(end))}\033[0m"
        # Jalur CDN: prioritas field cdn dari ws.py, fallback heuristik edge
        _cdn = best.get("cdn") or ""
        if not _cdn or _cdn == "-":
            _cdn = cdn_label(best.get("edge", "")) if best.get("edge") else ""
        jalur = f"  {C_DIM}[{_cdn}]{C_RESET}" if _cdn and _cdn != "-" else ""

        # Geo: kota + kode negara
        _city = best.get("city") or "-"
        _cc = best.get("cc") or "-"
        geo = ""
        if _city != "-" or _cc != "-":
            geo = f"  {C_DIM}{_city}{(' ' + _cc) if _cc != '-' else ''}{C_RESET}"

        # Port WS
        _pw = best.get("port_ws") or "-"
        port_info = f"  {C_DIM}ws:{_pw}{C_RESET}" if _pw != "-" else ""

        line = f"   {wt} {C_WHITE}{best['ip']:<16}{C_RESET}  {durasi:>7} {best['up']/1048576:.1f}\u2191{best['down']/1048576:.1f}\u2193 {status}{jalur}{geo}{port_info}"
        extra_ua = best.get('ua') or '-'
    else:
        # Tidak ada kecocokan di conns.json, tapi proses sshd masih hidup menurut ps
        line = f"   {wt} {C_WHITE}??.?.?.?{C_RESET:<16}     ??m??s ?↑?↓ {C_DIM}live (ws tidak terdeteksi){C_RESET}"
        extra_ua = '-'

    print(line)
    print(f"              {C_DIM}UA: {extra_ua}{C_RESET}")

recap(cur)
if cur is not None:
    grup_riwayat(cur)

# akun offline yg punya riwayat — tetap tampil sbg blok bernomor sendiri
online = set(users_order)
for u in sorted(groups, key=lambda x: groups[x][-1][0], reverse=True):
    if u in online:
        continue
    print(f"{C_CYAN}{next(uidx)}{C_RESET}{C_BOLD}) {u} (offline){C_RESET}")
    recap(u)
    grup_riwayat(u)
