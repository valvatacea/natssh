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
import fcntl
import os
import re
import subprocess
import sys
import time
import pwd

LOG = "/root/natssh/logs/autokill.log"
LOCK_FILE = "/root/natssh/logs/reap.lock"


def ensure_log_dir():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)


def acquire_lock():
    lock_fd = os.open(LOCK_FILE, os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError):
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") +
                    " - REAP: sudah berjalan, lewati.\n")
        sys.exit(0)
    return lock_fd


def kill_hantu(pid, user, sebab):
    """Bunuh proses sshd hantu. Coba SIGTERM dulu, baru SIGKILL."""
    subprocess.run(["kill", "-TERM", str(pid)], capture_output=True)
    time.sleep(0.5)
    try:
        os.kill(pid, 0)
        subprocess.run(["kill", "-KILL", str(pid)], capture_output=True)
        time.sleep(0.3)
    except OSError:
        # sudah mati setelah SIGTERM
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") +
                    f" - REAP: sesi hantu dibunuh, user={user} pid={pid} ({sebab})\n")
        return True
    try:
        os.kill(pid, 0)
        # masih hidup setelah SIGKILL
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") +
                    f" - REAP: GAGAL bunuh, user={user} pid={pid} ({sebab})\n")
        return False
    except OSError:
        # mati setelah SIGKILL
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") +
                    f" - REAP: sesi hantu dibunuh, user={user} pid={pid} ({sebab})\n")
        return True


def ss(filter_arg):
    r = subprocess.run(["ss", "-tnp", "state", "established", filter_arg],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return []
    return r.stdout.splitlines()


def has_active_connection(pid):
    """Cek apakah PID masih punya koneksi TCP established pada port 22."""
    r = subprocess.run(["ss", "-tnp", "state", "established", "sport = :22"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return False
    for line in r.stdout.splitlines():
        if re.search(rf"pid={pid}[,)]", line):
            return True
    return False


def main():
    ensure_log_dir()
    lock_fd = acquire_lock()
    try:
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
            try:
                if pwd.getpwnam(user_out).pw_shell != "/bin/false":
                    continue  # bukan akun jualan
            except KeyError:
                continue
            if kill_hantu(pid, user_out, "soket bridge mati"):
                reaped += 1

        # 3) proses sshd jualan TANPA pasangan TCP sama sekali (socket sudah lenyap) = hantu total
        for p in pwd.getpwall():
            if p.pw_uid < 1000 or p.pw_shell != "/bin/false":
                continue
            out = subprocess.run(["pgrep", "-u", p.pw_name, "sshd"],
                                  capture_output=True, text=True).stdout.split()
            for pid_str in out:
                if not pid_str.isdigit():
                    continue
                pid = int(pid_str)
                if pid in pids_seen:
                    continue
                # Cek apakah masih ada koneksi aktif pada port 22 untuk PID ini
                if has_active_connection(pid):
                    continue
                if kill_hantu(pid, p.pw_name, "tanpa TCP (socket lenyap)"):
                    reaped += 1
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") +
                    f" - REAP: selesai, {reaped} sesi dibunuh\n")
        return 0
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


if __name__ == "__main__":
    sys.exit(main())
