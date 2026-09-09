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
# The register lives in the model repo at docs/reference/mirrored-regions.json. Today it
# holds one region: the weekly timesheet grid, on Main.ConsultantDashboard (what a
# consultant fills in) and Main.CreateTimesheet (HR's rewrite tool).
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
# THE COMPARATOR LIVES IN THE MODEL REPO, not here, and where that repo sits relative to
# this one CHANGED on 2026-09-08. This suite used to be nested inside the Mendix working
# copy, so a single `../tools/check_mirrors.py` always resolved. It now sits BESIDE the
# model checkouts instead of inside one:
#
#   Titan Time/
#     tests/    <- this repo
#     main/     <- a model checkout, holds tools/check_mirrors.py
#     main2/    <- ditto
#     main3/    <- ditto
#
# so `../tools/` is now an empty path and the old single candidate could never resolve.
# That is not a hypothetical: it silently took the only guard on the mirrored regions out
# of service, in a suite where this script is the region's ONLY guard, because CI skips it
# (ci-skip.txt) and the local run was the one place it ever ran.
#
# Resolution therefore tries several candidates and reports every one it looked at. The
# sibling glob deliberately does not hardcode main/main2/main3 -- any checkout name works,
# and the first match wins because all model checkouts on the same branch carry an
# identical comparator.
#
# CI checks this repo out on its own, where none of the candidates exist -- hence the entry
# in ci-skip.txt. This script deliberately does NOT skip itself when the checker is missing:
# a self-skip that exits 0 is indistinguishable from a pass, and this suite has been bitten
# by exactly that before.
#
# Env: TT_BASE_URL (the app to test). TT_MIRRORS_CHECKER overrides the checker path.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"

BASE_URL="${TT_BASE_URL:-}"
if [ -z "$BASE_URL" ]; then
  echo "FAIL: verify-mirrored-regions — TT_BASE_URL is not set, so there is no app to read."
  exit 1
fi

# Candidate order: explicit override, then the pre-2026-09-08 nested layout, then the
# current sibling layout. TT_MIRRORS_CHECKER short-circuits everything.
CHECKER=""
CHECKER_TRIED=""
if [ -n "${TT_MIRRORS_CHECKER:-}" ]; then
  CHECKER_CANDIDATES="$TT_MIRRORS_CHECKER"
else
  CHECKER_CANDIDATES="$TT_ROOT/../tools/check_mirrors.py"
  for sibling in "$TT_ROOT"/../*/tools/check_mirrors.py; do
    [ -f "$sibling" ] && CHECKER_CANDIDATES="$CHECKER_CANDIDATES
$sibling"
  done
fi

while IFS= read -r candidate; do
  [ -z "$candidate" ] && continue
  CHECKER_TRIED="$CHECKER_TRIED
        $candidate"
  if [ -f "$candidate" ]; then CHECKER="$candidate"; break; fi
done <<EOF
$CHECKER_CANDIDATES
EOF

if [ -z "$CHECKER" ]; then
  echo "FAIL: verify-mirrored-regions — no comparator found. Looked at:$CHECKER_TRIED"
  echo "      It lives in the MODEL repo (tools/check_mirrors.py). Since 2026-09-08 this"
  echo "      suite sits BESIDE the model checkouts rather than inside one, so the"
  echo "      comparator is at ../<checkout>/tools/check_mirrors.py. Point"
  echo "      TT_MIRRORS_CHECKER at it, or add this script to ci-skip.txt for runs where"
  echo "      no model repo is checked out."
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
    echo "      anchor widget was renamed (update mirrored-regions.json), or a page has"
    echo "      lost its copy of the region entirely. A region that cannot be checked has"
    echo "      no guard at all, which is worse than one that has drifted — nothing will"
    echo "      say so again."
    exit 1
    ;;
  *)
    echo "FAIL: verify-mirrored-regions — comparator exited $status, which it should never do."
    exit 1
    ;;
esac
