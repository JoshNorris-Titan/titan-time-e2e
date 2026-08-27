#!/usr/bin/env bash
# TT-647 angle 6 — HR approving in the PROJECT MANAGER's place is named as the
# approver, and the PM is not.
#
# Main.SUB_ApprovalHelper_SetApprovalLines routes an approval by the stage it came
# from, and shows ChangeLog/ChangeBy -- the name of whoever actually clicked:
#   FromStatus=AwaitingManagerApproval -> $PMLog     -> line 1
#   FromStatus=AwaitingCustomerApproval -> $ClientLog -> line 2
#
# The failure this guards against is line 1 showing the PROJECT MANAGER's name for
# an approval HR performed. That would mean ChangeBy is not being read from the
# ChangeLog at all, and the card would credit someone who never touched it — the
# same class of error a2 guards at the client stage.
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
# approve. a1 must report the PM's name on line 1 and this file must report the
# HR user's. If both report the same name, ChangeBy is not being read per-approval.
#
# Consumes one pending manager-approval entry per run and seeds one if needed.
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

PROJECT="${TT_A6_PROJECT:-E2E Manager Approval}"
PM_NAME="${TT_A6_PM_NAME:-E2E ProjectManger}"
CONSULTANT_NAME="${TT_A6_CONSULTANT_NAME:-E2E Consultant}"

# 1) ALWAYS seed our own entry and remember its week.
# Deliberately not reusing whatever is already pending: verify-tt647-a1 uses the
# same project AND the same consultant, so a reused card could be the one it
# already approved as the PM — which is exactly how this test used to fail, by
# reading the PM's name. Seeding gives us a week we can pin to below.
tt_login "e2e_consultant" "My Timesheets"
tt_consultant_submit_project_row "$PROJECT"
WEEK_FRAG="$TT_SUBMITTED_WEEK"
[ -n "$WEEK_FRAG" ] \
  || tt_fail "could not record which week was submitted — cannot identify this test's own entry among other '$PROJECT' cards"
echo "seeded '$PROJECT' on week: $WEEK_FRAG"

tt647_hr_open_tab "$TT647_TAB_MANAGER"
tt647_wait_for_card "$WEEK_FRAG" "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "no '$PROJECT' card for '$CONSULTANT_NAME' in week '$WEEK_FRAG' on the Manager Approval tab — the submitted entry did not reach the manager queue (async workflow routing?). ${TT647_WAIT_ERR:-}"

# 2) HR approves it from the dashboard, standing in for the PM.
#    Deliberately NOT the PM dashboard — approving there would stamp
#    ChangeMethod=Manager and this test would silently become a copy of a1.
tt647_hr_approve_card "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "could not approve the Manager Approval card for '$PROJECT': ${TT647_APPROVE_ERR:-unknown}"

# 3) Manager-only project, so it goes straight to To Process.
# Pin to the week we seeded, then match the card on project AND consultant —
# anything less can read a different entry's approval line.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
tt647_wait_for_card "$WEEK_FRAG" "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "no '$PROJECT' card for '$CONSULTANT_NAME' in week '$WEEK_FRAG' on the To Process tab after HR approval — the entry did not advance. ${TT647_WAIT_ERR:-}"
echo "pinned To Process week: $WEEK_FRAG"

tt647_require_widgets "To Process tab"

# HR is signed in here, so this is the name ChangeBy recorded for the approval.
HR_NAME="$(tt647_session_fullname)"
[ -n "$HR_NAME" ]   || tt_fail "could not read the signed-in HR user's display name from the session"
echo "approving HR user: '$HR_NAME'"

LINES="$(tt647_card_lines "$PROJECT" "$CONSULTANT_NAME")"
L1="${LINES%%~~*}"
L2="${LINES#*~~}"
echo "line1: '$L1'"
echo "line2: '$L2'"

[ -n "$L1" ] || tt_fail "To Process card for '$PROJECT' has an empty approver line 1"

# HR stood in at the MANAGER stage, so the approval belongs on line 1 and must
# name the HR user who performed it.
[ "$L1" = "$HR_NAME" ]   || tt_fail "line 1 should name the HR user who approved ('$HR_NAME'), got: '$L1'"

# The failure this test exists to catch: crediting the PM for HR's approval.
[ "$L1" != "$PM_NAME" ]   || tt_fail "line 1 names the PM ($PM_NAME) as the approver even though HR performed it — ChangeBy is not being read from the ChangeLog"

[ "$L1" != "N/A" ]   || tt_fail "line 1 is 'N/A' — the manager-stage approval was not recorded at all"

# A manager-only project has no client stage, so line 2 is the empty marker.
[ "$L2" = "N/A" ]   || tt_fail "line 2 should be 'N/A' on a manager-only project, got: '$L2'"

echo "PASS: verify-tt647-a6-hr-on-behalf-of-pm — line1='$L1' line2='$L2'"
