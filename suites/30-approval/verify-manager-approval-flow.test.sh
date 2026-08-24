#!/usr/bin/env bash
# Manager-approval routing → Project Manager dashboard (post widget-naming).
#
# Proves that a timesheet entry on a project with ApprovalFromManager=Yes routes
# to the assigned PROJECT MANAGER's approval queue (not the customer email flow),
# and that the PM dashboard exposes it via the renamed, stable selectors
# (galPMPendingEntries / btnPMApprove / btnPMApproveAll).
#
# Idempotent: it does NOT approve, so the pending entry survives for the next run.
# If no pending manager-approval entry exists, it submits one as the consultant
# (filling only the manager-approval row of the multi-assignment timesheet).
#
# Data: project "E2E Manager Approval" (Customer Walmart, ApprovalFromManager=Yes,
# ApprovalFromCustomer=No, PM = E2E ProjectManger), with e2e_consultant assigned.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

PROJECT="E2E Manager Approval"
CONSULTANT="E2E Consultant"

pm_has_pending() {
  playwright-cli eval "() => String(((document.querySelector('.mx-name-galPMPendingEntries')||{}).innerText||'').indexOf('$PROJECT') >= 0)" 2>/dev/null | grep -qiw true
}

# 1) Ensure a pending manager-approval entry is in the PM queue.
tt_login "e2e_pm" "Project Manager Dashboard"
if ! pm_has_pending; then
  echo "no pending '$PROJECT' entry — submitting one as the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_project_row "$PROJECT"
  tt_login "e2e_pm" "Project Manager Dashboard"
  pm_has_pending || tt_fail "'$PROJECT' entry did not reach the PM pending queue after submit"
fi

# 2) The PM's pending gallery shows the manager-approval entry (stable selectors).
tt_wait_for ".mx-name-galPMPendingEntries" "PM pending-approval gallery"

playwright-cli eval "() => { const t=((document.querySelector('.mx-name-galPMPendingEntries')||{}).innerText)||''; return String(t.indexOf('$PROJECT')>=0 && t.indexOf('$CONSULTANT')>=0); }" 2>/dev/null | grep -qiw true \
  || tt_fail "PM pending gallery does not list '$PROJECT' for '$CONSULTANT'"

# 3) The renamed approve controls render for the pending work.
playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove').length >= 1)" 2>/dev/null | grep -qiw true \
  || tt_fail "no .mx-name-btnPMApprove in the PM pending gallery"
playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnPMApproveAll'))" 2>/dev/null | grep -qiw true \
  || tt_fail "no .mx-name-btnPMApproveAll on the PM dashboard"

echo "PASS: manager-approval routing — '$PROJECT' reaches the PM pending queue with renamed Approve controls"
