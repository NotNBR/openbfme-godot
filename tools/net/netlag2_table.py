#!/usr/bin/env python3
# usage: netlag2_table.py <out dir of netlag2_measure.sh batch> [frames=400]
# NETLAG-2 A/B table from the per-peer reports (out dir/<scenario>/r<slot>.txt): click-to-effect, run-ahead, early orders, and the game time lost
# (wall seconds beyond 400 frames at 5 Hz = 80 s: the real freezes; the stall counter also counts waits of a peer whose clock runs ahead)
import os,re,sys
out=sys.argv[1]; frames=int(sys.argv[2]) if len(sys.argv)>2 else 400
def rep(d):
    r={}
    for f in sorted(os.listdir(d)):
        if re.match(r'r\d+\.txt$',f):
            for line in open(os.path.join(d,f)):
                k,_,v=line.strip().partition(' '); r.setdefault(k,[]).append(v)
    return r
def g(v,k):
    m=re.search(k+r' (-?\d+)',v); return int(m.group(1)) if m else None
names=sorted({n[5:] if n.startswith('base-') else n for n in os.listdir(out)}, key=lambda n: os.path.getmtime(os.path.join(out,n)))
print('Game time lost: wall seconds beyond frames / 5 (includes the peers\' shutdown, about 0.2 s).\n')
print('| scenario | before: click->effect mean / p95 ms | after | before: run-ahead | after | before: game time lost s | after | early orders (after) | in sync |')
print('|---|---|---|---|---|---|---|---|---|')
for n in names:
    cells=[]
    R=[rep(os.path.join(out,x)) if os.path.isdir(os.path.join(out,x)) else {} for x in ('base-'+n,n)]
    for r in R:
        e=r.get('command_effect_ms',[]); m=[g(v,'mean') for v in e]; p=[g(v,'p95') for v in e]
        cells.append(f"{sum(m)//len(m)} / {max(p)}" if m else '-')
    for r in R: cells.append(r.get('run_ahead_frames',['-'])[0])
    for r in R:
        s=[float(v) for v in r.get('seconds',[])]; cells.append(f"{max(s)-frames/5:.1f}" if s else '-')

    cells.append(str(sum(int(v.split()[0]) for v in R[1].get('early_orders',[])) if R[1].get('early_orders') else '-'))
    # Sol r1: every peer of both runs wrote a full report (a final_hash) and they agree; a missing or failed peer is not "in sync"
    def full(d):
        p=os.path.join(out,d)
        if not os.path.isdir(p): return False
        reps=[f for f in os.listdir(p) if re.match(r'r\d+\.txt$',f)]
        rcs=[open(os.path.join(p,f)).read().strip() for f in os.listdir(p) if re.match(r'rc\d+\.txt$',f)]
        m=re.match(r'(?:base-)?(?:r|lan)(\d)',d)  # the players a scenario name says (r4-..., lan2): every one must have reported (Sol r2)
        want=int(m.group(1)) if m else len(reps)
        return len(reps)==want and len(rcs)==want and all(r=='0' for r in rcs) and all(any(l.startswith('final_hash ') for l in open(os.path.join(p,f))) for f in reps)
    ok=full('base-'+n) and full(n) and all(len(set(r.get('final_hash',[]))) == 1 and all(v=='0' for v in r.get('desyncs',[])) for r in R)
    cells.append('yes' if ok else 'NO')
    print('| '+n+' | '+' | '.join(cells)+' |')
