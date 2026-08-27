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

# ------------------------------------------------------- managed-project card
#
# The card comes from Main.DS_ProjectsManaged through the gallery in
# Main.SNIP_ProjectsDashboardView, and that gallery is VIRTUAL SCROLLING with a
# page size of THREE. Main.DS_ProjectsManaged sorts createdDate DESCENDING, so the
# cards on screen are the three NEWEST projects this PM manages. 'E2E Customer
# Approval' is older than that, so it is not in the initial DOM at all.
#
# This test previously waited 20s for that text and the failure was read as a
# rendering delay -- it never was one. Waiting cannot help; only scrolling the
# gallery's own .widget-gallery-content box loads the next page. See the gallery
# paging section of lib/_login.sh.
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
# Data-dependent on a standing pending entry, and asynchronously loaded like the
# gallery above — wait before asserting.
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
