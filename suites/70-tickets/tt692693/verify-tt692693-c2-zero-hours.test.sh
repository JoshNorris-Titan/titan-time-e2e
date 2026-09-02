#!/usr/bin/env bash
# C2 — zero-hours resubmit routes to PROCESS (HR), not "Awaiting Manager Approval".
#
# Before the change the entry DISPLAYED "Awaiting Manager Approval" while the only
# live task was HR's Process task. So this checks BOTH: the status shown to the
# consultant AND the queue it actually lands in — and that they agree.
#
# WHAT THE MODEL DOES, so a failure here can be read against something:
#   Main.SUB_AssignmentEntry_Submit sets Status to
#     'if $TotalHours = 0 then ToProcess else if ApprovalFromManager then ...'
#   with TotalHours a plain sum of the seven day attributes, and
#   Main.AssignmentEntry_Approval's FIRST decision ($WorkflowContext/TotalHours = 0)
#   goes straight to the Process user task. HR's WEEKLY TO PROCESS tab is the
#   HRDashboardTab row whose Status is ToProcess.
# So a genuine "not in the process queue" means one of those three disagrees. Every
# read below is paged and scoped so that conclusion is actually available; the
# previous version of this test could not support it. See lib/_tt692693.sh.
#
# tt-timeout: 10m
#
# The budget is declared because the fixture is expensive and honest about it: it
# submits a week, then retries the HR reject up to six times because the approval
# workflow routes asynchronously, and each attempt re-logs in twice at ~27s a login.
# The queue reads themselves are ~20s now they are scoped to one week; they were
# ~10 minutes when they walked all nine weeks of the picker, which is what made this
# test a TIMEOUT rather than a pass or a fail.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_C2_USER:-e2e_consultant2}"
CNAME="${TT_C2_NAME:-E2E Consultant Two}"
PROJECT="${TT_C2_PROJECT:-E2E Sandbox}"

TT_FORCE_NEW_REJECT=1 tt_make_rejected_entry "$CUSER" "$CNAME" "$PROJECT" \
  || tt_fail "C2 setup: could not produce a rejected entry"

WEEK="${TT_REJECTED_WEEK:-}"
[ -n "$WEEK" ] || tt_fail "C2 setup: the fixture did not report which week it submitted, so the consultant-status half of this test cannot be checked"
echo "week under test: $WEEK (key '$(tt_week_key "$WEEK")')"

tt_login "$CUSER" "My Timesheets"
BEFORE="$(tt_rejected_count)"
[ "$BEFORE" != "0" ] || tt_fail "C2: no rejected entry present"

tt_open_review_edit || tt_fail "C2: could not open Review & Edit"

# Zero every editable day box AND commit the last one — see tt_popup_zero_days.
ZEROED="$(tt_popup_zero_days)"
echo "zeroed $ZEROED day box(es)"
[ "${ZEROED:-0}" -ge 1 ] || tt_fail "C2: no editable day boxes in the Review & Edit popup"

# The premise of the whole test is that the week really is zero, so prove it rather
# than assuming the blur landed. Bounded wait: the commit is a server round trip.
ALLZERO=false
for _ in 1 2 3 4 5; do
  sleep 3
  ALLZERO="$(tt_popup_days_all_zero)"
  [ "$ALLZERO" = "true" ] && break
done
echo "day inputs now: $(tt_popup_day_inputs)"
[ "$ALLZERO" = "true" ] \
  || tt_fail "C2: the day boxes never all read as committed zeroes, so this run cannot test zero-hours routing.
  day inputs: $(tt_popup_day_inputs)
  (a raw '0' beside committed '0.00' values means that box was never blurred)"

tt_click_button_exact "resubmit timesheet" popup || tt_fail "C2: no Resubmit button"
sleep 4
tt_dismiss_dialogs
sleep 3
[ "$(tt_popup_open)" = "false" ] || tt_fail "C2: popup did not close"

# Status shown to the consultant, for THE WEEK THIS TEST SUBMITTED — the history list
# holds every week the consultant has, so it must be addressed by name.
tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
HIST="$(tt_consultant_week_status "$WEEK")"
echo "consultant sees for $WEEK: ${HIST:-(week not found in history)}"

# Which queue did it actually land in? Asked about THE WEEK THIS TEST SUBMITTED, not
# summed over every week the consultant has -- a leftover card from an earlier test's
# week would otherwise satisfy "it reached the process queue" on its own. See
# tt_hr_count_cards_for_week.
tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
INPROC="$(tt_hr_count_cards_for_week "$CNAME" "WEEKLY TO PROCESS" "$WEEK")"
INMGR="$(tt_hr_count_cards_for_week "$CNAME" "MANAGER APPROVAL" "$WEEK")"
echo "'$CNAME' in MANAGER APPROVAL=$INMGR  |  in WEEKLY TO PROCESS=$INPROC"

FAILS=""
[ "${INPROC:-0}" -ge 1 ] || FAILS="$FAILS not-in-process-queue"
[ -n "$HIST" ] || FAILS="$FAILS week-missing-from-consultant-history"
case "$HIST" in
  *"Awaiting Manager Approval"*)
    [ "${INMGR:-0}" -ge 1 ] || FAILS="$FAILS shows-AwaitingManagerApproval-but-not-in-manager-queue" ;;
esac

[ -z "$FAILS" ] || tt_fail "C2 FAIL:$FAILS
  week under test: $WEEK
  consultant history row: ${HIST:-(week not found in history)}
  full history: $(tt_consultant_history_load)
  MANAGER APPROVAL=$INMGR  WEEKLY TO PROCESS=$INPROC
  (expected: zero-hours resubmit -> Process/HR queue, and the displayed status must match the real queue)"

echo "PASS: C2 — zero-hours resubmit routed to the Process queue and the displayed status matches"
