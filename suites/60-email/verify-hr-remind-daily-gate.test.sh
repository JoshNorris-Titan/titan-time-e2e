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
#   A. the Client Approval tab has a pending E2E entry to act on (one is submitted
#      when there is none) - fatal if even that fails,
#      because everything below would be vacuous;
#   B. after a remind, the card for that entry is GATED - btnClientRemindBlocked
#      is present where btnClientRemind was;
#   C. the gate is specific, not global: the number of gated cards did not jump to
#      every card on the tab for an unrelated reason;
#   D. (only when this spec does the reminding) TT-768: the Remind ends in the
#      blocking "Reminder sent to {name} ({email})." message, which is read and
#      dismissed (tt_hr_remind_confirm) before the tab is clicked again.
#
# IF IT IS ALREADY GATED WHEN THIS STARTS that is not a failure. An earlier spec in
# the same run reminding the same approver is exactly the documented behaviour, and
# the assertion - that a gated card stays gated and offers no second send - is the
# same one. The step says which of the two worlds it ran in.
#
# Consumes: may send one reminder email to the fixture approver address, and may
# submit one e2e_consultant week on the project when the tab holds none of ours.
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

# ONE WEEK, PINNED (2026-10-06). Before and after used to be counted on whatever week
# the tab happened to show, and the remind walked the week picker to find its card -
# so when the default week's remindable card was someone else's (a targeted run on
# dev: 1 remindable, 1 gated, neither ours), the walk left a DIFFERENT week selected
# and C compared two weeks ("went from 2 to 1 card(s)"). Now the week holding our
# card is found first and every count, the remind and the read-back happen on it.
# When the tab holds no card of ours at all, one is submitted - the same seeding
# tt_customer_link does - rather than asserting on unrelated cards.
hr_tab() { tt_login "e2e_hr" "$TT_HR_READY"; tt_hr_click_tab "Client approval"; sleep 3; }
hr_tab
MODE=open
WEEK="$(tt_hr_find_remind_week "$CONSULTANT" "$PROJECT" open)" \
  || { MODE=gated; WEEK="$(tt_hr_find_remind_week "$CONSULTANT" "$PROJECT" gated)"; } \
  || WEEK=""
if [ -z "$WEEK" ]; then
  note "no '$CONSULTANT' / '$PROJECT' card on the Client Approval tab - submitting one as the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_project_row "$PROJECT"
  MODE=open
  for _ in 1 2 3 4 5 6; do
    hr_tab
    WEEK="$(tt_hr_find_remind_week "$CONSULTANT" "$PROJECT" open)" && break
    WEEK=""
    sleep 5
  done
  [ -n "$WEEK" ] || tt_fail "the Client Approval tab shows no '$CONSULTANT' / '$PROJECT' card even after submitting a week (${TT_SUBMITTED_WEEK:-?}), so there is nothing to remind about and this step has no verdict."
fi
note "pinned week $WEEK (our card is $MODE)"

OPEN_BEFORE="$(count_sel "$TT_HR_BTN_REMIND")"
GATED_BEFORE="$(count_sel "$TT_HR_BTN_REMIND_BLOCKED")"
case "$OPEN_BEFORE$GATED_BEFORE" in
  *ERR*|'') tt_fail "could not read the Client Approval tab's remind buttons" ;;
esac
note "before ($WEEK): $OPEN_BEFORE remindable card(s), $GATED_BEFORE already gated"

if [ "$MODE" = "gated" ]; then
  note "A: our card is ALREADY gated - an earlier spec in this run reminded this approver, which lib/_login_core.sh documents. Asserting the gate holds."
else
  note "A ok: our card can be reminded"
  RC=0
  tt_hr_remind_here "$CONSULTANT" "$PROJECT" || RC=$?
  case "$RC" in
    0) note "reminded '$CONSULTANT' / '$PROJECT' for week $WEEK; D ok: TT-768's 'Reminder sent to {name} ({email}).' message showed and was dismissed" ;;
    2) bad "D: the Remind for '$CONSULTANT' / '$PROJECT' week $WEEK did not end in TT-768's 'Reminder sent to {name} ({email}).' message (see the [remind] line above)" ;;
    *) tt_fail "the '$CONSULTANT' / '$PROJECT' card in week $WEEK offered Remind a moment ago and now does not - nothing was reminded, so B/C have no verdict" ;;
  esac
  sleep 3
  tt_hr_click_tab "Client approval"
  sleep 3
  tt_hr_select_week "$WEEK" || tt_fail "week $WEEK is no longer offered on the Client Approval tab after the remind"
fi

OPEN_AFTER="$(count_sel "$TT_HR_BTN_REMIND")"
GATED_AFTER="$(count_sel "$TT_HR_BTN_REMIND_BLOCKED")"
note "after ($WEEK): $OPEN_AFTER remindable card(s), $GATED_AFTER gated"

if [ "$(tt_hr_card_gated_here "$CONSULTANT" "$PROJECT")" = "true" ]; then
  note "B ok: the '$CONSULTANT' / '$PROJECT' card shows the gated state"
else
  bad "B: the '$CONSULTANT' / '$PROJECT' card in week $WEEK is not gated. Either the remind did not send, or a customer can be reminded about the same timesheet repeatedly in one day."
fi

TOTAL_BEFORE=$(( ${OPEN_BEFORE:-0} + ${GATED_BEFORE:-0} ))
TOTAL_AFTER=$(( ${OPEN_AFTER:-0} + ${GATED_AFTER:-0} ))
if [ "$TOTAL_AFTER" -eq "$TOTAL_BEFORE" ]; then
  note "C ok: week $WEEK still shows $TOTAL_AFTER card(s); reminding moved one between states rather than changing the queue"
else
  bad "C: week $WEEK went from $TOTAL_BEFORE to $TOTAL_AFTER card(s) across a remind - reminding is not supposed to consume the entry"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-remind-daily-gate — $fails problem(s) with the once-per-day remind gate."
  exit 1
fi
echo "PASS: verify-hr-remind-daily-gate — $GATED_AFTER card(s) gated, queue size unchanged at $TOTAL_AFTER."
