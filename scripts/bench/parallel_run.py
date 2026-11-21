#!/usr/bin/env python3
"""Compare 7zz -mx9 with two builds of squeeze7z-cli (Smart and Fast) on folders.

usage: parallel_run.py WORKDIR 7ZZ

WORKDIR must hold cli-old and cli-new (two squeeze7z-cli builds) and src/<name>/ for each input:
canterbury, headers, silesia, mixed, wallpapers. Writes WORKDIR/parallel.csv; every output is
extracted with 7zz and compared with its source (diff -r)."""
import csv, os, shutil, subprocess, sys, time
B, Z = sys.argv[1:3]
env = dict(os.environ, SQUEEZE7Z_7ZZ=Z)
def run(cmd, cwd=None):
    t = time.monotonic()
    p = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env)
    return p.returncode, time.monotonic() - t, p.stdout + p.stderr
w = csv.writer(open(f"{B}/parallel.csv", "w", newline="")); w.writerow(["id","tool","out_bytes","seconds","verify","strategy"])
for cid in ["canterbury","headers","silesia","mixed","wallpapers"]:
    src = f"{B}/src/{cid}"; od = f"{B}/out/{cid}"; shutil.rmtree(od, ignore_errors=True); os.makedirs(od)
    a = f"{od}/mx9.7z"; rc, t, _ = run([Z,"a","-t7z","-mx9","-snl","-y","-bb0","-bsp0",a,cid], cwd=f"{B}/src")
    w.writerow([cid,"7zz-mx9",os.path.getsize(a),f"{t:.1f}","",""]); os.remove(a)
    for name, cli, mode in [("old-smart","cli-old","smart"),("new-smart","cli-new","smart"),("new-fast","cli-new","fast")]:
        md = f"{od}/{name}"; os.makedirs(md)
        rc, t, o = run([f"{B}/{cli}","optimize","--mode",mode,"--out",md,src])
        strat = next((l.split("strategy:")[1].split(", trials")[0].strip() for l in o.splitlines() if "strategy:" in l), "")
        outs = [f for f in os.listdir(md) if f.endswith(".7z")]
        if rc or not outs: w.writerow([cid,name,"",f"{t:.1f}",f"fail {o[-200:]}",""]); continue
        f = f"{md}/{outs[0]}"; xd = f"{md}/x"; os.makedirs(xd)
        subprocess.run([Z,"x","-y","-bb0","-bsp0","-snld",f"-o{xd}",f], capture_output=True)
        v = subprocess.run(["diff","-r","--no-dereference",xd+"/"+cid,src], capture_output=True).returncode
        w.writerow([cid,name,os.path.getsize(f),f"{t:.1f}","identical" if v==0 else "DIFF",strat]); shutil.rmtree(md)
    print(cid, "done", flush=True)
