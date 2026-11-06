from fastapi import FastAPI, Header, HTTPException
import json, os, subprocess

app = FastAPI(title="NATSSH API", version="0.1")
TOKEN = os.environ.get("NATSSH_API_TOKEN", "change-me")
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def auth(token: str | None):
    if token != TOKEN:
        raise HTTPException(status_code=401, detail="invalid token")


def sh(cmd: str):
    return subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)


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


@app.post("/accounts/{user}/suspend")
def suspend(user: str, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not user.isalnum():
        raise HTTPException(400, "invalid user")
    r = sh(f'source {BASE}/menu.sh; do_suspend "{user}"')
    return {"ok": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr}


@app.post("/accounts/{user}/unsuspend")
def unsuspend(user: str, x_api_token: str | None = Header(default=None)):
    auth(x_api_token)
    if not user.isalnum():
        raise HTTPException(400, "invalid user")
    r = sh(f'source {BASE}/menu.sh; do_unsuspend "{user}"')
    return {"ok": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr}
