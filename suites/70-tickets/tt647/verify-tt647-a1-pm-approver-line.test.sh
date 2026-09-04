#!/usr/bin/env bash
# TT-647 angle 1 — a PM-approved entry shows the PROJECT MANAGER as the approver.
#
# Path: consultant submits on "E2E Manager Approval" (ApprovalFromManager=Yes,
# ApprovalFromCustomer=No) -> PM approves from the PM dashboard -> entry lands in
# ToProcess. Main.ACT_ApprovalHelper_Approve records ChangeBy = the approving
# account's name, which on this path is the project's own PM.
#
# Asserts on the HR "Weekly Timesheets to Process" tab:
#   line 1 = "E2E ProjectManger"  (the manager-stage approver, a bare name)
#   line 2 = "N/A"                (a manager-only project has no client stage)
#
# Consumes one pending manager-approval entry per run and seeds one if the pool is
# empty. Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

PROJECT="E2E Manager Approval"
PM_NAME="E2E ProjectManger"

mgr_ordinal() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; for(let n=0;n<btns.length;n++){ let el=btns[n]; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; if(/$PROJECT/.test(el.innerText||'')&&(el.innerText||'').length<200) return String(n+1);} } return '0'; }" 2>/dev/null | sed -n '2p' | tr -d '\"'
}
# No gallery wait. This is called BEFORE the seeding block below and again inside
# its retry loop, so an empty queue is an expected state on most calls -- and
# since 2026-09-03 an empty queue renders no gallery to wait for. Waiting here
# hard-failed the test before the seeding it guards could ever run.
pm_login_dash() { tt_login "e2e_pm" "Project Manager Dashboard"; }

# 1) Make sure the PM has a pending entry on the manager-approval project.
pm_login_dash
if [ "$(mgr_ordinal)" = "0" ]; then
  echo "no pending '$PROJECT' entry — seeding one as the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_project_row "$PROJECT"
  for _ in 1 2 3 4 5 6; do
    pm_login_dash
    [ "$(mgr_ordinal)" != "0" ] && break
    sleep 6
  done
fi
ORD="$(mgr_ordinal)"
[ "$ORD" != "0" ] || tt_fail "could not obtain a pending '$PROJECT' entry to approve (async workflow routing?)"

# 2) Approve it AS THE PM — this is what makes ChangeMethod = Manager.
playwright-cli click ":nth-match(.mx-name-galPMPendingEntries .mx-name-btnPMApprove, ${ORD})" >/dev/null 2>&1
sleep 4

# 3) Read the approver lines off the HR To Process tab.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
WEEK=$(tt647_select_week_with "$PROJECT") \
  || tt_fail "no week on the To Process tab lists a '$PROJECT' entry after PM approval"
echo "matched To Process week: $WEEK"

tt647_require_widgets "To Process tab"

LINES="$(tt647_card_lines "$PROJECT")"
L1="${LINES%%~~*}"
L2="${LINES#*~~}"
echo "line1: '$L1'"
echo "line2: '$L2'"

[ -n "$L1" ] || tt_fail "To Process card for '$PROJECT' has an empty approver line 1"

# Line 1 is the manager-stage approver's name verbatim, nothing more.
[ "$L1" = "$PM_NAME" ]   || tt_fail "line 1 should be the PM's name for a PM-approved entry. got: '$L1' (wanted '$PM_NAME')"

# A manager-only project has no client stage, so line 2 is the empty marker.
[ "$L2" = "N/A" ]   || tt_fail "line 2 should be 'N/A' on a manager-only project, got: '$L2'"

echo "PASS: verify-tt647-a1-pm-approver-line — line1='$L1' line2='$L2'"
