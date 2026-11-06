#!/usr/bin/env python3
import json, os, sys, time
os.environ["TZ"]="Asia/Jakarta"; time.tzset()
DIR=os.path.dirname(os.path.abspath(__file__))
CONNS=os.path.join(DIR,"conns.json")
STATE=os.path.join(DIR,"audit_state.json")
LOG=os.path.join(DIR,"audit_sess.log")
user=sys.argv[1]
eps=[int(x) for x in sys.stdin.read().split() if x.isdigit()]
try:
    d=json.load(open(CONNS))
    pool=[{**c,"_live":True} for c in d.get("live",[])]
except Exception:
    pool=[]
state={}
try:
    state=json.load(open(STATE))
except Exception:
    state={}
now=time.time()
killed_keys=set()
lines=[]
for ep in eps:
    best=None; bkey=None
    for c in pool:
        if c.get("_used"): continue
        dsec=ep-c["start"]
        if -2<=dsec<=10:
            key=(0,abs(dsec))
            if bkey is None or key<bkey:
                bkey=key; best=c
    if best is None:
        continue
    best["_used"]=True
    key=str(best["start"])
    dur=int(now-best["start"])
    ip=best.get("ip","-"); edge=best.get("edge","-"); cc=best.get("cc","-")
    city=(best.get("city") or "-").replace(" ","-")
    up=best.get("up",0); down=best.get("down",0)
    ua=best.get("ua") or "-"
    v=state.get(key)
    if isinstance(v,dict): ua=v.get("ua",ua)
    lines.append(f"SELESAI user={user} ip={ip} edge={edge} cc={cc} city={city} dur={dur//60}m{dur%60:02d}s up={up/1048576:.1f} down={down/1048576:.1f} ua={ua}")
    killed_keys.add(key)
if not lines:
    lines.append(f"SELESAI user={user} ip=- edge=- cc=- city=- dur=0m00s up=- down=- ua=autokill")
with open(LOG,"a") as f:
    for ln in lines:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ")+ln+"\n")
for k in killed_keys:
    state.pop(k,None)
tmp=STATE+".tmp"
with open(tmp,"w") as f: json.dump(state,f)
os.replace(tmp,STATE)
