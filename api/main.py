from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
import json, os, subprocess, re
from datetime import datetime, timedelta

import secrets
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = os.environ.get("NATSSH_API_TOKEN", "")
if not TOKEN or TOKEN == "change-me":
    tf = os.path.join(BASE, ".api_token")
    if os.path.exists(tf):
        TOKEN = open(tf).read().strip()
    else:
        TOKEN = secrets.token_urlsafe(48)
        with open(tf, "w") as f:
            f.write(TOKEN)
        # sync to .env files if present
        for envp in (os.path.join(BASE, "api", ".env"), "/root/natssh-bot/.env"):
            if os.path.exists(envp):
                lines = open(envp).read().splitlines()
                out = []
                found = False
                for ln in lines:
                    if ln.startswith("NATSSH_API_TOKEN="):
                        out.append(f"NATSSH_API_TOKEN={TOKEN}")
                        found = True
                    else:
                        out.append(ln)
                if not found:
                    out.append(f"NATSSH_API_TOKEN={TOKEN}")
                with open(envp, "w") as f:
                    f.write("\n".join(out) + "\n")
app = FastAPI(title="NATSSH API", version="0.2")

import logging
logging.basicConfig(filename=os.path.join(BASE, "api.log"), level=logging.INFO,
                    format="%(asctime)s %(message)s")


@app.middleware("http")
async def log_requests(request, call_next):
    ip = request.client.host if request.client else "-"
    token = request.headers.get("x-api-token", "-")
    response = await call_next(request)
    logging.info(f"{ip} {request.method} {request.url.path} status={response.status_code} token={token[:6]}...")
    return response


def auth(token):
    if token != TOKEN:
        raise HTTPException(status_code=401, detail="invalid token")


def sh(cmd):
    return subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)


def valid_user(u):
    return bool(re.fullmatch(r"[a-zA-Z0-9_]{3,32}", u))


def safe_token(v):
    return bool(re.fullmatch(r"[a-zA-Z0-9._-]+", v))


class AccountIn(BaseModel):
    user: str
    password: str
    days: int = 30


class LimitIn(BaseModel):
    limit: str


class RenewIn(BaseModel):
    days: int


class PasswordIn(BaseModel):
    password: str


class PortIn(BaseModel):
    port: str


class DomainIn(BaseModel):
    domain: str


