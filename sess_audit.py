#!/usr/bin/env python3
"""Audit sesi per user (cron tiap 2 menit).

Cara kerja: selagi sesi sshd user masih hidup, sandingkan waktu proses dengan
koneksi bridge (conns.json) — sama seperti menu Monitoring>7 — lalu catat:
  MULAI    user ip ua kota      (sesi baru terlihat pertama kali)
  SELESAI  user ip durasi trafik (koneksi tak lagi live)
Ke unik-nya: username tak pernah terbaca jembatan (SSH terenkripsi), jadi
riwayat per-user hanya bisa dibangun dengan AUGMENTASI selagi sesi hidup.

Batas (ponytail): sesi lebih pendek dari interval cron (±2 mnt) bisa lolos tak
tercatat; upgrade: panggil dari hook putusnya ws.py bila perlu.
"""
import json
import os
import pwd
import subprocess
import sys
import time

os.environ["TZ"] = "Asia/Jakarta"
time.tzset()

DIR = os.path.dirname(os.path.abspath(__file__))
CONNS = os.path.join(DIR, "conns.json")
LOG = os.path.join(DIR, "audit_sess.log")
STATE = os.path.join(DIR, "audit_state.json")
MAX_LOG = 512_000


def rotasi():
    if os.path.exists(LOG) and os.path.getsize(LOG) > MAX_LOG:
        os.replace(LOG, LOG + ".old")


def catat(msg):
    rotasi()
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")


def akun_jualan():
    return [p.pw_name for p in pwd.getpwall()
            if p.pw_uid >= 1000 and p.pw_shell == "/bin/false"]


def sesi_start(user):
    out = subprocess.run(["pgrep", "-u", user, "sshd"],
                         capture_output=True, text=True).stdout.split()
    eps = []
    for pid in out:
        st = subprocess.run(["ps", "-o", "lstart=", "-p", pid],
                            capture_output=True, text=True).stdout.strip()
        if st:
            eps.append((user, st))
    return eps


def main():
    now = time.time()
    # korelasi sama seperti ws_match.py: LIVE-first, jendela -2..+10 dtk
    pool = []
    try:
        d = json.load(open(CONNS))
        for c in d.get("live", []):
            pool.append({**c, "_live": True})
        for c in d.get("last", []):
            pool.append({**c, "_live": False})
    except (OSError, ValueError):
        pool = []

    state = {}
    try:
        state = json.load(open(STATE))
    except (OSError, ValueError):
        pass

    terlihat = {}
    live_starts = {str(c["start"]) for c in pool if c["_live"]}
    for user in akun_jualan():
        for u, st in sesi_start(user):
            try:
                ep = time.mktime(time.strptime(st, "%a %b %d %H:%M:%S %Y"))
            except ValueError:
                continue
            best = None
            bkey = None
            for c in pool:
                dsec = ep - c["start"]
                if -2 <= dsec <= 10:
                    key = (0 if c["_live"] else 1, abs(dsec))
                    if bkey is None or key < bkey:
                        bkey = key
                        best = c
            if best is not None:
                terlihat[str(best["start"])] = best
                key = str(best["start"])
                if key not in state and best["_live"]:
                    # simpan dulu, catat SATU baris utuh saat sesi selesai
                    state[key] = {"user": user, "ip": best["ip"],
                                  "ua": best.get("ua") or "-",
                                  "city": (best.get("city") or "-").replace(" ", "-"),
                                  "cc": best.get("cc") or "-",
                                  "edge": best.get("edge") or "-"}

    # koneksi yang hilang dari live -> SATU baris SELESAI lengkap
    for key in list(state):
        if key in live_starts:
            continue  # masih live — jangan catat apalagi (race dump/cron)
        v = state[key]
        if isinstance(v, str):          # state format lama: hanya username
            v = {"user": v, "ip": "-", "ua": "-", "city": "-", "cc": "-", "edge": "-"}
        c = terlihat.get(key)
        if c is None:
            c = next((x for x in pool if str(x["start"]) == key and not x["_live"]), None)
        if c is None:
            # hilang total (mis. bridge restart) — best-effort durasi saja
            dur = now - float(key)
            catat(f"SELESAI user={v['user']} ip={v['ip']} edge={v['edge']} cc={v['cc']} "
                  f"city={v['city']} dur={int(dur//60)}m{int(dur%60):02d}s up=- down=- ua={v['ua']}")
            del state[key]
            continue
        dur = int(now - c["start"])
        catat(f"SELESAI user={v['user']} ip={v['ip']} edge={v['edge']} cc={v['cc']} "
              f"city={v['city']} dur={int(dur//60)}m{int(dur%60):02d}s "
              f"up={c['up']/1048576:.1f} down={c['down']/1048576:.1f} ua={v['ua']}")
        del state[key]

    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
