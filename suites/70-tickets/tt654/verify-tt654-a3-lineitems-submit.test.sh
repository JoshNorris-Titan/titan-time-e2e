#!/usr/bin/env bash
# TT-654 A3 — the NeedsLineItems branch of Main.SUB_AssignmentEntry_Submit.
#
# ── WHAT CHANGED ABOUT THIS TEST, AND WHY ───────────────────────────────────────
# This test used to drive the timesheet grid's .mx-name-btnSubmit and claim it
# was covering the extraction. It was not. In Main.SNIP_Timesheet that button is
# `microflow Main.ACT_Timesheet_Submit_Start` -> the single confirm popup ->
# Main.ACT_Timesheet_Submit, which is the WEEKLY submit and keeps its own inline
# line-items handling. Main.ACT_AssignmentEntry_Submit — the microflow that was
# gutted into Main.SUB_AssignmentEntry_Submit — is referenced from exactly one
# widget in the whole model: the "Resubmit Timesheet" button on
# Main.AssignmentEntry_RejectionReview. So the only way to reach the refactored
# sub from the UI is a REJECTED entry's resubmit, which is what this now does.
# ────────────────────────────────────────────────────────────────────────────────
#
# The branch under test: when AssignmentEntry/NeedsLineItems is true,
# Main.SUB_AssignmentEntry_Submit does four extra things before committing the
# change log —
#   retrieve the LineItems -> commit them -> Main.SUB_LineItem_ToString ->
#   write the result onto ChangeLog.LineItems
# Those four activities were transcribed during the extraction and have never
# run: verify-tt692693-c1-resubmit (the only other test on this path) uses
# "E2E Sandbox", which is not a line-items project.
#
# The MCP SubmitWeek tool deliberately REFUSES line-items projects — that
# refusal is asserted separately by verify-tt654-a7 — so the resubmit popup is
# the only route to this branch.
#
# Asserts:
#   - a rejected line-items entry can be resubmitted from the Review & Edit popup
#   - the popup closes and the entry leaves the Rejected list (the sub ran and
#     returned OK; NOT_EDITABLE or a save failure would leave it in place)
#   - it reaches an approval queue, i.e. the status expression ran too
#
# Does NOT assert ChangeLog.LineItems content — that is not on screen. Check it
# on a local F5 with tests/oql-changelog-attribution.sh.

# tt-timeout: 8m
#   Measured at 277s against Mendix Cloud dev: five logins, a rejection hunt over
#   the HR tabs, a resubmit through the Review & Edit popup and two re-reads. It
#   is the longest step in the suite and does not fit the 4m default.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"
source "$TT_ROOT/lib/_tt692693.sh"

PROJ="$TT654_PROJECT_LINEITEMS"
CUSER="$TT654_CONSULTANT"
CNAME="${TT654_CONSULTANT_NAME:-E2E Consultant}"

# ------------------------------------------------------------- local helpers
#
# tt_make_rejected_entry (lib/_tt692693.sh) cannot seed this project: it fills
# the aggregate day cells directly, and on a NeedsLineItems row those are
# read-only — hours come from the task rows. So the seed below uses the TT-654
# line-item helpers instead.
#
# Both helpers target the card/row by PROJECT as well as by consultant. The
# weekly Submit submits every assignment row on the week at once, so this
# consultant will usually have several entries in flight, and a
# first-match-by-name helper would happily reject or reopen the wrong one — a
# run that proves nothing while reporting green.

# Both live in lib/_tt692693.sh now, under tt_-prefixed names, because
# verify-tt692693-c4 needed the identical pair: it asks for a rejected 'E2E Line
# Items' entry and used the name-only helpers, so it rejected and then reopened a
# different project's entry and reported a failure it had manufactured. Two
# copies of a helper this fiddly is how one of them gets fixed and the other does
# not. These aliases keep the local call sites reading as they did.
hr_reject_card_for_project() {
  tt_hr_reject_card_for_project "$1" "$2" "$3" "E2E automated reject for TT-654 A3"
}
open_review_for_project() { tt_open_review_for_project "$1"; }

# ---------------------------------------------------------------- 1) fixture
# Seed a line-items week: hours live on the task row, not the day cells.
tt_login "$CUSER" "My Timesheets"
tt654_find_editable_row "$PROJ"
ORD="$TT654_ORD"
WEEK="$TT654_WEEK"
echo "seeding '$PROJ' on week: ${WEEK:-<unknown>} (row $ORD)"
tt654_fill_row "$ORD" "$TT654_HOURS"
TASK_IDX="$(tt654_add_task "$ORD" "TT654 A3 LineItem Task" "$TT654_HOURS")"
echo "added task #$TASK_IDX"
tt654_save_draft

