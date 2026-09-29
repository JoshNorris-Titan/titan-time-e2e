#!/usr/bin/env bash
# Day cells accept hours in 0.25 steps and refuse anything finer.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Main.SUB_Timesheet_Validate refuses a day whose value fails
# round(day * 100) mod 25 != 0, with "Enter 0 to 24 hours in 0.25 increments".
# It is the only precision rule in the app, it sits directly upstream of the hours
# that reach an exported PDF and an invoice, and nothing in this suite mentions
# 0.25 or "increments". verify-hours-validation covers the bounds (25 and -5) and
# the under-40 warning; the granularity between those bounds is untested, so a
# regression that let 7.3 through would be invisible until somebody read a PDF.
#
# WHAT IT ASSERTS
#   A. 7.3 is refused - something objects, and the week does NOT leave Draft;
#   B. 7.25 is accepted - nothing objects on that ground and the value sticks.
#
# A NOW REQUIRES THE INCREMENT MESSAGE. The confirmation popup that btnSubmit opens
# since the 2026-09-04 rework used to be read as "the complaint", so A could only note
# whether it mentioned 0.25. The spec now confirms that popup and reads what the
# validation actually says; on dev (2026-09-29) that is "Enter 0 to 24 hours in 0.25
# increments" under the cell, with the week left Draft, so the naming is asserted.
#
# B is what stops this becoming a test that passes because everything is refused.
# A rule that rejected every decimal would satisfy A alone.
#
# THE VALUE IS COMPARED NUMERICALLY, not as a string, for the reason
# verify-hours-validation records: a committed Mendix day cell reformats what you
# typed (7.25 becomes "7.25", 7 becomes "7.00"), so a string compare reads an
# accepted value as a refused one.
#
# Consumes: one fresh week for the consultant, left in Draft.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"

CUSER="${TT_QI_USER:-e2e_consultant2}"
PROJECT="${TT_QI_PROJECT:-E2E Sandbox}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

qi_row()  { tt_week_row_of "$PROJECT" editable; }
qi_set()  { tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, $1)" "$2"; }
qi_val()  { playwright-cli eval "() => { const els=document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input'); const el=els[$1-1]; return el ? String(el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str; }
qi_eq()   { awk -v a="$1" -v b="$2" 'BEGIN{ gsub(/,/,".",a); exit (a+0==b+0) ? 0 : 1 }'; }
# qi_complained - every visible validation message and visible dialog's text,
# EXCLUDING the "Submit timesheet?" confirmation (a question, not a refusal).
# Visibility is by layout box: dialogs are position:fixed, so offsetParent is null.
qi_complained() {
  playwright-cli eval "() => { const vis=e=>getComputedStyle(e).display!=='none' && e.getClientRects().length>0; const v=[...document.querySelectorAll('.mx-validation-message')].filter(vis).map(e=>(e.innerText||'').trim()); const d=[...document.querySelectorAll('.modal-dialog, .mx-dialog, [role=dialog]')].filter(vis).filter(e=>!e.querySelector('.mx-name-btnConfirmSubmit')).map(e=>(e.innerText||'').replace(/\s+/g,' ').trim()); return v.concat(d).filter(Boolean).join(' ~ '); }" 2>/dev/null | _tt_eval_str
}
# qi_submit - Submit, then confirm the merged popup: validation runs on the confirm
# (ACT_Timesheet_SubmitAnyway -> ACT_Timesheet_Submit -> SUB_Timesheet_CanSave),
# not on btnSubmit, which only opens "Submit timesheet?".
qi_submit() {
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  tt_wait_for ".mx-name-btnConfirmSubmit" "the merged Submit timesheet? popup (btnConfirmSubmit)"
  playwright-cli click ".mx-name-btnConfirmSubmit" >/dev/null 2>&1
  local i c
  for i in $(seq 1 8); do
    sleep 2
    c="$(qi_complained)"
    case "$c" in *increment*|*Increment*|*"highlighted errors"*) return 0 ;; esac
  done
}

tt_login "$CUSER" "My Timesheets"
tt_goto_fresh_week "$PROJECT" || tt_fail "no fresh week with an editable '$PROJECT' row was reachable, so neither case could be attempted"

ROW="$(qi_row)"
[ "$ROW" != "0" ] || tt_fail "no editable row for '$PROJECT' in this week"
WEEK="$(tt_week_label)"
note "week $WEEK, row $ROW"

# ------------------------------------------------------------------ A. 7.3 refused
qi_set "$ROW" "7.3"
sleep 1
qi_submit
COMPLAINT="$(qi_complained)"
if [ -n "$COMPLAINT" ]; then
  note "A ok: 7.3 drew a complaint: $COMPLAINT"
  case "$COMPLAINT" in
    *0.25*|*increment*|*Increment*) note "A ok: it names the increment rule" ;;
    *) bad "A: the complaint does not name the 0.25 increment rule, so something else refused 7.3: $COMPLAINT" ;;
  esac
else
  bad "A: nothing objected to 7.3 on Monday"
fi
# Only error popups can be open now (the confirmation closes before validating),
# so clearing them clicks OK, never a submit.
tt_dismiss_dialogs >/dev/null 2>&1 || note "note: a dialog would not clear: $TT_DIALOG_BLOCKED"
sleep 2

# Read by WEEK; an unreadable status is a failure, not a pass (it used to pass as UNKNOWN).
STATUS_A="$(tt_consultant_week_status "$WEEK")"
case "$STATUS_A" in
  *Draft*|*draft*) note "A ok: the week is still Draft ($STATUS_A)" ;;
  "") bad "A: week $WEEK has no row in the timesheet history, so whether it left Draft could not be read" ;;
  *) bad "A: the week left Draft ($STATUS_A) with 7.3 on it" ;;
esac

# ----------------------------------------------------------------- B. 7.25 accepted
qi_set "$ROW" "7.25"
sleep 2
V="$(qi_val "$ROW")"
if qi_eq "$V" "7.25"; then
  note "B ok: the cell holds $V"
else
  bad "B: 7.25 did not stick - the cell reads [$V]"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hours-quarter-increment — $fails case(s) not holding."
  exit 1
fi
echo "PASS: verify-hours-quarter-increment — 7.3 refused and the week stayed Draft; 7.25 accepted and held."
