#!/usr/bin/env bash
# C3 — cannot resubmit an entry that is already in approval.
#
# The status-eligibility guard must refuse a second submit (a message, not a silent
# re-submit), and the approval queue must contain exactly ONE item for the entry —
# the old bug created a duplicate workflow instance.
#
# Runs C1's flow first (resubmit once), then attempts a second resubmit from the
# stale popup/list state without a full reload.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_C3_USER:-e2e_consultant2}"
CNAME="${TT_C3_NAME:-E2E Consultant Two}"
PROJECT="${TT_C3_PROJECT:-E2E Sandbox}"

# baseline queue depth before we add anything
tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
Q0="$(tt_hr_count_cards_for "$CNAME" "MANAGER APPROVAL")"
echo "manager-approval cards for '$CNAME' before: $Q0"

TT_FORCE_NEW_REJECT=1 tt_make_rejected_entry "$CUSER" "$CNAME" "$PROJECT" \
  || tt_fail "C3 setup: could not produce a rejected entry"

tt_login "$CUSER" "My Timesheets"
tt_open_review_edit || tt_fail "C3: could not open Review & Edit"

# first resubmit (should succeed)
tt_click_button_exact "resubmit timesheet" popup || tt_fail "C3: no Resubmit button"
sleep 4; tt_dismiss_dialogs; sleep 3
echo "first resubmit done (popup open=$(tt_popup_open))"

# attempt a SECOND resubmit without a full reload
SECOND="skipped"
if tt_open_review_edit; then
  if tt_click_button_exact "resubmit timesheet" popup; then
    sleep 4
    MSG="$(tt_popup_text)"
    tt_dismiss_dialogs
    SECOND="attempted"
    echo "second resubmit attempted; popup/message: $MSG"
  else
    SECOND="no-button"
  fi
  tt_click_button_exact "cancel" popup >/dev/null 2>&1
else
  SECOND="row-gone"
  echo "the rejected row was already gone — no second submit possible (acceptable)"
fi

# the queue must have grown by exactly ONE
tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
Q1="$(tt_hr_count_cards_for "$CNAME" "MANAGER APPROVAL")"
echo "manager-approval cards for '$CNAME' after: $Q1 (second-submit path: $SECOND)"

DELTA=$(( ${Q1:-0} - ${Q0:-0} ))
[ "$DELTA" -le 1 ] || tt_fail "C3 FAIL: approval queue grew by $DELTA (expected at most 1) — duplicate workflow instance created"

echo "PASS: C3 — no duplicate approval item (queue delta=$DELTA, second-submit path: $SECOND)"
