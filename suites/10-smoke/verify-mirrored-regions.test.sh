#!/usr/bin/env bash
# verify-mirrored-regions.test.sh
#
# Asserts that page content which exists as more than one copy has not drifted apart.
#
# WHY THIS EXISTS. The Studio Pro MCP server cannot read or write snippets -- it rejects
# the Pages$Snippet document type outright, and Pages$Layout with it. A screen that lives
# in a snippet is therefore a screen no agent can edit, and every change to it is hand
# work in Studio Pro. TT-724/TT-725 traded that permanent tooling wall for a duplication
# cost: the snippet is inlined into each calling page, and the copies are then meant to
# stay identical forever. "Meant to" is the weak part. This is the part that checks.
#
# The register lives in the model repo at docs/reference/mirrored-regions.json. It
# began with one region: the weekly timesheet grid, on Main.ConsultantDashboard (what a
# consultant fills in) and Main.CreateTimesheet (HR's rewrite tool). It holds more now;
# the register, not this comment, is the list.
#
# WHAT IT COMPARES. Not the DOM, and not the .mpr. Mendix compiles every page into a
# pretty-printed React module and the app serves it at /pages/<Module>.<Page>.js -- the
# whole widget tree with every caption, attribute path, conditional-visibility expression,
# nanoflow binding, allowed-roles list and CSS class. Two HTTP fetches and a normalized
# diff cover the entire region, which no amount of clicking through it would.
#
# So this needs no browser, no login and no seed data, and it runs identically against
# local, dev and acceptance. It is in 10-smoke because it is fast and because a drifted
# grid invalidates every consultant and HR scenario that runs after it.
#
# THE COMPARATOR LIVES IN A MODEL CHECKOUT, not here: tools/check_mirrors.py, which
# reads the register docs/reference/mirrored-regions.json from that same checkout.
# Until 2026-09-08 this repository was nested inside the Mendix working copy, so the
# comparator was simply ../tools/check_mirrors.py. It now sits BESIDE the model
# checkouts (main, main2, main3), and more than one of them can hold the comparator,
# so this script does not guess which: set TT_MODEL_DIR to the checkout whose register
# should be enforced -- the same variable verify-scheduled-event-config uses. Unset,
# it falls back to the parent directory, which only works in the old nested layout.
# Pick a checkout whose register matches what is deployed at TT_BASE_URL: a region
# registered there but not yet deployed reads as "could not check", not as a pass.
#
# CI checks this repo out on its own, with no model checkout at all -- hence the
# entry in ci-skip.txt. This script deliberately does NOT skip itself when the
# comparator is missing: a self-skip that exits 0 is indistinguishable from a pass,
# and this suite has been bitten by exactly that before.
#
# Env: TT_BASE_URL (the app to test). TT_MODEL_DIR (the model checkout holding the
# comparator and register). TT_MIRRORS_CHECKER overrides the comparator path outright.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"

BASE_URL="${TT_BASE_URL:-}"
if [ -z "$BASE_URL" ]; then
  echo "FAIL: verify-mirrored-regions — TT_BASE_URL is not set, so there is no app to read."
  exit 1
fi

MODEL="${TT_MODEL_DIR:-$(cd "$TT_ROOT/.." && pwd)}"
CHECKER="${TT_MIRRORS_CHECKER:-$MODEL/tools/check_mirrors.py}"
if [ ! -f "$CHECKER" ]; then
  echo "FAIL: verify-mirrored-regions — no comparator at $CHECKER"
  if [ -n "${TT_MIRRORS_CHECKER:-}" ]; then
    echo "      TT_MIRRORS_CHECKER names a file that does not exist."
  else
    if [ -n "${TT_MODEL_DIR:-}" ]; then
      echo "      TT_MODEL_DIR=$MODEL is not a model checkout that carries tools/check_mirrors.py."
    else
      echo "      TT_MODEL_DIR is not set, and the parent directory ($MODEL) is not a model"
      echo "      checkout. This repo no longer lives inside one."
    fi
    echo "      Set TT_MODEL_DIR to the Mendix model checkout whose register should be"
    echo "      enforced. Checkouts beside this repo that carry the comparator:"
    found=""
    for d in "$TT_ROOT"/../*/; do
      [ -f "$d/tools/check_mirrors.py" ] || continue
      echo "        TT_MODEL_DIR=\"$(cd "$d" && pwd)\""
      found=1
    done
    [ -n "$found" ] || echo "        (none found)"
  fi
  echo "      This step cannot run in CI, where no model is checked out; it is listed in"
  echo "      ci-skip.txt for that reason. Missing is a FAIL, never a skip."
  exit 1
fi
echo "  comparator: $CHECKER"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then PY="$candidate"; break; fi
done
if [ -z "$PY" ]; then
  echo "FAIL: verify-mirrored-regions — no python on PATH to run the comparator."
  exit 1
fi

# --self-test is not optional. Without it a green means "found no difference", which is
# also what a silently broken comparator reports; with it, the run has demonstrated that a
# one-sided edit still registers as drift before trusting the result.
echo "  comparing mirrored regions on $BASE_URL"
output="$("$PY" "$CHECKER" --base-url "$BASE_URL" --self-test 2>&1)"
status=$?
echo "$output" | sed 's/^/  /'

case "$status" in
  0)
    echo "PASS: verify-mirrored-regions — every mirrored region is in sync, and the"
    echo "      comparator proved it can still detect a one-sided edit."
    exit 0
    ;;
  1)
    echo "FAIL: verify-mirrored-regions — the copies of a mirrored region have DRIFTED."
    echo "      The diff above names the widget. A change was made to one page and not the"
    echo "      other; reconcile them rather than adjusting this test. See"
    echo "      docs/reference/MIRRORED-REGIONS.md in the model repo."
    exit 1
    ;;
  2)
    echo "FAIL: verify-mirrored-regions — the comparison could not be performed."
    echo "      This is NOT a pass. Usually one of: the app is unreachable, a region's"
    echo "      anchor widget was renamed (update mirrored-regions.json), a page has"
    echo "      lost its copy of the region entirely, or the model checkout's register"
    echo "      names a region that is not deployed at this URL yet (pick a TT_MODEL_DIR"
    echo "      that matches the deploy). A region that cannot be checked has"
    echo "      no guard at all, which is worse than one that has drifted — nothing will"
    echo "      say so again."
    exit 1
    ;;
  *)
    echo "FAIL: verify-mirrored-regions — comparator exited $status, which it should never do."
    exit 1
    ;;
esac
