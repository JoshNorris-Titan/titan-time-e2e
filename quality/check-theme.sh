#!/usr/bin/env bash
# Lint the CUSTOM theme SCSS and compare against the recorded baseline.
#
#   ./tests/quality/check-theme.sh            # check against theme-baseline.json
#   ./tests/quality/check-theme.sh --update   # rewrite the baseline from this run
#   ./tests/quality/check-theme.sh --list     # print every finding, grouped by rule
#
# Companion to check-app.sh. That one runs Studio Pro's model consistency check;
# this one covers the half of the app the model check cannot see — the hand
# written stylesheets in theme/web and themesource/titan_theme/web.
#
# SCOPE: the two custom theme folders only. themesource/atlas_core and every
# other marketplace themesource are vendor code — linting them produces
# thousands of findings nobody is allowed to fix.
#
# The rules in .stylelintrc.json are not a generic style guide. Each was chosen
# because it catches a defect class that was actually found in the August 2026
# front-end audit — chiefly `no-duplicate-selectors`, which is the rule that
# would have caught .status-badge being declared three times with import order
# silently deciding the winner.
#
# Baseline semantics: this is a RATCHET, not a clean-desk rule. The theme starts
# with 178 known findings, most of them inside _legacy-rules.scss (the holding
# pen created when the duplicated rule blocks were consolidated). The gate fails
# on anything NEW, so the count can only go down. Lowering the baseline as rules
# migrate out of the holding pen is the intended workflow.
#
# stylelint is fetched on demand via npx — there is no node_modules to install
# and no package.json change. First run downloads it; later runs are cached.
#
# Exit: 0 = at or below baseline, 1 = regression (new findings), 2 = tooling problem.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASELINE="$HERE/theme-baseline.json"
OUT="$HERE/.last-theme-check.json"

STYLELINT_VER="${TT_STYLELINT_VER:-16.9.0}"
POSTCSS_SCSS_VER="${TT_POSTCSS_SCSS_VER:-4.0.9}"

MODE="${1:-check}"

command -v npx >/dev/null 2>&1 || { echo "FAIL: npx not on PATH (need Node >= 20)"; exit 2; }
[ -f "$ROOT/.stylelintrc.json" ] || { echo "FAIL: .stylelintrc.json not found at repo root"; exit 2; }

cd "$ROOT" || exit 2

# stylelint exits non-zero when it reports findings, which is normal here — the
# baseline decides pass/fail, not the exit code. Only a missing/!JSON report is
# a tooling failure. --output-file is used because the JSON formatter's stream
# is not reliably stdout across versions.
rm -f "$OUT"
npx --yes -p "stylelint@$STYLELINT_VER" -p "postcss-scss@$POSTCSS_SCSS_VER" \
    stylelint "theme/web/**/*.scss" "themesource/titan_theme/web/**/*.scss" \
    --formatter json --output-file "$OUT" >/dev/null 2>&1

if [ ! -s "$OUT" ]; then
  echo "FAIL: stylelint wrote no report. Re-run without the output redirect to see why."
  exit 2
fi

python - "$OUT" "$BASELINE" "$MODE" <<'PY'
import json, io, sys, os, collections

out, baseline_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

raw = io.open(out, encoding="utf-8").read().strip()
if not raw.startswith("["):
    print("FAIL: report is not JSON (stylelint likely errored)"); sys.exit(2)
report = json.loads(raw)

counts = collections.Counter()
detail = collections.defaultdict(list)
for f in report:
    name = os.path.basename(f.get("source", "?"))
    for w in f.get("warnings", []):
        key = "%s|%s" % (name, w["rule"])
        counts[key] += 1
        detail[w["rule"]].append("%s:%s  %s" % (name, w["line"], w["text"]))

total = sum(counts.values())

if mode == "--list":
    for rule in sorted(detail, key=lambda r: -len(detail[r])):
        print("\n== %s (%d)" % (rule, len(detail[rule])))
        for line in detail[rule]:
            print("   ", line)
    print("\nTOTAL: %d" % total)
    sys.exit(0)

if mode == "--update":
    io.open(baseline_path, "w", encoding="utf-8").write(
        json.dumps({"total": total, "counts": dict(sorted(counts.items()))}, indent=2) + "\n")
    print("Baseline updated: %d findings across %d file/rule pairs." % (total, len(counts)))
    sys.exit(0)

if not os.path.exists(baseline_path):
    print("FAIL: no baseline at %s - run with --update first." % baseline_path)
    sys.exit(2)

base = json.load(io.open(baseline_path, encoding="utf-8"))
bc = collections.Counter(base.get("counts", {}))

regressions = [(k, bc.get(k, 0), v) for k, v in counts.items() if v > bc.get(k, 0)]
improvements = [(k, bc[k], counts.get(k, 0)) for k in bc if counts.get(k, 0) < bc[k]]

if regressions:
    print("THEME LINT REGRESSION - %d new finding(s):\n" % sum(n - o for _, o, n in regressions))
    for k, o, n in sorted(regressions):
        fname, rule = k.split("|", 1)
        print("  %-34s %-46s %d -> %d" % (fname, rule, o, n))
        for line in detail[rule]:
            if line.startswith(fname + ":"):
                print("        %s" % line)
    print("\nRun --list to see everything, or --update if the increase is intended.")
    sys.exit(1)

msg = "OK: %d findings, at or below baseline (%d)." % (total, base.get("total", 0))
if improvements:
    msg += " %d file/rule pair(s) improved - consider --update to lock the gain in." % len(improvements)
print(msg)
sys.exit(0)
PY
