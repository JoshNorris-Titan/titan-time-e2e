#!/usr/bin/env bash
# TT-647 angle 5 — a project needing BOTH approvals lists BOTH approvers.
#
# This is the headline requirement Josh added: when a project requires PM *and*
# client approval, the To Process card must show both, manager stage first.
#
# Path: consultant submits on a dual-approval project -> PM approves from the PM
# dashboard (ChangeMethod=Manager, FromStatus=AwaitingManagerApproval) -> the entry
# moves to AwaitingCustomerApproval -> HR approves it on the Client Approval tab
# (ChangeMethod=HR, FromStatus=AwaitingCustomerApproval) -> ToProcess with TWO
# approval rows in the cycle, which must render as two lines.
#
# ── FIXTURE REQUIRED ────────────────────────────────────────────────────────────
# Needs a project with BOTH ApprovalFromManager=Yes AND ApprovalFromCustomer=Yes,
# with e2e_consultant assigned. The existing e2e projects are single-stage
# ("E2E Manager Approval" is manager-only, "E2E Customer Approval" client-only), so
# neither can produce a two-line card. Create "E2E Dual Approval" (PM =
# E2E ProjectManger) or point TT_A5_PROJECT at an equivalent one.
# This test FAILS rather than skips when the fixture is absent — a silent skip here
# would mean the two-approver requirement is never actually proven.
# ────────────────────────────────────────────────────────────────────────────────
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt647.sh"

PROJECT="${TT_A5_PROJECT:-E2E Dual Approval}"
PM_NAME="${TT_A5_PM_NAME:-E2E ProjectManger}"

mgr_ordinal() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; for(let n=0;n<btns.length;n++){ let el=btns[n]; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; if(/$PROJECT/.test(el.innerText||'')&&(el.innerText||'').length<200) return String(n+1);} } return '0'; }" 2>/dev/null | sed -n '2p' | tr -d '\"'
}
pm_login_dash() { tt_login "e2e_pm" "Project Manager Dashboard"; tt_wait_for ".mx-name-galPMPendingEntries" "PM pending gallery"; }

# 1) Seed + confirm the dual-approval fixture actually exists.
tt_login "e2e_consultant" "My Timesheets"
if ! playwright-cli eval "() => String((document.body.innerText||'').indexOf('$PROJECT') >= 0)" 2>/dev/null | grep -qiw true; then
  tt_fail "no assignment for project '$PROJECT' is visible to e2e_consultant — this scenario needs a project with ApprovalFromManager=Yes AND ApprovalFromCustomer=Yes (see the fixture note at the top of this file)"
fi
tt_consultant_submit_project_row "$PROJECT"

# 2) PM approves -> should move to the client stage, NOT straight to To Process.
for _ in 1 2 3 4 5 6; do
  pm_login_dash
  [ "$(mgr_ordinal)" != "0" ] && break
  sleep 6
done
ORD="$(mgr_ordinal)"
[ "$ORD" != "0" ] || tt_fail "'$PROJECT' entry never reached the PM pending queue — is ApprovalFromManager set on this project?"
playwright-cli click ":nth-match(.mx-name-galPMPendingEntries .mx-name-btnPMApprove, ${ORD})" >/dev/null 2>&1
sleep 4

# 3) It must now be awaiting the CLIENT — proving the project is genuinely two-stage.
tt647_hr_open_tab "$TT647_TAB_CLIENT"
tt647_select_week_with "$PROJECT" >/dev/null \
  || tt_fail "'$PROJECT' did not reach the Client Approval tab after PM approval — this project is not dual-approval, so it cannot exercise the two-line case"

# 4) HR approves in the client's place -> second approval row in the same cycle.
tt647_hr_approve_card "$PROJECT" \
  || tt_fail "no Approve control on the Client Approval card for '$PROJECT'"

# 5) Both approvers must now be listed, manager stage first.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
WEEK=$(tt647_select_week_with "$PROJECT") \
  || tt_fail "no week on the To Process tab lists a '$PROJECT' entry after both approvals"
echo "matched To Process week: $WEEK"

tt647_require_widgets "To Process tab"

LINES="$(tt647_card_lines "$PROJECT")"
L1="${LINES%%~~*}"
L2="${LINES#*~~}"
echo "line1: '$L1'"
echo "line2: '$L2'"

[ -n "$L1" ] || tt_fail "dual-approval card has an empty approver line 1"
[ -n "$L2" ] || tt_fail "dual-approval card has only ONE approver line — the client-stage approval is missing. line1='$L1'"

case "$L1" in
  "Approved by $PM_NAME (Project Manager) on "??/??/????) : ;;
  *) tt_fail "line 1 should be the manager-stage approval by $PM_NAME, got: '$L1'" ;;
esac
case "$L2" in
  *"(HR/Titan Manager, on behalf of Client)"*) : ;;
  *) tt_fail "line 2 should be the client-stage approval performed by HR, got: '$L2'" ;;
esac

# Manager stage is line 1 by construction; both lines must carry a real date.
case "$L1$L2" in
  *" on "??/??/????*" on "??/??/????*) : ;;
  *) tt_fail "both lines should end in an MM/DD/YYYY date. line1='$L1' line2='$L2'" ;;
esac

echo "PASS: verify-tt647-a5-dual-approval-two-lines — both approvers listed, manager stage first"
