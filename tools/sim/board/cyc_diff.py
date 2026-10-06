#!/usr/bin/env python3
"""Compare the per-cycle bus logs of two runs of tb_nj_board.v (+cyclog=).

usage: cyc_diff.py <reference.cyc> <new.cyc> [clock_ns]

Each line: n KIND addr data tw=N TH=x dir=t bd=t dat=t wt=t, the times in
ns counted from the cycle's /MREQ or /IORQ (-1 = the event did not happen).

Checks (exit status 0 only if all hold):
  - both runs made the same bus cycles in the same order (kind, address,
    clock), so the bench took the same path;
  - every read at 3.58 and 5.37 MHz returned the same byte in both, and the
    same number of wait states; at 7.16 MHz the differences are only
    counted (New Juice does not serve every read in time there);
  - for each event (DATADIR, BUSDIR, data settled at the slot, /WAIT) it
    prints how much later the new run is: the distribution of the shift,
    in clocks of `clock_ns` (default 108 MHz = 9.259 ns).
"""
import sys, re, collections

def load(p):
    rows = []
    for ln in open(p):
        f = ln.split()
        if len(f) < 10:
            continue
        d = {'n': int(f[0]), 'kind': f[1], 'addr': f[2], 'data': f[3]}
        for kv in f[4:]:
            k, v = kv.split('=')
            d[k] = float(v) if k != 'tw' else int(v)
        rows.append(d)
    return rows

def speed(th):
    return '3,58' if th > 120 else ('5,37' if th > 80 else '7,16')

def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    clk = float(sys.argv[3]) if len(sys.argv) > 3 else 1000.0 / 108.0
    ok = True
    print(f"cyc_diff: {len(a)} cycles in {sys.argv[1]}, {len(b)} in {sys.argv[2]}")
    ka = [(r['kind'], r['addr'], speed(r['TH'])) for r in a]
    kb = [(r['kind'], r['addr'], speed(r['TH'])) for r in b]
    if ka != kb:
        ok = False
        for i, (x, y) in enumerate(zip(ka, kb)):
            if x != y:
                print(f"  [FAIL] the cycle sequences part at cycle {i + 1}: {x} / {y}")
                break
        else:
            print(f"  [FAIL] one run has more cycles ({len(a)} / {len(b)})")
    n = min(len(a), len(b))
    data_bad = collections.Counter(); tw_bad = collections.Counter(); seen = collections.Counter()
    shifts = collections.defaultdict(list)
    for i in range(n):
        x, y = a[i], b[i]
        if (x['kind'], x['addr']) != (y['kind'], y['addr']):
            continue
        sp = speed(x['TH'])
        key = (x['kind'], sp)
        seen[key] += 1
        reads = x['kind'] in ('IO_RD', 'IO_RDT', 'MEM_RD')
        if reads and x['data'] != y['data']:
            data_bad[key] += 1
            if sp != '7,16' and data_bad[key] <= 3:
                print(f"  [FAIL] cycle {x['n']} {x['kind']} {x['addr']} at {sp} MHz: {x['data']} / {y['data']}")
        if x['tw'] != y['tw']:
            tw_bad[key] += 1
            if sp != '7,16' and tw_bad[key] <= 3:
                print(f"  [FAIL] cycle {x['n']} {x['kind']} {x['addr']} at {sp} MHz: {x['tw']} / {y['tw']} wait states")
        for ev in ('dir', 'bd', 'dat', 'wt'):
            if x[ev] >= 0 and y[ev] >= 0:
                shifts[(x['kind'], sp, ev)].append(y[ev] - x[ev])
            elif (x[ev] >= 0) != (y[ev] >= 0):
                shifts[(x['kind'], sp, ev)].append(None)
    for key in sorted(seen):
        bad_d = data_bad[key]; bad_t = tw_bad[key]
        if key[1] != '7,16' and (bad_d or bad_t):
            ok = False
        print(f"  {key[0]:7s} {key[1]} MHz: {seen[key]:4d} cycles, {bad_d} with another byte, {bad_t} with other wait states")
    names = {'dir': 'DATADIR', 'bd': '/BUSDIR', 'dat': 'data at the slot', 'wt': '/WAIT'}
    print("  shift of each event (new - reference), in clocks of %.3f ns:" % clk)
    for key in sorted(shifts):
        v = shifts[key]
        miss = sum(1 for s in v if s is None)
        v = [s for s in v if s is not None]
        if not v:
            print(f"    {key[0]:7s} {key[1]} {names[key[2]]:17s}: only in one run ({miss})")
            continue
        h = collections.Counter(round(s / clk, 1) for s in v)
        hs = ', '.join(f"{k:+.1f}: {h[k]}" for k in sorted(h))
        print(f"    {key[0]:7s} {key[1]} {names[key[2]]:17s}: n={len(v)} min {min(v):+.3f} max {max(v):+.3f} ns  [{hs}]"
              + (f"  ({miss} only in one run)" if miss else ""))
    print("cyc_diff: " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)

main()