ORD="$(tt654_row_ordinal "$PROJ")"
[ -n "$ORD" ] && [ "$ORD" != "0" ] || tt_fail "'$PROJ' row is no longer editable after Save Draft — nothing to submit"
tt654_submit_row "$ORD" "$PROJ" >/dev/null 2>&1 || true

# Reject it so the resubmit path becomes reachable.
#
# WHICH TAB. The fixture declares 'E2E Line Items' as No|No|Yes - needs line
# items, requires NO approval - so a submitted entry on it goes straight to
# ToProcess and never enters either approval queue. This used to search only
# MANAGER APPROVAL and CLIENT APPROVAL, so it spent six attempts and ~7 minutes
# looking in two tabs the entry cannot reach, then failed as though HR were
# broken. WEEKLY TO PROCESS is where this project's entries actually land; the
# approval tabs stay in the list so the same test still works if the fixture is
# ever given an approval step.
# This phase is the slowest in the suite and used to run silently, so a run that
# died here reported only "added task #1" and gave no clue which tab it was on.
echo "seeded and submitted; now hunting a '$PROJ' card to reject"
REJECTED=""
for TAB in "WEEKLY TO PROCESS" "MANAGER APPROVAL" "CLIENT APPROVAL"; do
  for ATTEMPT in 1 2 3; do
    echo "  reject attempt $ATTEMPT on the $TAB tab"
    if hr_reject_card_for_project "$CNAME" "$PROJ" "$TAB"; then REJECTED=1; break; fi
    sleep 6
  done
  [ -n "$REJECTED" ] && { echo "  rejected on the $TAB tab"; break; }
done
[ -n "$REJECTED" ] \
  || tt_fail "HR could not find a '$PROJ' card for '$CNAME' to reject in either approval queue — without a rejected entry the resubmit path (the only caller of Main.ACT_AssignmentEntry_Submit) cannot be reached"

tt_login "$CUSER" "My Timesheets"
BEFORE="$(tt_rejected_count)"
[ "$BEFORE" != "0" ] || tt_fail "no rejected entry present after the fixture ran"
echo "rejected entries before resubmit: $BEFORE"

# ------------------------------------------------- 2) resubmit via the popup
open_review_for_project "$PROJ" \
  || tt_fail "no Review & Edit control for a rejected '$PROJ' entry — the fixture rejected something else, so this run would exercise the non-line-items path and report a misleading pass"
POPUP="$(tt_popup_text)"
echo "popup: $POPUP"

case "$POPUP" in
  *"$PROJ"*) : ;;
  *) tt_fail "the Review & Edit popup is not showing the '$PROJ' entry (got: ${POPUP:0:200})" ;;
esac

tt_click_button_exact "resubmit timesheet" popup \
  || tt_fail "no 'Resubmit Timesheet' button in the popup — that button is the only caller of Main.ACT_AssignmentEntry_Submit"
sleep 4
tt_dismiss_dialogs
sleep 3

[ "$(tt_popup_open)" = "false" ] \
  || tt_fail "the popup did not close after Resubmit — Main.ACT_AssignmentEntry_Submit did not reach its 'close page', so SUB_AssignmentEntry_Submit returned something other than OK (a required field on Main.ChangeLog in the line-items branch would do this)"
echo "popup closed"

# ------------------------------------------------------------- 3) it submitted
AFTER="$(tt_rejected_count)"
echo "rejected entries after resubmit: $AFTER"
[ "$AFTER" -lt "$BEFORE" ] \
  || tt_fail "the '$PROJ' entry is still in the Rejected list (before=$BEFORE after=$AFTER) — the line-items branch of SUB_AssignmentEntry_Submit did not complete"

# Still gone after a real re-fetch, i.e. it committed rather than just repainting.
tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
RELOADED="$(tt_rejected_count)"
[ "$RELOADED" -lt "$BEFORE" ] \
  || tt_fail "the entry reappeared in the Rejected list after reload (=$RELOADED) — the commit inside the line-items branch rolled back"

# ------------------------------------------------ 4) the status expression ran
# Where it should land is decided by the project's approval flags, not by a fixed
# tab: 'E2E Line Items' requires no approval, so the status expression routes a
# resubmit straight back to ToProcess. Asserting MANAGER APPROVAL here was
# asserting a queue this project never uses.
tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
LANDED="WEEKLY TO PROCESS"
INQ="$(tt_hr_count_cards_for "$CNAME" "$LANDED")"
echo "'$CNAME' cards in $LANDED: $INQ"
[ "${INQ:-0}" -ge 1 ] \
  || tt_fail "the resubmitted line-items entry did not reach $LANDED — SUB_AssignmentEntry_Submit's status expression did not route it"

echo "PASS: verify-tt654-a3-lineitems-submit — the NeedsLineItems branch of SUB_AssignmentEntry_Submit ran end to end via the resubmit path"