@app.get("/status")
def status(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    ws = sh("systemctl is-active natssh-ws").stdout.strip()
    try:
        conns = json.load(open(os.path.join(BASE, "conns.json")))
        live = len(conns.get("live", []))
    except Exception:
        live = 0
    return {"ws": ws, "live_connections": live}

@app.get("/live")
def live_sessions(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    try:
        conns = json.load(open(os.path.join(BASE, "conns.json")))
        rows = conns.get("live", [])
    except Exception:
        rows = []
    return {"live": rows}


@app.get("/system")
def system(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    ram = sh("free -h | awk 'NR==2{print $3\"/\"$2}'").stdout.strip()
    cpu = sh("top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4}'").stdout.strip()
    disk = sh("df -h / | awk 'NR==2{print $3\"/\"$2\" (\"$5\")\"}'").stdout.strip()
    return {"ram": ram, "cpu": cpu + "%", "disk": disk}


@app.get("/ws_peak")
def ws_peak(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    peak = "0"
    tolak = "0"
    try:
        peak = sh("grep -o 'total=[0-9]*' /root/natssh/ws.log | cut -d= -f2 | sort -n | tail -1").stdout.strip() or "0"
        tolak = sh("grep -c 'TOLAK' /root/natssh/ws.log").stdout.strip() or "0"
    except Exception:
        pass
    cur_max = "30"
    try:
        cur_max = sh("systemctl show natssh-ws -p Environment --value 2>/dev/null | grep -o 'NATSSH_MAX_TOTAL=[0-9]*' | cut -d= -f2").stdout.strip() or "30"
    except Exception:
        pass
    return {"peak": peak, "tolak": tolak, "max_total": cur_max}
@app.get("/info")
def info(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    host = ""
    try:
        host = open(os.path.join(BASE, "host.conf")).read().strip()
    except Exception:
        pass
    wsport = ""
    try:
        wpid = sh("pgrep -f 'ws.py' | head -1").stdout.strip()
        if wpid:
            wsport = sh(f"ss -tlnp 2>/dev/null | grep 'pid={wpid},' | awk '{{print $4}}' | awk -F: '{{print $NF}}' | head -1").stdout.strip()
    except Exception:
        pass
    cfport = "2086"
    try:
        cfport = open(os.path.join(BASE, "port.conf")).read().strip() or cfport
    except Exception:
        pass
    # fallback: port.conf mungkin tidak ada; coba baca dari ... (tetap default)
    return {"host": host, "cf_port": cfport, "ws_port": wsport}


@app.get("/accounts")
def accounts(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    out = sh("awk -F: '$7==\"/bin/false\" {print $1}' /etc/passwd").stdout.split()
    res = []
    for u in out:
        lim = None
        p = os.path.join(BASE, "limits", u)
        if os.path.exists(p):
            lim = open(p).read().strip()
        res.append({"user": u, "limit": lim})
    return {"accounts": res}


@app.post("/accounts")
def create_account(body: AccountIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(body.user):
        raise HTTPException(400, "invalid user")
    if len(body.password) < 6:
        raise HTTPException(400, "password too short")
    if body.days < 1:
        raise HTTPException(400, "invalid days")
    if sh(f"id {body.user}").returncode == 0:
        raise HTTPException(400, "user exists")
    exp = (datetime.now() + timedelta(days=body.days)).strftime("%Y-%m-%d")
    r = sh(f"useradd -e {exp} -m -s /bin/false {body.user}")
    if r.returncode != 0:
        raise HTTPException(500, r.stderr)
    r2 = subprocess.run(["chpasswd"], input=f"{body.user}:{body.password}", text=True, capture_output=True)
    if r2.returncode != 0:
        raise HTTPException(500, r2.stderr)
    return {"ok": True, "user": body.user, "expired": exp}


@app.delete("/accounts/{user}")
def delete_account(user: str, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(user):
        raise HTTPException(400, "invalid user")
    sh(f"pkill -KILL -u {user} 2>/dev/null; sleep 0.5; userdel -r {user} 2>/dev/null; rm -f {BASE}/limits/{user}")
    return {"ok": True}


@app.get("/accounts/{user}/history")
def history(user: str, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(user):
        raise HTTPException(400, "invalid user")
    rows = []
    try:
        for line in open(os.path.join(BASE, "audit_sess.log")):
            if f"user={user} " in line:
                rows.append(line.strip())
    except FileNotFoundError:
        pass
    return {"user": user, "history": rows[-10:]}


@app.post("/accounts/{user}/limit")
def set_limit(user: str, body: LimitIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(user):
        raise HTTPException(400, "invalid user")
    if body.limit != "unlimited" and not body.limit.isdigit():
        raise HTTPException(400, "invalid limit")
    os.makedirs(os.path.join(BASE, "limits"), exist_ok=True)
    with open(os.path.join(BASE, "limits", user), "w") as f:
        f.write(body.limit)
    return {"ok": True, "limit": body.limit}


@app.post("/accounts/{user}/renew")
def renew(user: str, body: RenewIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(user) or body.days < 1:
        raise HTTPException(400, "invalid")
    r = sh(f"chage -E $(date -d '{body.days} days' +%Y-%m-%d) {user}")
    return {"ok": r.returncode == 0, "stderr": r.stderr}


@app.post("/accounts/{user}/password")
def change_password(user: str, body: PasswordIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(user) or len(body.password) < 6:
        raise HTTPException(400, "invalid")
    r = subprocess.run(["chpasswd"], input=f"{user}:{body.password}", text=True, capture_output=True)
    return {"ok": r.returncode == 0, "stderr": r.stderr}


@app.get("/audit")
def audit(user: str | None = None, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    rows = []
    try:
        for line in open(os.path.join(BASE, "audit_sess.log")):
            if user and f"user={user} " not in line:
                continue
            rows.append(line.strip())
    except FileNotFoundError:
        pass
    return {"rows": rows[-50:]}


@app.post("/config/port")
def set_port(body: PortIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not body.port.isdigit():
        raise HTTPException(400, "invalid port")
    with open(os.path.join(BASE, "port.conf"), "w") as f:
        f.write(body.port)
    return {"ok": True}


@app.post("/config/domain")
def set_domain(body: DomainIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    with open(os.path.join(BASE, "host.conf"), "w") as f:
        f.write(body.domain)
    return {"ok": True}


class SpeedIn(BaseModel):
    value: str


@app.post("/backup")
def backup(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    os.makedirs(os.path.join(BASE, "backups"), exist_ok=True)
    fn = f"backup-{datetime.now().strftime('%Y%m%d-%H%M%S')}.tar.gz"
    path = os.path.join(BASE, "backups", fn)
    r = sh(f"tar -czf {path} -C {BASE} .")
    return {"ok": r.returncode == 0, "file": fn, "stderr": r.stderr}


@app.post("/restore/{filename}")
def restore(filename: str, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if "/" in filename or ".." in filename:
        raise HTTPException(400, "invalid filename")
    path = os.path.join(BASE, "backups", filename)
    if not os.path.exists(path):
        raise HTTPException(404, "not found")
    r = sh(f"tar -xzf {path} -C {BASE}")
    return {"ok": r.returncode == 0, "stderr": r.stderr}


@app.post("/config/speed")
def set_speed(body: SpeedIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    with open(os.path.join(BASE, "speed.conf"), "w") as f:
        f.write(body.value)
    return {"ok": True}
@app.post("/udpgw/{port}/toggle")
def udpgw_toggle(port: int, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if port not in (7100, 7200, 7300, 7400, 7500):
        raise HTTPException(400, "invalid port")
    svc = f"natssh-udpgw@{port}.service"
    st = sh(f"systemctl is-active {svc}").stdout.strip()
    if st == "active":
        r = sh(f"systemctl disable --now {svc}")
        action = "disabled"
    else:
        r = sh(f"systemctl enable --now {svc}")
        action = "enabled"
    return {"ok": r.returncode == 0, "action": action, "stderr": r.stderr}
class BannerIn(BaseModel):
    text: str


@app.get("/banner")
def get_banner(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    try:
        return {"text": open("/etc/issue.net").read()}
    except FileNotFoundError:
        return {"text": ""}


@app.put("/banner")
def set_banner(body: BannerIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    with open("/etc/issue.net", "w") as f:
        f.write(body.text)
    return {"ok": True}
class HostCfIn(BaseModel):
    domain: str


class SuspendMinutesIn(BaseModel):
    minutes: int


@app.get("/config/host_cf")
def get_host_cf(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    try:
        return {"domain": open(os.path.join(BASE, "host_cf.conf")).read().strip()}
    except FileNotFoundError:
        return {"domain": ""}


@app.post("/config/host_cf")
def set_host_cf(body: HostCfIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    with open(os.path.join(BASE, "host_cf.conf"), "w") as f:
        f.write(body.domain)
    return {"ok": True}


@app.get("/config/suspend_minutes")
def get_suspend_minutes(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    try:
        return {"minutes": int(open(os.path.join(BASE, "suspend_minutes.conf")).read().strip())}
    except Exception:
        return {"minutes": 15}


@app.post("/config/suspend_minutes")
def set_suspend_minutes(body: SuspendMinutesIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if body.minutes < 1:
        raise HTTPException(400, "invalid")
    with open(os.path.join(BASE, "suspend_minutes.conf"), "w") as f:
        f.write(str(body.minutes))
    return {"ok": True}
class MaxTotalIn(BaseModel):
    value: int


class MaxPerIpIn(BaseModel):
    value: int


@app.post("/config/max_total")
def set_max_total(body: MaxTotalIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if body.value < 1:
        raise HTTPException(400, "invalid")
    sh(f"sed -i 's/Environment=NATSSH_MAX_TOTAL=[0-9]*/Environment=NATSSH_MAX_TOTAL={body.value}/' /etc/systemd/system/natssh-ws.service")
    sh("systemctl daemon-reload && systemctl restart natssh-ws")
    return {"ok": True}


@app.post("/config/max_per_ip")
def set_max_per_ip(body: MaxPerIpIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if body.value < 1:
        raise HTTPException(400, "invalid")
    # max_per_ip not currently in unit; append if missing
    unit = "/etc/systemd/system/natssh-ws.service"
    r = sh(f"grep -q 'NATSSH_MAX_PER_IP' {unit}")
    if r.returncode != 0:
        sh(f"sed -i '/Environment=NATSSH_WS_PORT=/a Environment=NATSSH_MAX_PER_IP={body.value}' {unit}")
    else:
        sh(f"sed -i 's/Environment=NATSSH_MAX_PER_IP=[0-9]*/Environment=NATSSH_MAX_PER_IP={body.value}/' {unit}")
    sh("systemctl daemon-reload && systemctl restart natssh-ws")
    return {"ok": True}
class RestartScheduleIn(BaseModel):
    cron: str


@app.post("/config/restart_schedule")
def set_restart_schedule(body: RestartScheduleIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    # remove old natssh-ws restart cron line, add new
    sh("crontab -l 2>/dev/null | grep -v 'natssh-ws' | crontab -")
    sh(f"(crontab -l 2>/dev/null; echo '{body.cron} /usr/bin/systemctl restart natssh-ws; /usr/bin/systemctl restart \"natssh-udpgw@*\" >/dev/null 2>&1') | crontab -")
    return {"ok": True}


@app.get("/logs")
def logs(file: str = "ws", lines: int = 50, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if file == "audit":
        path = os.path.join(BASE, "audit_sess.log")
    else:
        path = os.path.join(BASE, "ws.log")
    try:
        out = sh(f"tail -n {lines} {path}").stdout
    except Exception:
        out = ""
    return {"file": file, "lines": out.splitlines()}
class BannerTemplateIn(BaseModel):
    name: str


class AutoBackupIn(BaseModel):
    enabled: bool


@app.get("/banners")
def list_banners(x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    d = os.path.join(BASE, "banners")
    try:
        return {"banners": sorted(os.listdir(d))}
    except FileNotFoundError:
        return {"banners": []}


@app.post("/banner/apply")
def apply_banner(body: BannerTemplateIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    src = os.path.join(BASE, "banners", body.name)
    if not os.path.exists(src):
        raise HTTPException(404, "not found")
    sh(f"cp {src} /etc/issue.net")
    return {"ok": True}


@app.post("/config/autobackup")
def set_autobackup(body: AutoBackupIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    # remove existing autobackup cron line
    sh("crontab -l 2>/dev/null | grep -v 'autobackup.sh' | crontab -")
    if body.enabled:
        sh("(crontab -l 2>/dev/null; echo '0 2 * * * /root/natssh/autobackup.sh') | crontab -")
    return {"ok": True}
class SpeedApplyIn(BaseModel):
    iface: str
    up: str
    down: str


@app.post("/config/speed/apply")
def apply_speed(body: SpeedApplyIn, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not re.fullmatch(r"[a-zA-Z0-9._-]+", body.iface):
        raise HTTPException(400, "invalid iface")
    if not re.fullmatch(r"[0-9]+(kbit|mbit|gbit)?", body.up) or not re.fullmatch(r"[0-9]+(kbit|mbit|gbit)?", body.down):
        raise HTTPException(400, "invalid rate")
    iface = body.iface
    up = body.up
    down = body.down
    cmds = f"""
IFACE={iface}
tc qdisc del dev $IFACE root 2>/dev/null
tc qdisc del dev $IFACE ingress 2>/dev/null
tc qdisc add dev $IFACE root handle 1: htb default 30
tc class add dev $IFACE parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
tc class add dev $IFACE parent 1:1 classid 1:10 htb rate {up} ceil {up} prio 1 burst 32k
tc class add dev $IFACE parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit prio 2
tc qdisc add dev $IFACE parent 1:10 handle 10: fq_codel
tc qdisc add dev $IFACE parent 1:30 handle 30: fq_codel
tc filter add dev $IFACE parent 1: protocol ip prio 1 u32 match ip sport 22 0xffff flowid 1:10 2>/dev/null
tc filter add dev $IFACE parent 1: protocol ip prio 1 u32 match ip dport 22 0xffff flowid 1:10 2>/dev/null
echo "IFACE=$IFACE" > /root/natssh/speed.conf
echo "UP={up}" >> /root/natssh/speed.conf
echo "DOWN={down}" >> /root/natssh/speed.conf
echo "MODE=ssh-only" >> /root/natssh/speed.conf
"""
    r = sh(cmds)
    return {"ok": r.returncode == 0, "stderr": r.stderr}
@app.post("/accounts/{user}/suspend")
def suspend(user: str, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(user):
        raise HTTPException(400, "invalid user")
    r = sh(f'source {BASE}/menu.sh; do_suspend "{user}"')
    return {"ok": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr}


@app.post("/accounts/{user}/unsuspend")
def unsuspend(user: str, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not valid_user(user):
        raise HTTPException(400, "invalid user")
    r = sh(f'source {BASE}/menu.sh; do_unsuspend "{user}"')
    return {"ok": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr}
