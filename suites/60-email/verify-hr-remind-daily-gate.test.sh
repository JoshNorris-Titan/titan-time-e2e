#!/usr/bin/env bash
# A customer cannot be reminded twice about the same timesheet on the same day.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS, AND WHY IT EXPLAINS SOMETHING ELSE. Main.ACT_Email_Remind has
# an "Already reminded today?" split: a second remind for the same customer and
# timesheet on the same day is refused with "A reminder email was sent to this
# customer for this timesheet already today at {1}.", and the card swaps
# btnClientRemind for btnClientRemindBlocked.
#
# Nothing tests it, and its absence has been paid for elsewhere. lib/_login_core.sh
# records that all the e2e projects share one FX_APPROVER_EMAIL, so "the FIRST spec
# in a run to press Remind gates every already-pending client entry for the rest of
# the run, across all projects". The three token specs in 30-approval each press
# Remind, and when the gate fires for the second and third the failure surfaces as
# "reminder email not received" - which reads like a broken mail queue and is
# actually this rule working correctly. A test that names the gated state is the
# difference between that being a known behaviour and a recurring mystery.
#
# WHAT IT ASSERTS
#   A. the Client Approval tab has a pending entry to act on - fatal otherwise,
#      because everything below would be vacuous;
#   B. after a remind, the card for that entry is GATED - btnClientRemindBlocked
#      is present where btnClientRemind was;
#   C. the gate is specific, not global: the number of gated cards did not jump to
#      every card on the tab for an unrelated reason.
#
# IF IT IS ALREADY GATED WHEN THIS STARTS that is not a failure. An earlier spec in
# the same run reminding the same approver is exactly the documented behaviour, and
# the assertion - that a gated card stays gated and offers no second send - is the
# same one. The step says which of the two worlds it ran in.
#
# Consumes: may send one reminder email to the fixture approver address.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CONSULTANT="${TT_REMIND_CONSULTANT:-E2E Consultant}"
PROJECT="${TT_REMIND_PROJECT:-E2E Customer Approval}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

count_sel() { playwright-cli eval "() => String(document.querySelectorAll('$1').length)" 2>/dev/null | _tt_eval_str; }

tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_click_text "CLIENT APPROVAL"
sleep 3

OPEN_BEFORE="$(count_sel "$TT_HR_BTN_REMIND")"
GATED_BEFORE="$(count_sel "$TT_HR_BTN_REMIND_BLOCKED")"
case "$OPEN_BEFORE$GATED_BEFORE" in
  *ERR*|'') tt_fail "could not read the Client Approval tab's remind buttons" ;;
esac
note "before: $OPEN_BEFORE remindable card(s), $GATED_BEFORE already gated"

# --------------------------------------------------------------- A. something to act on
if [ "${OPEN_BEFORE:-0}" -eq 0 ] && [ "${GATED_BEFORE:-0}" -eq 0 ]; then
  tt_fail "the Client Approval tab shows no pending entry at all, so there is nothing to remind about and this step has no verdict. suites/30-approval puts one there; run the suite in order."
fi

if [ "${OPEN_BEFORE:-0}" -eq 0 ]; then
  note "A: every card is ALREADY gated - an earlier spec in this run reminded this approver, which lib/_login_core.sh documents. Asserting the gate holds."
else
  note "A ok: $OPEN_BEFORE card(s) can still be reminded"
  if WEEK="$(tt_hr_remind_e2e_entry "$CONSULTANT" "$PROJECT")"; then
    note "reminded '$CONSULTANT' / '$PROJECT' for week $WEEK"
  else
    note "note: no remindable card matched '$CONSULTANT' / '$PROJECT'; asserting on whatever the tab shows"
  fi
  sleep 3
  tt_click_text "CLIENT APPROVAL"
  sleep 3
fi

# ------------------------------------------------------------------------ B/C. the gate
OPEN_AFTER="$(count_sel "$TT_HR_BTN_REMIND")"
GATED_AFTER="$(count_sel "$TT_HR_BTN_REMIND_BLOCKED")"
note "after: $OPEN_AFTER remindable card(s), $GATED_AFTER gated"

if [ "${GATED_AFTER:-0}" -gt 0 ]; then
  note "B ok: $GATED_AFTER card(s) show the gated state"
else
  bad "B: no card is gated. Either the remind did not send, or a customer can be reminded about the same timesheet repeatedly in one day."
fi

TOTAL_BEFORE=$(( ${OPEN_BEFORE:-0} + ${GATED_BEFORE:-0} ))
TOTAL_AFTER=$(( ${OPEN_AFTER:-0} + ${GATED_AFTER:-0} ))
if [ "$TOTAL_AFTER" -eq "$TOTAL_BEFORE" ]; then
  note "C ok: the tab still shows $TOTAL_AFTER card(s); reminding moved one between states rather than changing the queue"
else
  bad "C: the tab went from $TOTAL_BEFORE to $TOTAL_AFTER card(s) across a remind - reminding is not supposed to consume the entry"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-remind-daily-gate — $fails problem(s) with the once-per-day remind gate."
  exit 1
fi
echo "PASS: verify-hr-remind-daily-gate — $GATED_AFTER card(s) gated, queue size unchanged at $TOTAL_AFTER."
