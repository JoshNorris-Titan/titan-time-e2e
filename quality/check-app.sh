#!/usr/bin/env bash
# Run Studio Pro's own consistency check (errors / warnings / deprecations /
# best-practice) from the command line and compare it against the recorded
# baseline.
#
#   ./tests/quality/check-app.sh            # check against baseline.json
#   ./tests/quality/check-app.sh --update   # rewrite baseline.json from this run
#   ./tests/quality/check-app.sh --list     # print every finding, grouped by code
#
# This is the SAME engine as Studio Pro's Errors pane — `mx check` from the
# version-matched toolset. It reads the .mpr ON DISK, i.e. the LAST SAVE, so
# unsaved Studio Pro edits are invisible here. `mcp__mendix__ped_check_errors`
# is the live equivalent, but it is per-document and reports errors only.
#
# Marketplace warnings (Email_Connector, WorkflowCommons, Atlas_*, MxModelReflection,
# ...) are suppressed via titan-time.suppressions.json — 65 of them as of the
# baseline. They are not ours to fix and they drown the ~38 that are.
#
# Exit: 0 = at or below baseline, 1 = regression (new findings), 2 = tooling problem.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MPR="${TT_MPR:-$ROOT/Titan Timee.mpr}"
MX="${TT_MX_EXE:-C:/Program Files/Mendix/11.12.2/modeler/mx.exe}"
SUPPRESS="$HERE/titan-time.suppressions.json"
BASELINE="$HERE/baseline.json"
OUT="$HERE/.last-check.json"
LOG="$HERE/.last-check.txt"

MODE="${1:-check}"

[ -f "$MX" ]  || { echo "FAIL: mx toolset not found at $MX (set TT_MX_EXE)"; exit 2; }
[ -f "$MPR" ] || { echo "FAIL: .mpr not found at $MPR (set TT_MPR)"; exit 2; }

# NOTE: -p and -b are mutually exclusive; -b already includes the performance checks.
# NOTE: never pipe this through head/tail — you lose mx's exit code.
"$MX" check "$MPR" "$SUPPRESS" -w -d -b -j "$OUT" > "$LOG" 2>&1
MX_STATUS=$?
if [ ! -s "$OUT" ]; then
  echo "FAIL: mx check wrote no JSON (exit $MX_STATUS). Log:"; tail -20 "$LOG"; exit 2
fi

# A malformed suppression rule is NOT rejected - it silently matches everything. Probing three
# plausible-but-wrong rule shapes each suppressed 98 of 99 warnings. So the count is checked below.
SUPPRESSED=$(grep -oE '[0-9]+ warnings were suppressed' "$LOG" | grep -oE '^[0-9]+' | tail -1)
SUPPRESSED="${SUPPRESSED:-0}"

python3 - "$OUT" "$BASELINE" "$MODE" "$SUPPRESSED" <<'PY'
import json, sys, collections, os

out, baseline_path, mode, suppressed = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = json.load(open(out, encoding='utf-8-sig'))

def counts(doc):
    c = collections.Counter()
    for sec in ('errors', 'warnings', 'deprecations'):
        for item in doc.get(sec) or []:
            c[f"{sec}:{item['code']}"] += 1
    for rec in (doc.get('performance') or {}).get('recommendations') or []:
        c[f"best-practice:{rec['code']}"] += 1
    return c

def where(item):
    out = []
    for l in item.get('locations') or []:
        out.append(f"{l.get('module-name','?')} / {l.get('document-name','')} / {l.get('element-name','')}".rstrip(' /'))
    return out or ['(project)']

cur = counts(d)
tot = {s: len(d.get(s) or []) for s in ('errors', 'warnings', 'deprecations')}
tot['best-practice'] = len((d.get('performance') or {}).get('recommendations') or [])
print(f"errors {tot['errors']}  warnings {tot['warnings']}  deprecations {tot['deprecations']}  best-practice {tot['best-practice']}")

if mode == '--list':
    items = [(f"{sec}:{i['code']}", i['message'], w)
             for sec in ('errors', 'warnings', 'deprecations')
             for i in d.get(sec) or [] for w in where(i)]
    items += [(f"best-practice:{r['code']}", r['message'], w)
              for r in (d.get('performance') or {}).get('recommendations') or [] for w in where(r)]
    for key in sorted({i[0] for i in items}):
        rows = [i for i in items if i[0] == key]
        print(f"\n{key}  ({len(rows)})")
        for _, msg, loc in rows:
            print(f"    {loc}\n        {msg}")
    sys.exit(0)

if mode == '--update':
    json.dump({'totals': tot, 'by_code': dict(cur), 'suppressed': suppressed}, open(baseline_path, 'w'), indent=2, sort_keys=True)
    print(f"baseline written to {os.path.basename(baseline_path)}")
    sys.exit(0)

if not os.path.exists(baseline_path):
    print("no baseline.json — run with --update to record one"); sys.exit(2)

baseline = json.load(open(baseline_path))
base = collections.Counter(baseline['by_code'])
exp_sup = baseline.get('suppressed')
if exp_sup is not None and suppressed > exp_sup:
    print("")
    print(f"FAIL: {suppressed} warnings suppressed, baseline expects {exp_sup}.")
    print("A malformed suppression rule matches EVERYTHING rather than being rejected - check")
    print("tests/quality/titan-time.suppressions.json before trusting any of the numbers above.")
    sys.exit(1)
worse = {k: (base.get(k, 0), v) for k, v in cur.items() if v > base.get(k, 0)}
better = {k: (base[k], cur.get(k, 0)) for k in base if cur.get(k, 0) < base[k]}

for k, (was, now) in sorted(better.items()):
    print(f"  improved  {k}: {was} -> {now}")
for k, (was, now) in sorted(worse.items()):
    print(f"  REGRESSED {k}: {was} -> {now}")
    for sec, code in [k.split(':', 1)]:
        pool = ((d.get('performance') or {}).get('recommendations') or []) if sec == 'best-practice' else (d.get(sec) or [])
        for i in [x for x in pool if x['code'] == code]:
            for loc in where(i):
                print(f"                {loc}")

if worse:
    print("\nFAIL: new findings above baseline")
    sys.exit(1)
print("\nOK: at or below baseline" + (" (baseline is now stale - rerun with --update)" if better else ""))
PY
