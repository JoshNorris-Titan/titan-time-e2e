#!/usr/bin/env bash
# TT-647 angle 6 — HR approving in the PROJECT MANAGER's place is labelled as a
# stand-in for the PM, not for the client.
#
# Main.SUB_ApprovalHelper_SetApprovalLines derives the role suffix from
# ChangeLog.ChangeMethod plus the stage the approval came from:
#   Manager                            -> "(Project Manager)"                          [a1]
#   Token (emailed client link)        -> "(Client)"                                   [untested: needs a real token click]
#   HR, from AwaitingCustomerApproval  -> "(HR/Titan Manager, on behalf of Client)"     [a2, a5]
#   HR, from AwaitingManagerApproval   -> "(HR/Titan Manager, on behalf of Project Manager)"  <-- THIS FILE
#
# The fourth variant was the only one with no coverage. It is a distinct branch
# of the expression, and getting it wrong produces a sentence that credits the
# wrong stand-in — the same class of error a2 exists to prevent, just at the
# manager stage instead of the client stage.
#
# Path: consultant submits on "E2E Manager Approval" (ApprovalFromManager=Yes,
# ApprovalFromCustomer=No) -> the entry sits on the HR "Manager Approval" tab ->
# HR clicks Approve there INSTEAD of the PM approving from the PM dashboard.
# Because the approving account is not the project's PM,
# Main.ACT_HRDashboard_ApproveOrReject stamps ChangeMethod=HR with
# FromStatus=AwaitingManagerApproval. The project is manager-only, so the entry
# then lands directly in ToProcess with a single approval line.
#
# Contrast with verify-tt647-a1, which uses the SAME project but has the PM
# approve, and must render "(Project Manager)". If both tests report the same
# sentence, the ChangeMethod/FromStatus branch is not being read at all.
#
# Consumes one pending manager-approval entry per run and seeds one if needed.
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt647.sh"

PROJECT="${TT_A6_PROJECT:-E2E Manager Approval}"
PM_NAME="${TT_A6_PM_NAME:-E2E ProjectManger}"
CONSULTANT_NAME="${TT_A6_CONSULTANT_NAME:-E2E Consultant}"
EXPECT="(HR/Titan Manager, on behalf of Project Manager)"

# 1) ALWAYS seed our own entry and remember its week.
# Deliberately not reusing whatever is already pending: verify-tt647-a1 uses the
# same project AND the same consultant, so a reused card could be the one it
# already approved as the PM — which is exactly how this test used to fail with
# "(Project Manager)". Seeding gives us a week we can pin to below.
tt_login "e2e_consultant" "My Timesheets"
tt_consultant_submit_project_row "$PROJECT"
WEEK_FRAG="$TT_SUBMITTED_WEEK"
[ -n "$WEEK_FRAG" ] \
  || tt_fail "could not record which week was submitted — cannot identify this test's own entry among other '$PROJECT' cards"
echo "seeded '$PROJECT' on week: $WEEK_FRAG"

tt647_hr_open_tab "$TT647_TAB_MANAGER"
tt647_wait_for_card "$WEEK_FRAG" "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "no '$PROJECT' card for '$CONSULTANT_NAME' in week '$WEEK_FRAG' on the Manager Approval tab — the submitted entry did not reach the manager queue (async workflow routing?)"

# 2) HR approves it from the dashboard, standing in for the PM.
#    Deliberately NOT the PM dashboard — approving there would stamp
#    ChangeMethod=Manager and this test would silently become a copy of a1.
tt647_hr_approve_card "$PROJECT" \
  || tt_fail "no Approve control on the Manager Approval card for '$PROJECT'"

# 3) Manager-only project, so it goes straight to To Process.
# Pin to the week we seeded, then match the card on project AND consultant —
# anything less can read a different entry's approval line.
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
  *"$EXPECT"*) : ;;
  *"(Project Manager)"*)
    tt_fail "line 1 credits the project manager directly for an HR-performed approval — the stand-in is not being distinguished at the manager stage. got: '$L1'" ;;
  *"on behalf of Client"*)
    tt_fail "line 1 says 'on behalf of Client' for an approval taken from the MANAGER stage — SUB_ApprovalHelper_SetApprovalLines is not branching on FromStatus. got: '$L1'" ;;
  *) tt_fail "line 1 is not the expected HR-stand-in-for-PM sentence (wanted something containing \"$EXPECT\"). got: '$L1'" ;;
esac

case "$L1" in
  "Approved by "*" on "??/??/????) : ;;
  *) tt_fail "line 1 does not match \"Approved by <name> on MM/DD/YYYY\". got: '$L1'" ;;
esac

# HR stood in for the PM, so the PM's own name must not be the approver.
case "$L1" in
  "Approved by $PM_NAME "*)
    tt_fail "line 1 names the PM ($PM_NAME) as the approver even though HR performed it — ChangeBy is not being read from the ChangeLog. got: '$L1'" ;;
esac

# A manager-only project has no client stage, so the second line stays empty.
[ -z "$L2" ] || tt_fail "line 2 should be empty on a manager-only project, got: '$L2'"

echo "PASS: verify-tt647-a6-hr-on-behalf-of-pm — HR stand-in at the manager stage renders '$L1'"
