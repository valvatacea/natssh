#!/usr/bin/env python3
"""Reaper sesi sshd hantu (dipanggil autokill.sh tiap 2 menit).

Sesi sshd jalur bridge mati setengah (mis. restart ws.py saat aktif) meninggalkan
proses hidup dengan TCP ESTABLISHED tapi soket sisi bridge sudah TAK BERPEMILIK.
Proses hantu menggelembungkan hitungan perangkat. Reaper membandingkan:
  - port lokal soket python (ws.py) yang terhubung ke :22  = daftar "hidup"
  - pasangan loopback sshd :22 <-> port X
and kills sshd sessions (akun jualan, shell /bin/false) whose port X lacks a live
python owner. Sesi non-loopback (root via NAT 10.20.x) tak tersentuh.
"""
import re
import subprocess
import sys

LOG = "/root/natssh/logs/autokill.log"


def kill_hantu(pid, user, sebab):
    subprocess.run(["kill", str(pid)], capture_output=True)
    import time
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S") +
                f" - REAP: sesi hantu dibunuh, user={user} pid={pid} ({sebab})\n")


def ss(filter_arg):
    r = subprocess.run(["ss", "-tnp", "state", "established", filter_arg],
                       capture_output=True, text=True)
    return r.stdout.splitlines()


def main():
    # 1) port hidup: soket ws.py -> sshd (ada pemilik python)
    live = set()
    for line in ss("( dport = :22 )"):
        m = re.match(r"\S+\s+\S+\s+127\.0\.0\.1:(\d+)\s+127\.0\.0\.1:22\s+users:.*python", line)
        if m:
            live.add(m.group(1))

    # 2) sisi sshd: pasangan loopback yg port bridgenya tak hidup
    reaped = 0
    pids_seen = set()
    for line in ss("( sport = :22 )"):
        m = re.match(r"\S+\s+\S+\s+127\.0\.0\.1:22\s+127\.0\.0\.1:(\d+)\s+users:\(\(\"sshd\",pid=(\d+)", line)
        if not m:
            continue
        pids_seen.add(int(m.group(2)))
        port, pid = m.group(1), int(m.group(2))
        if port in live:
            continue
        try:
            with open(f"/proc/{pid}/loginuid") as f:  # cukup pastikan proc masih ada
                pass
        except OSError:
            continue
        user_out = subprocess.run(["ps", "-o", "user=", "-p", str(pid)],
                                  capture_output=True, text=True).stdout.strip()
        if not user_out:
            continue
        import pwd
        try:
            if pwd.getpwnam(user_out).pw_shell != "/bin/false":
                continue  # bukan akun jualan
        except KeyError:
            continue
        kill_hantu(pid, user_out, "soket bridge mati")

    # 3) proses sshd jualan TANPA pasangan TCP sama sekali (socket sudah lenyap) = hantu total
    import pwd as _pwd
    for p in _pwd.getpwall():
        if p.pw_uid < 1000 or p.pw_shell != "/bin/false":
            continue
        out = subprocess.run(["pgrep", "-u", p.pw_name, "sshd"],
                              capture_output=True, text=True).stdout.split()
        for pid in (int(x) for x in out if x.isdigit()):
            if pid in pids_seen:
                continue
            kill_hantu(pid, p.pw_name, "tanpa TCP (socket lenyap)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
