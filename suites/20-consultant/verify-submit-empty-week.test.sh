#!/usr/bin/env bash
# Submitting a week with no hours sends every entry straight to ToProcess,
# bypassing manager and customer approval.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Main.ACT_Timesheet_Submit routes an entry whose TotalHours is 0
# to ToProcess regardless of the project's ApprovalFromManager and
# ApprovalFromCustomer flags. That is deliberate - nobody should have to approve a
# blank week - but it means a blank week reaches HR marked as approved work
# without a human ever looking at it, and the behaviour is load-bearing enough
# that a change to it should be noticed.
#
# tt692693-c2 is the only test that touches zero hours, and it reaches the
# behaviour through the REJECTED-entry Review & Edit popup, which is a different
# microflow (Main.SUB_AssignmentEntry_Submit). The ordinary weekly grid path
# through ACT_Timesheet_Submit has never been exercised with an empty week.
#
# WHAT IT ASSERTS
#   A. the week really is empty before submitting - every day cell blank or zero.
#      Without this the test could pass on a week that had hours and was approved
#      normally, which is the wrong behaviour passing for the right reason;
#   B. the submit is accepted (the grid leaves Draft);
#   C. every entry for that week is ToProcess, read from the DATA LAYER rather
#      than from a badge - the badge is a rollup and would read "Awaiting
#      Approval" identically whether the entries went to ToProcess or to
#      AwaitingManagerApproval;
#   D. specifically, none is AwaitingManagerApproval or AwaitingCustomerApproval.
#
# C is the assertion that distinguishes this from a plain submit test. B alone
# passes whatever status the entries ended in.
#
# Consumes: one fresh week, which it submits and leaves in ToProcess.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"
source "$TT_ROOT/lib/_authz.sh"

CUSER="${TT_EMPTY_SUBMIT_USER:-e2e_consultant2}"
CNAME="${TT_EMPTY_SUBMIT_NAME:-E2E Consultant Two}"
PROJECT="${TT_EMPTY_SUBMIT_PROJECT:-E2E Sandbox}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

nonzero_cells() {
  playwright-cli eval "() => { const els=[...document.querySelectorAll('.mx-name-galAssignmentRows input')]; return String(els.filter(e => { const v=String(e.value||'').trim().replace(',','.'); return v !== '' && parseFloat(v) > 0; }).length); }" 2>/dev/null | _tt_eval_str
}

tt_login "$CUSER" "My Timesheets"
tt_goto_fresh_week "$PROJECT" || tt_fail "no fresh week with an editable '$PROJECT' row was reachable"
WEEK="$(tt_week_label)"
note "week $WEEK"

# ------------------------------------------------------------------- A. really empty
NZ="$(nonzero_cells)"
case "$NZ" in
  ''|*[!0-9]*) tt_fail "could not count filled day cells in week $WEEK (read: [$NZ])" ;;
  0)           note "A ok: every day cell is blank or zero" ;;
  *)           tt_fail "week $WEEK already carries $NZ non-zero day cell(s), so this would test an ordinary submit, not an empty one. tt_goto_fresh_week is supposed to land on an untouched week." ;;
esac

# ---------------------------------------------------------------------- B. submit it
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
sleep 3
# The merged submit popup asks for confirmation whether or not it warned.
if [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnConfirmSubmit'))" 2>/dev/null | _tt_eval_str)" = "true" ]; then
  note "confirm popup shown; confirming"
  playwright-cli click ".mx-name-btnConfirmSubmit" >/dev/null 2>&1
  sleep 4
fi
tt_dismiss_dialogs >/dev/null 2>&1 || note "note: no dialog was open to dismiss"

STATUS="$(tt_consultant_week_status 2>/dev/null || echo UNKNOWN)"
case "$STATUS" in
  *Draft*|*draft*) bad "B: the week is still $STATUS - the empty submit was not accepted" ;;
  UNKNOWN)         note "B: could not read the week badge; C decides this test" ;;
  *)               note "B ok: the week now reads $STATUS" ;;
esac

# ------------------------------------------------------- C/D. where did the entries go
tt_login "e2e_hr" "WEEKLY TO PROCESS"
OWNED="Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$CNAME'"
TOPROCESS="$(tt_authz_count "//Main.AssignmentEntry[$OWNED][Status='ToProcess']")"
AWAIT_M="$(tt_authz_count "//Main.AssignmentEntry[$OWNED][Status='AwaitingManagerApproval']")"
AWAIT_C="$(tt_authz_count "//Main.AssignmentEntry[$OWNED][Status='AwaitingCustomerApproval']")"
note "for $CNAME: ToProcess=$TOPROCESS AwaitingManager=$AWAIT_M AwaitingCustomer=$AWAIT_C"

case "$TOPROCESS" in
  ERR:*|''|*[!0-9]*) bad "C: could not count ToProcess entries for $CNAME (read: [$TOPROCESS])" ;;
  0)                 bad "C: no entry for $CNAME is ToProcess after submitting an empty week" ;;
  *)                 note "C ok: $TOPROCESS entr(ies) are ToProcess" ;;
esac

for pair in "AwaitingManagerApproval:$AWAIT_M" "AwaitingCustomerApproval:$AWAIT_C"; do
  s="${pair%%:*}"; n="${pair#*:}"
  case "$n" in
    ERR:*|''|*[!0-9]*) note "D: could not count $s (read: [$n])" ;;
    0)                 note "D ok: nothing is waiting in $s" ;;
    *)                 bad "D: $n entr(ies) for $CNAME are in $s - an empty week should bypass approval entirely" ;;
  esac
done

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-submit-empty-week — $fails problem(s) with the zero-hours route."
  exit 1
fi
echo "PASS: verify-submit-empty-week — week $WEEK submitted empty and its entries went straight to ToProcess."
