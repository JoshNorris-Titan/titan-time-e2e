#!/usr/bin/env bash
# TT-647 angle 2 — HR approving in the CLIENT's place is labelled as a stand-in.
#
# This is the distinction Josh asked for: the line must not read as though the
# client approved. Path: consultant submits on "E2E Customer Approval"
# (ApprovalFromCustomer=Yes) -> entry sits on the HR "Client Approval" tab awaiting
# the emailed token link -> HR clicks Approve on the dashboard instead.
#
# Main.ACT_ApprovalHelper_Approve stamps ChangeMethod=HR (the approving account is
# not the project's PM) with FromStatus=AwaitingCustomerApproval, so TT-647 must
# render "(HR/Titan Manager, on behalf of Client)" — NOT "(Client)".
#
# Consumes one pending client-approval entry per run and seeds one if none exists.
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt647.sh"

PROJECT="E2E Customer Approval"
CONSULTANT_NAME="${TT_A2_CONSULTANT_NAME:-E2E Consultant}"

# 1) ALWAYS seed our own entry and remember its week.
# Reusing a pending entry is what made this test unreliable: several
# 'E2E Customer Approval' cards can sit on the To Process tab at once, and the
# assertion below used to read whichever came first — including entries that
# reached ToProcess with NO approval step, which render "No approval required".
# Seeding gives us a week to pin to, so we read the entry we actually approved.
tt_login "e2e_consultant" "My Timesheets"
tt_consultant_submit_project_row "$PROJECT"
WEEK_FRAG="$TT_SUBMITTED_WEEK"
[ -n "$WEEK_FRAG" ] \
  || tt_fail "could not record which week was submitted — cannot identify this test's own entry among other '$PROJECT' cards"
echo "seeded '$PROJECT' on week: $WEEK_FRAG"

tt647_hr_open_tab "$TT647_TAB_CLIENT"
tt647_wait_for_card "$WEEK_FRAG" "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "no '$PROJECT' card for '$CONSULTANT_NAME' in week '$WEEK_FRAG' on the Client Approval tab — the entry did not reach the client queue"

# 2) HR approves it from the dashboard, standing in for the client.
tt647_hr_approve_card "$PROJECT" \
  || tt_fail "no Approve control on the Client Approval card for '$PROJECT'"

# 3) It should now be on the To Process tab, attributed to HR as a stand-in.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
tt647_wait_for_card "$WEEK_FRAG" "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "no '$PROJECT' card for '$CONSULTANT_NAME' in week '$WEEK_FRAG' on the To Process tab after HR approval — the entry did not advance"
echo "pinned To Process week: $WEEK_FRAG"

tt647_require_widgets "To Process tab"

LINES="$(tt647_card_lines "$PROJECT" "$CONSULTANT_NAME")"
L1="${LINES%%~~*}"
L2="${LINES#*~~}"
echo "line1: '$L1'"
echo "line2: '$L2'"

[ -n "$L1" ] || tt_fail "To Process card for '$PROJECT' has an empty approver line 1"

# The stand-in wording is the whole point of this scenario.
case "$L1" in
  *"(HR/Titan Manager, on behalf of Client)"*) : ;;
  *"(Client)"*) tt_fail "line 1 credits the client directly for an HR-performed approval — the stand-in is not being distinguished. got: '$L1'" ;;
  *) tt_fail "line 1 is not the expected HR-stand-in sentence. got: '$L1'" ;;
esac
case "$L1" in
  "Approved by "*" on "??/??/????) : ;;
  *) tt_fail "line 1 does not match \"Approved by <name> on MM/DD/YYYY\". got: '$L1'" ;;
esac

echo "PASS: verify-tt647-a2-hr-on-behalf-of-client — HR stand-in renders '$L1'"
