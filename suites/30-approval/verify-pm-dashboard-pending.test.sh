#!/usr/bin/env bash
# Project Manager dashboard — managed project + pending-approval oversight.
#
# Verifies that a PM logging in sees the project they manage (with its details)
# and the "Pending Approval" section listing submitted entries with Approve /
# Approve All controls. This is a read-only oversight check — it does NOT click
# Approve (that would consume the entry). Uses the stable post-naming selectors
# galPMPendingEntries / btnPMApprove / btnPMApproveAll.
#
# Data dependency: the pending-approval assertions need one entry sitting at the
# MANAGER-approval stage on a project e2e_pm manages, and this test seeds one when
# the queue is empty. It never approves, so what it seeds stays standing.
#
# It used to rely on a pool it does not own, and the comment naming that pool was
# wrong twice over. Main.DS_ApprovalHelper_PM feeds galPMPendingEntries from the
# MANAGER stage; verify-customer-approval-flow's standing entries sit at the CLIENT
# stage and never appear here at all. The only sibling that puts an entry in THIS
# queue is verify-pm-approve-action, which seeds one and then approves it -- and it
# runs first alphabetically, so it hands this test an empty queue by design.
# Measured on dev 2026-09-02, both this gallery and HR's MANAGER APPROVAL tab held
# zero cards: the queue really was empty, which is the answer the test should seed
# its way out of rather than assert against.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_pm" "Project Manager Dashboard"

# ------------------------------------------------------- managed-project card
#
# The card comes from Main.DS_ProjectsManaged through the projects gallery, which
# the snippet fold moved out of Main.SNIP_ProjectsDashboardView and into
# Main.ProjectManagerDashboard under foldProjectsDashboardView. That gallery is
# PAGED, and it has been paged two different ways: virtual scrolling with pageSize 3
# until model commit b05c11d2 ("layout grid changes"), Load more with pageSize 25
# since. Main.DS_ProjectsManaged sorts createdDate DESCENDING, so at pageSize 3 the
# cards on screen were the three NEWEST projects this PM manages and 'E2E Customer
# Approval' was not in the DOM at all.
#
# This test has now failed once for each mode, and neither failure was what it
# looked like. First it waited 20s for that text and the timeout was read as a
# rendering delay -- waiting could never have helped, only paging. Then the paging
# helper hard-required the virtual-scrolling content box and died at its own guard
# on a gallery that was already showing every card it had. tt_gallery_load_until_text
# now pages whichever way the gallery offers; see the gallery paging section of
# lib/_login.sh.
#
# SCOPING. The projects gallery widget is still auto-named (gallery1) and the suite
# never depends on auto-generated names. galPMPendingEntries IS named, so scope by
# exclusion: the projects gallery is the gallery on this page that is not the
# pending one. Mark it once, then address the mark -- that stays correct whether or
# not Mendix puts the mx-name class on the same node as .widget-gallery.
GAL='[data-tt-gallery=pmprojects]'

pm_mark_projects_gallery() {
  playwright-cli eval "() => { const gs = [...document.querySelectorAll('.widget-gallery')].filter(g => !g.closest('.mx-name-galPMPendingEntries')); document.querySelectorAll('[data-tt-gallery]').forEach(g => g.removeAttribute('data-tt-gallery')); if (gs.length === 1) { gs[0].setAttribute('data-tt-gallery', 'pmprojects'); } return String(gs.length); }" 2>/dev/null | _tt_eval_str
}

marked=""
for _ in $(seq 1 20); do
  marked="$(pm_mark_projects_gallery)"
  [ "$marked" = "1" ] && break
  sleep 1
done
[ "$marked" = "1" ] \
  || tt_fail "PM dashboard: expected exactly one gallery that is not galPMPendingEntries (the managed-projects list); found [$marked] after 20s. Either the projects gallery never rendered, or Main.ProjectManagerDashboard gained another gallery — re-scope this test rather than letting it guess."

tt_gallery_load_until_text "$GAL" "E2E Customer Approval" "pm-dashboard projects"
echo "  [pm-dashboard projects] $(tt_gallery_titles "$GAL")"

# Assert the details ON THE CARD, not anywhere on the page. Costco also owns E2E
# Dual Approval, and every card shows the same project manager, so a body-wide check
# for 'Costco' or 'E2E ProjectManger' passes even when the card under test is
# missing entirely — an assertion that cannot fail, which is the trap this suite
# exists to stay out of.
card="$(playwright-cli eval "() => { const c = [...document.querySelectorAll('$GAL .widget-gallery-item')].find(e => (e.innerText || '').indexOf('E2E Customer Approval') >= 0); return c ? (c.innerText || '').replace(/\s+/g, ' ').trim() : 'NOCARD'; }" 2>/dev/null | _tt_eval_str)"

[ "$card" != "NOCARD" ] \
  || tt_fail "PM dashboard: the gallery reported 'E2E Customer Approval' loaded, but no single card contains it — the card template has changed shape"

for want in "Costco" "E2E ProjectManger"; do
  case "$card" in
    *"$want"*) ;;
    *) tt_fail "PM dashboard: the 'E2E Customer Approval' card does not show '$want'. The card reads: $card" ;;
  esac
done
echo "  [pm-dashboard card] $card"

tt_assert_all "PM dashboard: header" "Project Manager Dashboard"

# ------------------------------------------------ pending-approval oversight
#
# Asynchronously loaded like the gallery above, so wait before asserting. Also PAGED
# (Load more, pageSize 25), so page it in before reading it: an unpaged read answers
# "is the entry on the first page", not "is it in the queue".
tt_wait_text "Pending Approval" "pending-approval section on the PM dashboard"
tt_wait_for ".mx-name-galPMPendingEntries" "PM pending-approval gallery"

PENDING_PROJECT="E2E Manager Approval"

# How many entries the PM's queue is currently offering to approve. Counting the
# Approve buttons rather than the cards keeps this the same question the assertions
# below ask.
pm_pending_count() {
  tt_gallery_load_all ".mx-name-galPMPendingEntries" "PM pending queue" >/dev/null
  playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove').length)" 2>/dev/null | _tt_eval_str
}

pm_open_dashboard() {
  tt_login "e2e_pm" "Project Manager Dashboard"
  tt_wait_for ".mx-name-galPMPendingEntries" "PM pending-approval gallery"
}

# Seed one, the same way verify-pm-approve-action does and for the same reason:
# nothing upstream guarantees this queue is non-empty. Workflow routing into it is
# async, so poll rather than assert on the first look.
if [ "$(pm_pending_count)" = "0" ]; then
  echo "  [pm-dashboard pending] queue is empty -- seeding one '$PENDING_PROJECT' entry as the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_project_row "$PENDING_PROJECT"
  for _ in 1 2 3 4 5 6; do
    pm_open_dashboard
    [ "$(pm_pending_count)" != "0" ] && break
    sleep 6
  done
fi

[ "$(pm_pending_count)" != "0" ] \
  || tt_fail "PM dashboard: the pending-approval queue is empty and seeding a '$PENDING_PROJECT' entry did not fill it. Check HR's MANAGER APPROVAL tab: if that is empty too the entry never routed to the manager stage (a submit/routing problem); if it holds the entry and this gallery does not, Main.DS_ApprovalHelper_PM is not returning it to e2e_pm."

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
