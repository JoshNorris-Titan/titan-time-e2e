#!/usr/bin/env bash
# verify-fixture-window-expiry.test.sh
#
# The E2E assignment window (FX_START_DATE - FX_END_DATE in lib/_fixtures.sh) must
# still have room ahead of it. Fails while there is time to act, not on the day it
# breaks.
#
# WHY THIS EXISTS. The window is a pair of hardcoded dates, currently
# 07/01/2026 - 12/31/2027, and lib/_fixtures.sh says what happens when the tests
# drive a week outside it: "the assignment exists but renders zero rows". That is
# not one red test. Every consultant, approval, HR and export step works through an
# assignment, so the whole suite goes red at once, on a date nobody has in mind,
# with a symptom (empty grids everywhere) that reads like a broken deployment or a
# wiped database rather than an expired constant. The cost is an emergency
# investigation of a product that is fine.
#
# WHY IT IS NOT FIXED BY MAKING THE DATE RELATIVE. The dates match the assignments
# ALREADY ON DEV -- lib/_fixtures.sh:125 -- and fx_reconcile compares by name and
# config, so quietly rolling the default forward would make every existing
# assignment look mismatched, and would still not extend the ones already saved on
# the environment. Extending the window is a deliberate act against dev data:
# update the assignments there, then move these constants to match. This test is the
# reminder to do it, early enough that it is routine.
#
# WHAT TO DO WHEN IT FAILS. Extend the E2E assignments on the target environment
# (Titan Manager -> Assignments), then update FX_END_DATE in lib/_fixtures.sh to
# match. Do not silence this by moving the constant alone -- the constant only
# governs assignments this suite CREATES, and the ones on dev are already saved.
#
# Nothing here drives a browser. It is a static contract check, like
# verify-lib-contract and verify-run-budget beside it.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"

# How much runway the window must keep. A quarter is enough to schedule the dev-data
# change without it becoming an interruption, and short enough that the test is not
# crying wolf for a year.
MIN_DAYS="${TT_FX_WINDOW_MIN_DAYS:-90}"

# Read the effective values the suite would actually use, honouring an env override,
# without running any fixture code. _fixtures.sh needs _login.sh first; both are
# proven to source cleanly under `set -u` by verify-lib-contract.
# shellcheck source=/dev/null
source "$TT_ROOT/lib/_login.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
source "$TT_ROOT/lib/_fixtures.sh" >/dev/null 2>&1

[ -n "${FX_END_DATE:-}" ] || { echo "FAIL: FX_END_DATE is unset after sourcing lib/_fixtures.sh"; exit 1; }

# MM/DD/YYYY is the load-bearing shape the date picker parses (TT-721). Convert to
# ISO for date arithmetic, and refuse anything that is not that shape rather than
# letting `date` guess -- a misread date here would report false reassurance.
case "$FX_END_DATE" in
  [0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]) ;;
  *) echo "FAIL: FX_END_DATE is not MM/DD/YYYY: '$FX_END_DATE'"; exit 1 ;;
esac
mm="${FX_END_DATE%%/*}"
rest="${FX_END_DATE#*/}"
dd="${rest%%/*}"
yyyy="${rest#*/}"
iso="$yyyy-$mm-$dd"

end_epoch="$(date -d "$iso" +%s 2>/dev/null)" \
  || { echo "FAIL: could not parse FX_END_DATE '$FX_END_DATE' as a date"; exit 1; }
now_epoch="$(date +%s)"
days_left=$(( (end_epoch - now_epoch) / 86400 ))

echo "  FX_START_DATE = ${FX_START_DATE:-<unset>}"
echo "  FX_END_DATE   = $FX_END_DATE  ($days_left day(s) from today)"

if [ "$days_left" -lt 0 ]; then
  echo "FAIL: the E2E assignment window EXPIRED $(( -days_left )) day(s) ago."
  echo "      Assignments still exist but render zero rows, which fails the suite"
  echo "      broadly and looks nothing like an expired date. See this file's header."
  exit 1
fi

if [ "$days_left" -lt "$MIN_DAYS" ]; then
  echo "FAIL: only $days_left day(s) of assignment window left (minimum $MIN_DAYS)."
  echo "      Extend the E2E assignments on the target environment, then update"
  echo "      FX_END_DATE in lib/_fixtures.sh to match. See this file's header."
  exit 1
fi

echo "PASS: verify-fixture-window-expiry — $days_left day(s) of assignment window remain"
