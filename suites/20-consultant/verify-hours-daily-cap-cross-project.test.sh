#!/usr/bin/env bash
# A single day cannot exceed 24 hours once every project in the week is counted.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS, AND WHY THE EXISTING TEST CANNOT COVER IT.
# Main.SUB_Timesheet_Validate sums each weekday ACROSS EVERY EDITABLE ENTRY in the
# week and refuses the submit with "These days exceed 24 hours across all
# projects: <day>". It is the only guard against a thirty-hour Tuesday.
#
# verify-hours-validation's out-of-range cases put 25 and -5 into a single row and
# run as e2e_consultant2, who holds exactly one assignment. With one row there is
# nothing to sum, so the per-row bound is what fires and the cross-project branch
# can never be reached by that test - not because it was overlooked, but because
# the account it uses makes it unreachable. This one runs as e2e_consultant, who
# holds four assignments, and puts a legal 13 hours on the SAME weekday in TWO
# different projects: 13 is fine on either row alone, and 26 is not.
#
# WHAT IT ASSERTS
#   A. two editable project rows are present in the week - established first, and
#      fatal if not, because with one row this test would silently degrade into a
#      weaker copy of verify-hours-validation;
#   B. 13 + 13 on one day is refused on submit;
#   C. the complaint names the cross-project rule rather than a per-row bound, so
#      a pass cannot come from the wrong guard firing;
#   D. the week does not leave Draft.
#
# THE REFUSAL COMES AFTER THE CONFIRM, NOT BEFORE IT. Since the 2026-09-04 rework,
# btnSubmit runs ACT_Timesheet_Submit_Start, which only gathers warnings and opens
# the merged "Submit timesheet?" popup (Consultant_OverFortyHours). Validation runs
# when that popup's btnConfirmSubmit calls ACT_Timesheet_SubmitAnyway ->
# ACT_Timesheet_Submit -> SUB_Timesheet_CanSave, which shows "These days exceed 24
# hours across all projects: <day>" and then "Please fix the highlighted errors
# first." This spec used to read the confirmation popup itself as the complaint,
# and then called tt_dismiss_dialogs, whose button list includes 'submit' - so the
# confirm was clicked blind and D read the status with no week label. Confirmed on
# dev 2026-09-29: after the confirm the week stays Draft with 26 hours on it and no
# entry leaves Draft, so the guard holds; only the reading was wrong.
#
# Consumes: one fresh week for the consultant, left in Draft.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"

CUSER="${TT_CAP_USER:-e2e_consultant}"
DAY="${TT_CAP_DAY:-Tues}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

cap_rows() { playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDay$DAY input').length)" 2>/dev/null | _tt_eval_str; }
cap_set()  { tt_fill_commit ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay$DAY input, $1)" "$2"; }
# cap_complained - every visible validation message and every visible dialog's text,
# EXCLUDING the "Submit timesheet?" confirmation, which is a question, not a
# refusal. Visibility is by layout box: a dialog is position:fixed, so offsetParent
# is always null for it, and Mendix keeps closed dialogs in the DOM.
cap_complained() {
  playwright-cli eval "() => { const vis=e=>getComputedStyle(e).display!=='none' && e.getClientRects().length>0; const v=[...document.querySelectorAll('.mx-validation-message')].filter(vis).map(e=>(e.innerText||'').trim()); const d=[...document.querySelectorAll('.modal-dialog, .mx-dialog, [role=dialog]')].filter(vis).filter(e=>!e.querySelector('.mx-name-btnConfirmSubmit')).map(e=>(e.innerText||'').replace(/\s+/g,' ').trim()); return v.concat(d).filter(Boolean).join(' ~ '); }" 2>/dev/null | _tt_eval_str
}
# cap_wait_complaint - poll up to ~15 s for a complaint that names a reason.
cap_wait_complaint() {
  local i c=""
  for i in $(seq 1 8); do
    c="$(cap_complained)"
    case "$c" in *"exceed 24"*|*"across all projects"*) break ;; esac
    sleep 2
  done
  printf '%s' "$c"
}

tt_login "$CUSER" "My Timesheets"
tt_goto_fresh_week "E2E Manager Approval" || tt_fail "no fresh week was reachable for '$CUSER'"
WEEK="$(tt_week_label)"

# ---------------------------------------------------------------- A. two rows present
N="$(cap_rows)"
case "$N" in
  ''|*[!0-9]*) tt_fail "could not count $DAY cells in week $WEEK (read: [$N])" ;;
esac
[ "$N" -ge 2 ] || tt_fail "week $WEEK shows $N editable project row(s) for '$CUSER'. This test needs TWO to sum across, and with one row it would silently become a weaker copy of verify-hours-validation. FX_ASSIGNMENTS gives '$CUSER' four projects; check 00-setup built them."
note "A ok: week $WEEK has $N editable $DAY cell(s)"

# ------------------------------------------------------------------- B/C. 13 + 13
cap_set 1 "13"
cap_set 2 "13"
tt_commit_focused >/dev/null 2>&1 || note "note: no focused field to commit"
sleep 2
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
tt_wait_for ".mx-name-btnConfirmSubmit" "the merged Submit timesheet? popup (btnConfirmSubmit)"
note "the submit opened the confirmation popup; confirming it, which is where validation runs"
playwright-cli click ".mx-name-btnConfirmSubmit" >/dev/null 2>&1
sleep 2

COMPLAINT="$(cap_wait_complaint)"
if [ -n "$COMPLAINT" ]; then
  note "B ok: the submit drew: $COMPLAINT"
else
  bad "B: 13 + 13 = 26 hours on $DAY was not objected to at all"
fi

case "$COMPLAINT" in
  *"exceed 24"*|*"across all projects"*)
    note "C ok: the complaint names the cross-project cap" ;;
  "")
    bad "C: no complaint to attribute" ;;
  *)
    bad "C: something objected, but not with the cross-project message - a pass here would be the wrong guard firing. Got: $COMPLAINT" ;;
esac

# Only error popups are left by now (the confirmation closed itself before
# validating), so clearing them clicks OK, never a submit.
tt_dismiss_dialogs >/dev/null 2>&1 || note "note: a dialog would not clear: $TT_DIALOG_BLOCKED"
sleep 2

# ------------------------------------------------------------------------ D. still Draft
# Read by WEEK: the history row for this week, from the consultant's own gallery.
# An unreadable status is a failure, not a pass - it used to be passed as UNKNOWN.
STATUS="$(tt_consultant_week_status "$WEEK")"
case "$STATUS" in
  *Draft*|*draft*) note "D ok: the week is still Draft ($STATUS)" ;;
  "") bad "D: week $WEEK has no row in the timesheet history, so whether it left Draft could not be read" ;;
  *) bad "D: the week left Draft ($STATUS) carrying 26 hours on $DAY" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hours-daily-cap-cross-project — $fails case(s) not holding."
  exit 1
fi
echo "PASS: verify-hours-daily-cap-cross-project — 13+13 on $DAY refused by the cross-project cap; week $WEEK still Draft."
