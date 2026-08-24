#!/usr/bin/env bash
# PM approve ACTION (TT-691) — approving a manager-approval entry from the PM dashboard
# fires no server error and removes the entry from the queue.
#
# TT-691 background: the PM dashboard Approve (btnPMApprove → Main.ACT_ApprovalHelper_Approve)
# used to throw HTTP 560 / "Internal server error" because it retrieved a null
# WorkflowUserTask (AssignmentEntry_WorkflowUserTask was empty) and passed it to
# SUB_AssignAndApprove. The fix (merged ~2026-07-27) stamps that association on task
# creation (WFC_AssignmentEntry_AddTask_*) and adds an unactionable-task guard to
# ACT_ApprovalHelper_Approve. This test is the regression guard for that fix.
#
# What it does: ensures a pending manager-approval entry exists (self-seeds via the
# multi-assignment submit helper when the pool is empty; workflow routing is async so it
# polls), clicks its .mx-name-btnPMApprove, asserts NO server error fires, and that the
# entry has left the PM's pending queue after a re-fetch. Consumes one entry per run.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

PROJECT="E2E Manager Approval"

# Count pending entries for $PROJECT in the PM gallery.
mgr_count() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; let m=0; for(const b of btns){let el=b; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; if(/$PROJECT/.test(el.innerText||'')&&(el.innerText||'').length<200){m++;break;}}} return String(m); }" 2>/dev/null | sed -n '2p' | tr -d '\"'
}

# Ordinal (1-based) of the first $PROJECT Approve button among all btnPMApprove.
mgr_ordinal() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; for(let n=0;n<btns.length;n++){ let el=btns[n]; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; if(/$PROJECT/.test(el.innerText||'')&&(el.innerText||'').length<200) return String(n+1);} } return '0'; }" 2>/dev/null | sed -n '2p' | tr -d '\"'
}

pm_login_dash() { tt_login "e2e_pm" "Project Manager Dashboard"; tt_wait_for ".mx-name-galPMPendingEntries" "PM pending gallery"; }

# 1) Ensure a pending manager-approval entry exists.
pm_login_dash
if [ "$(mgr_count)" = "0" ]; then
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_project_row "$PROJECT"
  # Workflow routing to the PM's pending queue is async — poll a few times.
  for _ in 1 2 3 4 5 6; do
    pm_login_dash
    [ "$(mgr_count)" != "0" ] && break
    sleep 6
  done
fi
N="$(mgr_count)"
[ "$N" != "0" ] || tt_fail "could not obtain a pending '$PROJECT' entry to approve (async routing?)"

# 2) Approve one entry.
ORD="$(mgr_ordinal)"
playwright-cli click ":nth-match(.mx-name-galPMPendingEntries .mx-name-btnPMApprove, ${ORD})" >/dev/null 2>&1
sleep 3

# 3) The approve must not raise a server error.
if playwright-cli console 2>/dev/null | grep -qiE "executing an action of Main.ProjectManagerDashboard.btnPMApprove|/xas/.*560"; then
  tt_fail "PM Approve raised a server error (btnPMApprove 560 bug — see FINDINGS.md)"
fi

# 4) After a re-fetch, the approved entry has left the queue.
pm_login_dash
M="$(mgr_count)"
[ "$M" -lt "$N" ] || tt_fail "approved entry did not leave the PM queue (before=$N, after=$M)"

echo "PASS: PM approve action removed a '$PROJECT' entry from the pending queue (before=$N, after=$M)"
