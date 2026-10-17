#!/usr/bin/env python3
"""Compare two history.csv files (Swift vs C++ or N vs M workers), ignoring timing columns.
usage: compare_history.py a.csv b.csv [--rtol 1e-9]   exit 0 when every non-timing cell matches."""
import csv, sys
TIMING = {"wall_s", "sims_per_s", "simsec_per_wall_s"}
a, b = sys.argv[1], sys.argv[2]
rtol = float(sys.argv[sys.argv.index("--rtol") + 1]) if "--rtol" in sys.argv else 1e-9
ra, rb = list(csv.DictReader(open(a))), list(csv.DictReader(open(b)))
if len(ra) != len(rb): print(f"row count {len(ra)} vs {len(rb)}"); sys.exit(1)
worst, exact, bad = 0.0, True, 0
for i, (x, y) in enumerate(zip(ra, rb)):
    for k in x:
        if k in TIMING: continue
        if x[k] == y.get(k): continue
        exact = False
        try: fx, fy = float(x[k]), float(y[k])
        except ValueError: print(f"gen {i} {k}: {x[k]!r} vs {y.get(k)!r}"); bad += 1; continue
        rel = abs(fx - fy) / max(abs(fx), abs(fy), 1e-300)
        worst = max(worst, rel)
        if rel > rtol: bad += 1; print(f"gen {i} {k}: {fx} vs {fy} (rel {rel:.3g})") if bad < 10 else None
sims = lambda r: sum(float(z["evaluations"]) for z in r) / max(sum(float(z["wall_s"]) for z in r), 1e-9)
print(f"{'BIT-IDENTICAL' if exact else 'max rel diff %.3g' % worst}; rows {len(ra)}; sims/s {sims(ra):.1f} vs {sims(rb):.1f}")
sys.exit(1 if bad else 0)
