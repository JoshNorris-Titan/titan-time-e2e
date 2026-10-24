#!/usr/bin/env bash
# TT-796 — clicking into an hours box selects what is in it, so typing replaces it.
#
# tt-timeout: 6m
#
# WHY THIS EXISTS. Every editable hours box (txtDay* on a project row, txtLine* on a
# task line) has an On enter action, Main.NACT_Timesheet_SelectHours, which calls the
# JavaScript action Main.JSA_SelectFocusedInput: it selects the focused box's value and
# tells the click's own mouse-up not to move the caret. Without it a click puts the
# caret where the mouse landed, and typing "5" into "8.00" gives "8.005" or "58.00".
#
# WHAT IT ASSERTS (on Monday of one editable row, holding 8)
#   A. a real click selects the whole value — selectionStart 0, selectionEnd = length;
#   B. typing replaces it: pressing 5 then committing leaves the box at 5, not 8.005/58;
#   C. a SECOND click inside the already-focused box places the caret (an empty
#      selection), so a consultant can still edit part of a value.
#
# C is what stops this passing on a box that selects on every click and can never be
# edited in place. A and B are what this ticket adds: before TT-796 is deployed they
# go red, which is this spec's proof that it can fail.
#
# `fill` is deliberately not used for A-C: it replaces the value whatever is selected,
# which is why no older spec noticed the change. A real click and real key presses are.
#
# Consumes: one fresh week for the consultant, left in Draft.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"

CUSER="${TT_SEL_USER:-e2e_consultant2}"
PROJECT="${TT_SEL_PROJECT:-E2E Sandbox}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

sel_cell() { echo ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, $1)"; }
# sel_state <row> - "<selectionStart>|<selectionEnd>|<value>|<focused true/false>" of Monday's input.
sel_state() {
  playwright-cli eval "() => { const el=document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$1-1]; if(!el) return '__MISSING__'; return [el.selectionStart, el.selectionEnd, el.value, String(document.activeElement===el)].join('|'); }" 2>/dev/null | _tt_eval_str
}
sel_eq() { awk -v a="$1" -v b="$2" 'BEGIN{ gsub(/,/,".",a); exit (a+0==b+0) ? 0 : 1 }'; }

tt_login "$CUSER" "My Timesheets"
tt_goto_fresh_week "$PROJECT" || tt_fail "no fresh week with an editable '$PROJECT' row was reachable, so no case could be attempted"

ROW="$(tt_week_row_of "$PROJECT" editable)"
[ "$ROW" != "0" ] || tt_fail "no editable row for '$PROJECT' in this week"
note "week $(tt_week_label), row $ROW"

tt_fill_commit "$(sel_cell "$ROW")" "8"
sleep 2

# ------------------------------------------------------- A. a click selects the value
playwright-cli click "$(sel_cell "$ROW")" >/dev/null 2>&1
sleep 1   # the On enter nanoflow runs after focus; give it time to select
IFS='|' read -r S E V F <<<"$(sel_state "$ROW")"
[ "$F" = "true" ] || tt_fail "A HARNESS ERROR (not an app bug): the click did not put focus in Monday's box on row $ROW (state [$S|$E|$V|$F])"
if [ "$S" = "0" ] && [ -n "$V" ] && [ "$E" = "${#V}" ]; then
  note "A ok: the click selected all of [$V]"
else
  bad "A: after a click the selection is $S..$E of [$V] (length ${#V}) — the value is not selected"
fi

# ---------------------------------------------------------- B. typing replaces it
playwright-cli press "5" >/dev/null 2>&1
tt_commit_focused
sleep 2
IFS='|' read -r _ _ V _ <<<"$(sel_state "$ROW")"
if sel_eq "$V" "5"; then
  note "B ok: typing 5 left the box at [$V]"
else
  bad "B: typing 5 after the click left the box at [$V], not 5 — the old value was kept"
fi

# ------------------------------------------- C. a second click places the caret
playwright-cli click "$(sel_cell "$ROW")" >/dev/null 2>&1
sleep 1
playwright-cli click "$(sel_cell "$ROW")" >/dev/null 2>&1
sleep 1
IFS='|' read -r S E V F <<<"$(sel_state "$ROW")"
if [ "$F" = "true" ] && [ -n "$S" ] && [ "$S" = "$E" ]; then
  note "C ok: the second click placed the caret at $S in [$V]"
else
  bad "C: after a second click the selection is $S..$E of [$V] (focused $F) — expected a caret, so the box cannot be edited in place"
fi

tt_commit_focused

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt796-hours-select-on-click — $fails case(s) not holding."
  exit 1
fi
echo "PASS: verify-tt796-hours-select-on-click — a click selects the hours, typing replaces them, and a second click places the caret."
