#!/usr/bin/env bash
# TT-647 angle 2 — HR approving in the CLIENT's place is named as the approver.
#
# The line carries no role suffix, so it cannot say "on behalf of". What it CAN
# guarantee is that the name shown is the person who actually clicked Approve --
# the HR user -- and not the project's client contact. That is what this asserts.
# Path: consultant submits on "E2E Customer Approval"
# (ApprovalFromCustomer=Yes) -> entry sits on the HR "Client Approval" tab awaiting
# the emailed token link -> HR clicks Approve on the dashboard instead.
#
# Main.ACT_ApprovalHelper_Approve stamps ChangeMethod=HR (the approving account is
# not the project's PM) with FromStatus=AwaitingCustomerApproval, so the approval
# lands in $ClientLog -> line 2. The project is client-only, so there is no
# manager stage and line 1 stays 'N/A'.
#
# Asserts on the HR "Weekly Timesheets to Process" tab:
#   line 1 = "N/A"                  (no manager stage on a client-only project)
#   line 2 = the HR user's own name (NOT Project/ContactName, the client contact)
#
# Consumes one pending client-approval entry per run and seeds one if none exists.
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

PROJECT="E2E Customer Approval"
CONSULTANT_NAME="${TT_A2_CONSULTANT_NAME:-E2E Consultant}"

# 1) ALWAYS seed our own entry and remember its week.
# Reusing a pending entry is what made this test unreliable: several
# 'E2E Customer Approval' cards can sit on the To Process tab at once, and the
# assertion below used to read whichever came first — including entries that
# reached ToProcess with NO approval step, which render 'N/A' on both lines.
# Seeding gives us a week to pin to, so we read the entry we actually approved.
tt_login "e2e_consultant" "My Timesheets"
tt_consultant_submit_project_row "$PROJECT"
WEEK_FRAG="$TT_SUBMITTED_WEEK"
[ -n "$WEEK_FRAG" ] \
  || tt_fail "could not record which week was submitted — cannot identify this test's own entry among other '$PROJECT' cards"
echo "seeded '$PROJECT' on week: $WEEK_FRAG"

tt647_hr_open_tab "$TT647_TAB_CLIENT"
tt647_wait_for_card "$WEEK_FRAG" "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "no '$PROJECT' card for '$CONSULTANT_NAME' in week '$WEEK_FRAG' on the Client Approval tab — the entry did not reach the client queue. ${TT647_WAIT_ERR:-}"

# 2) HR approves it from the dashboard, standing in for the client.
tt647_hr_approve_card "$PROJECT" "$CONSULTANT_NAME" \
  || tt_fail "could not approve the Client Approval card for '$PROJECT': ${TT647_APPROVE_ERR:-unknown}"

# 3) It should now be on the To Process tab, attributed to HR as a stand-in.
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

# Client-only project: no manager stage, so line 1 is the empty marker.
[ "$L1" = "N/A" ]   || tt_fail "line 1 should be 'N/A' on a client-only project (no manager stage), got: '$L1'"

# The point of this scenario: the approver named is the HR user who clicked,
# not the client contact the stage nominally belongs to.
[ "$L2" = "$HR_NAME" ]   || tt_fail "line 2 should name the HR user who approved ('$HR_NAME'), got: '$L2'"
[ "$L2" != "N/A" ]   || tt_fail "line 2 is 'N/A' — the client-stage approval was not recorded at all"

echo "PASS: verify-tt647-a2-hr-on-behalf-of-client — line1='$L1' line2='$L2'"
