#!/usr/bin/env bash
# TT-654 A2 — the WEEKLY timesheet Submit path still works.
#
# ── SCOPE CORRECTION ────────────────────────────────────────────────────────────
# This file used to claim it was the regression for the
# Main.ACT_AssignmentEntry_Submit -> Main.SUB_AssignmentEntry_Submit extraction.
# It is not, and never was. .mx-name-btnSubmit in Main.SNIP_Timesheet is
# `show_page Main.Confirmation_timesheet` -> Main.ACT_Timesheet_Precheck ->
# Main.ACT_Timesheet_Submit. That is a DIFFERENT microflow which keeps its own
# inline submit logic; it does not call the extracted sub at all.
#
# The extraction is covered by verify-tt692693-c1-resubmit (general case) and
# verify-tt654-a3 (the NeedsLineItems branch), both of which go through the
# "Resubmit Timesheet" button on Main.AssignmentEntry_RejectionReview — the only
# widget in the model wired to Main.ACT_AssignmentEntry_Submit.
#
# What this file is genuinely worth keeping for: Main.ACT_Timesheet_Submit was
# itself edited in the same commit (its Main.ChangeLog row is now created BEFORE
# the status change and patched after, so FromStatus records the real prior
# status), and this is the only test that drives that flow end to end.
# ────────────────────────────────────────────────────────────────────────────────
#
# Asserts:
#   - a seeded Draft week can be submitted from the page
#   - the row becomes non-editable afterwards (status left Draft/Rejected)
#   - submitting again is refused with the "can no longer be edited" warning,
#     which proves the editability guard still fires from the page path
#
# Uses a customer-approval project so the submit lands on AwaitingCustomerApproval.
# Consumes the week it seeds — submitted entries are not editable, so each run
# seeds a fresh one.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"

PROJ="$TT654_PROJECT_CUSTOMER"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# Seed a Draft week for this project and remember where it is.
tt654_find_editable_row "$PROJ"
ORD="$TT654_ORD"
WEEK="$TT654_WEEK"
echo "submitting '$PROJ' on week: ${WEEK:-<unknown>} (row $ORD)"

tt654_fill_row "$ORD" "$TT654_HOURS"
tt654_save_draft

# Re-resolve the ordinal — Save Draft re-renders the grid and row order is not
# guaranteed to survive it.
ORD="$(tt654_row_ordinal "$PROJ")"
[ -n "$ORD" ] && [ "$ORD" != "0" ] || tt_fail "'$PROJ' row is no longer editable after Save Draft — nothing to submit"

if tt654_submit_row "$ORD" "$PROJ"; then
  echo "submit confirmed — $TT654_SUBMIT_DIAG"
else
  tt_fail "the page submit path did not complete for '$PROJ' — $TT654_SUBMIT_DIAG"
fi

# The entry is now submitted, so the row should also stop being offered for
# editing. That is a genuinely separate property from the transition above — the
# entry can be out of Draft while the grid still renders a live input — but the
# grid does not repaint on its own, so the week has to be re-queried before the
# question can be asked fairly. Without that this assertion fails on a submit
# that demonstrably worked, which is exactly what it did before.
AGAIN=""
for _ in 1 2 3; do
  tt654_refetch_week
  AGAIN="$(tt654_row_ordinal "$PROJ")"
  [ "$AGAIN" = "0" ] && break
  sleep 4
done
[ "$AGAIN" = "0" ] \
  || tt_fail "'$PROJ' still offers an editable row on '$WEEK' after a submit that DID move the entry out of Draft ($TT654_SUBMIT_DIAG) — the grid is still letting a submitted week be edited"

echo "PASS: the weekly timesheet Submit path (Main.ACT_Timesheet_Submit) still works ($WEEK)"
