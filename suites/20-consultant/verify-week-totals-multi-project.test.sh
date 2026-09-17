#!/usr/bin/env bash
# The day-column totals and the week total equal the sum of the rows beneath them.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.SUB_Timesheet_RecalcAll recomputes the per-day column sums
# and the week total from the individual entries. The suite asserts on
# txtRowTotal (verify-consultant-line-items, tt692693-b1) and on line totals, but
# the day-column figures (txtTotalMon..txtTotalSat) and txtWeekTotal are asserted
# NOWHERE - and those are the numbers a consultant actually looks at before
# pressing Submit. The number the person signs off on is the one nothing checks.
#
# It is written for two projects on purpose: with one row a column total is
# trivially equal to the single cell beneath it and a broken sum would still pass.
# Two rows make the addition real.
#
# WHAT IT ASSERTS
#   A. at least two editable rows, fatal otherwise, for the reason above;
#   B. after a server round trip, txtTotalMon equals the sum of the Monday cells;
#   C. txtWeekTotal equals the sum of every cell entered.
#
# THE ROUND TRIP MATTERS. The totals are recomputed server-side, so reading them
# straight after typing can catch the client's optimistic value rather than the
# model's. tt_refetch_week re-queries the week WITHOUT leaving it - a plain reload
# lands on today's week, which is a different week and a different set of numbers.
#
# Consumes: one fresh week, left in Draft.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"

CUSER="${TT_TOT_USER:-e2e_consultant}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

tot_cells()  { playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input').length)" 2>/dev/null | _tt_eval_str; }
tot_set()    { tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, $1)" "$2"; }
tot_read()   { playwright-cli eval "() => { const e=document.querySelector('.mx-name-$1'); return e ? (e.innerText||'').trim() : '__MISSING__'; }" 2>/dev/null | _tt_eval_str; }
tot_num()    { printf '%s' "$1" | tr -d ' ,' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1; }
tot_eq()     { awk -v a="$1" -v b="$2" 'BEGIN{ exit (a+0==b+0) ? 0 : 1 }'; }

tt_login "$CUSER" "My Timesheets"
tt_goto_fresh_week "E2E Manager Approval" || tt_fail "no fresh week was reachable for '$CUSER'"
WEEK="$(tt_week_label)"

N="$(tot_cells)"
case "$N" in ''|*[!0-9]*) tt_fail "could not count Monday cells in week $WEEK (read: [$N])" ;; esac
[ "$N" -ge 2 ] || tt_fail "week $WEEK shows $N editable row(s); this test needs TWO, or a column total is trivially its single cell and a broken sum still passes"
note "week $WEEK, $N editable row(s)"

# Two values that cannot be confused with each other or with their sum.
A_VAL=3.25
B_VAL=4.5
EXPECT_MON=7.75

tot_set 1 "$A_VAL"
tot_set 2 "$B_VAL"
tt_commit_focused >/dev/null 2>&1 || true
sleep 3
tt_refetch_week >/dev/null 2>&1 || note "note: tt_refetch_week did not report success; totals may be the client's optimistic values"
sleep 2

# ------------------------------------------------------------------ B. column total
RAW_MON="$(tot_read txtTotalMon)"
case "$RAW_MON" in
  __MISSING__) bad "B: txtTotalMon is not on the page" ;;
  *)
    GOT_MON="$(tot_num "$RAW_MON")"
    if [ -n "$GOT_MON" ] && tot_eq "$GOT_MON" "$EXPECT_MON"; then
      note "B ok: txtTotalMon reads $RAW_MON for $A_VAL + $B_VAL"
    else
      bad "B: txtTotalMon reads '$RAW_MON' where $A_VAL + $B_VAL = $EXPECT_MON"
    fi ;;
esac

# -------------------------------------------------------------------- C. week total
RAW_WEEK="$(tot_read txtWeekTotal)"
case "$RAW_WEEK" in
  __MISSING__) bad "C: txtWeekTotal is not on the page" ;;
  *)
    GOT_WEEK="$(tot_num "$RAW_WEEK")"
    if [ -n "$GOT_WEEK" ] && tot_eq "$GOT_WEEK" "$EXPECT_MON"; then
      note "C ok: txtWeekTotal reads $RAW_WEEK, and Monday is the only day with hours"
    else
      bad "C: txtWeekTotal reads '$RAW_WEEK' where the only hours entered total $EXPECT_MON"
    fi ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-week-totals-multi-project — $fails total(s) not adding up."
  exit 1
fi
echo "PASS: verify-week-totals-multi-project — column and week totals both equal the rows beneath them in week $WEEK."
