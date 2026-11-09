# Ide Future: Limit Speed SSH-WS via cgroup net_cls

Sebagai alternatif yang lebih robust daripada filter port WebSocket.

## Konsep
- net_cls cgroup memberi label (classid) ke semua paket proses dalam cgroup.
- tc filter cgroup membaca label, sehingga semua traffic ws.py (port apapun) bisa di-limit.

## Setup
1. mkdir /sys/fs/cgroup/net_cls/natssh
2. echo 0x100010 > /sys/fs/cgroup/net_cls/natssh/net_cls.classid  (label 1:10)
3. echo <pid_ws.py> > /sys/fs/cgroup/net_cls/natssh/cgroup.procs
4. tc filter add dev eth0 parent 1: cgroup flowid 1:10

## Catatan
- Perlu wrapper/systemd Slice agar ws.py masuk cgroup saat restart.
- Saat ini pakai filter port WebSocket (lebih sederhana, sudah diterapkan).