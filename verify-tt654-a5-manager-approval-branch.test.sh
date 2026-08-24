#!/usr/bin/env bash
# TT-654 A5 — the manager-approval branch of the WEEKLY submit status expression.
#
# ── SCOPE CORRECTION ────────────────────────────────────────────────────────────
# This file used to attribute the status expression to
# Main.SUB_AssignmentEntry_Submit. It drives .mx-name-btnSubmit, which is
# Main.ACT_Timesheet_Submit (via Main.Confirmation_timesheet ->
# Main.ACT_Timesheet_Precheck), not the extracted sub. Both flows carry their own
# copy of the same expression, so the test is still worth having — it just covers
# the weekly one. The sub's copy is covered by verify-tt692693-c1-resubmit, which
# asserts a resubmit lands in the Manager Approval queue.
# ────────────────────────────────────────────────────────────────────────────────
#
# The expression under test (Main.ACT_Timesheet_Submit, per entry):
#   if TotalHours = 0            -> ToProcess
#   else if ApprovalFromManager  -> AwaitingManagerApproval
#   else if ApprovalFromCustomer -> AwaitingCustomerApproval
#   else                         -> ToProcess
# Every other TT-654 test submits a customer-approval project, so without this
# the AwaitingManagerApproval branch is never taken. A mis-transcribed condition
# here would silently route timesheets to the wrong approver, which is worse
# than an error.
#
# Submits from the PAGE (proving the client path) and then reads the resulting
# status back through the MCP GetMyWeek tool — the status is not reliably
# rendered on the timesheet grid, and this cross-checks the two paths agree
# about the same entry.

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt654.sh"

PROJ="$TT654_PROJECT_MANAGER"

tt_login "$TT654_CONSULTANT" "My Timesheets"

tt654_find_editable_row "$PROJ"
ORD="$TT654_ORD"
WEEK="$TT654_WEEK"
WEEK_START="$TT654_WEEK_START"
echo "manager-approval week: ${WEEK:-<unknown>} (row $ORD)"

tt654_fill_row "$ORD" "$TT654_HOURS"
tt654_save_draft

ORD="$(tt654_row_ordinal "$PROJ")"
[ -n "$ORD" ] && [ "$ORD" != "0" ] || tt_fail "'$PROJ' row is no longer editable after Save Draft — nothing to submit"

if tt654_submit_row "$ORD"; then
  echo "row became non-editable after Submit"
else
  tt_fail "row for '$PROJ' is still editable after Submit — the page submit path did not complete"
fi

# Read the resulting status back through MCP. Needs a parseable week start; if
# the caption could not be parsed, say so rather than silently skipping the
# assertion that is the entire point of this test.
[ -n "$WEEK_START" ] || tt_fail "submitted '$PROJ' on '$WEEK' but could not parse a yyyy-MM-dd week start, so the resulting status cannot be asserted"

TOKEN="$(tt654_mint_token)"
[ -n "$TOKEN" ] || tt_fail "could not mint an MCP token to read back the submitted status"

WK="$(tt654_mcp_call "$TOKEN" GetMyWeek "{WeekStartDate:'$WEEK_START'}")"
case "$WK" in
  *AUTHFAIL*)  tt_fail "MCP rejected a freshly minted token" ;;
  *"$PROJ"*)   ;;
  *)           tt_fail "GetMyWeek($WEEK_START) did not include '$PROJ' (got: ${WK:0:300})" ;;
esac

case "$WK" in
  *AwaitingManagerApproval*)
    echo "status after submit: AwaitingManagerApproval" ;;
  *AwaitingCustomerApproval*)
    tt_fail "'$PROJ' submitted to AwaitingCustomerApproval — the manager branch of the status expression did not fire (is ApprovalFromManager actually true on this project?)" ;;
  *ToProcess*)
    tt_fail "'$PROJ' submitted to ToProcess — either the hours did not commit (TotalHours = 0) or neither approval flag is set on the project" ;;
  *)
    tt_fail "unexpected status after submitting '$PROJ' (got: ${WK:0:300})" ;;
esac

echo "PASS: manager-approval project routes to AwaitingManagerApproval ($WEEK_START)"
