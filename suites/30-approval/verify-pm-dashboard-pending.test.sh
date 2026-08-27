#!/usr/bin/env bash
# Project Manager dashboard — managed project + pending-approval oversight.
#
# Verifies that a PM logging in sees the project they manage (with its details)
# and the "Pending Approval" section listing submitted entries with Approve /
# Approve All controls. This is a read-only oversight check — it does NOT click
# Approve (that would consume the entry). Uses the stable post-naming selectors
# galPMPendingEntries / btnPMApprove / btnPMApproveAll.
#
# Data dependency: the pending-approval assertions expect at least one submitted
# E2E entry awaiting approval. The customer-approval test keeps a standing pool of
# these (it never approves), so they are normally present.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_pm" "Project Manager Dashboard"

# Managed-project card (stable data: project + assignment + PM linkage).
#
# The card comes from Main.DS_ProjectsManaged through a gallery in
# Main.SNIP_ProjectsDashboardView, so it renders ASYNCHRONOUSLY after login. Wait
# for it before asserting: this test used to fail in 4s against a correctly
# configured project simply because it looked too early.
# Log what the dashboard actually rendered before asserting on it: DS_ProjectsManaged
# returns every non-archived project for this PM, so "which ones came back" is the
# first thing worth knowing when a name is missing.
playwright-cli eval "() => { const b=document.body.innerText||''; const m=b.match(/E2E [A-Za-z ]+/g); return m ? [...new Set(m)].join(', ') : '(no E2E project names on the page)'; }" 2>/dev/null | _tt_eval_str | sed 's/^/  [pm-dashboard projects] /'

tt_wait_text "E2E Customer Approval" "managed-project card on the PM dashboard"

tt_assert_all "PM dashboard: managed project" \
  "Project Manager Dashboard" \
  "E2E Customer Approval" \
  "Costco" \
  "E2E ProjectManger"

# Pending-approval oversight section (data-dependent on a standing pending entry).
# Same asynchronous-load caveat as above.
tt_wait_text "Pending Approval" "pending-approval section on the PM dashboard"

tt_assert_all "PM dashboard: pending approval" \
  "Pending Approval" \
  "E2E Consultant"

# Approve / Approve All controls render for the pending work (stable selectors).
tt_wait_for ".mx-name-galPMPendingEntries" "PM pending-approval gallery"
playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove').length >= 1)" 2>/dev/null | grep -qiw true \
  || tt_fail "PM dashboard: no .mx-name-btnPMApprove control found"
playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnPMApproveAll'))" 2>/dev/null | grep -qiw true \
  || tt_fail "PM dashboard: no .mx-name-btnPMApproveAll control found"

echo "PASS: PM dashboard shows managed project + pending-approval oversight with Approve controls"
