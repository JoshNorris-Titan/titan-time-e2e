#!/usr/bin/env bash
# TT-721 — the PROJECT-side assignment period must render MM/DD/YYYY.
#
# WHY A SECOND TT-721 TEST. TT-721 reformatted five surfaces. The suite's other TT-721
# test (suites/50-titan-manager/verify-tt721-date-format.test.sh) covers three of them —
# the Consultant Details period string, the assignment details popup, and the edit form —
# and documents a fourth, Main.Assignment_Overview, as unreachable.
#
# The fifth is Main.DS_Assignment_ProjectStatus, and nothing covered it. It is a SEPARATE
# microflow from the consultant-side DS_Assignment_ConsultantStatus that the other test
# reads: same four 'MMM dd YYYY' -> 'MM/dd/yyyy' edits, made on the project side, feeding
# the assignment list on Main.Project_Details_TitanManager. A revert of just that one
# microflow would leave the existing TT-721 test green.
#
# Period is a STRING built inside the microflow, so nothing on the page can change its
# shape — a date format on the widget that displays it is inert. That is why this asserts
# on rendered text rather than on a widget property.
#
# The assertion has two halves on purpose. Matching MM/DD/YYYY alone would pass on a popup
# that rendered no dates at all, so the test also proves the popup is the right one and
# that the OLD month-name shape is gone.
#
# The popup's assignment list is an auto-named widget (listView1), which this suite's
# selector rule forbids relying on, so this reads the whole modal's text instead.
#
# Read-only: opens a project popup and reads it. Env: TT_BASE_URL, TT_ROLE_PASS.
# Needs the 00-setup fixtures (E2E Manager Approval, with an assignment on it).
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

PROJECT="${TT721_PROJECT:-E2E Manager Approval}"

NEW_RE='[0-9]{2}/[0-9]{2}/[0-9]{4}'
# The shape TT-721 removed: a three-letter month followed by a day number. Spelled out
# rather than [A-Z][a-z]{2} so it cannot collide with an ordinary capitalised word before
# a number — a project called "Sandbox 2026", say.
OLD_RE='(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ?[0-9]{1,2}'

# tt721p_modal_text — text of the topmost VISIBLE dialog, whitespace collapsed. Uses the
# shared _tt_dialog_js because Mendix leaves closed dialogs in the DOM and a bare
# querySelector can hand back a dead one.
tt721p_modal_text() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\\s+/g,' ') : ''; }" 2>/dev/null | _tt_eval_str
}

tt721p_close_modals() {
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.modal-content button, .modal-header button')].filter(x=>x.offsetParent!==null); if(b.length) b[0].click(); }" >/dev/null 2>&1
  sleep 2
}

tt_login "e2e_tm" "Add Customer"

# --------------------------------------------------------- open the project's popup
fx_view "cardProjects" "galProjects" >/dev/null
fx_search "txtProjectSearch" "galProjects" "$PROJECT" >/dev/null

r="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galProjects'); if(!g) return 'NOGAL'; const c=[...g.querySelectorAll('*')].find(e=>getComputedStyle(e).cursor==='pointer' && (e.innerText||'').indexOf('$PROJECT')>=0); if(!c) return 'NOCARD'; c.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
[ "$r" = "ok" ] || tt_fail "TT-721: could not open the project popup for '$PROJECT' ($r) — check the 00-setup fixtures ran"
sleep 4

popup="$(tt721p_modal_text)"
[ -n "$popup" ] || tt_fail "TT-721: the Project Details popup rendered no text"
case "$popup" in
  *"$PROJECT"*) : ;;
  *) tt_fail "TT-721: the open popup is not '$PROJECT' — got: ${popup:0:160}" ;;
esac

# ------------------------------------------------------------------- the assertions
echo "$popup" | grep -Eq "$NEW_RE - $NEW_RE" \
  || tt_fail "TT-721: no 'MM/DD/YYYY - MM/DD/YYYY' assignment period in the Project Details popup — DS_Assignment_ProjectStatus not updated? Got: ${popup:0:240}"

if echo "$popup" | grep -Eq "$OLD_RE"; then
  tt_fail "TT-721: the Project Details popup still shows a month-name date — DS_Assignment_ProjectStatus is building the old 'MMM dd YYYY' shape. Got: ${popup:0:240}"
fi
echo "  ok: Project Details assignment period is MM/DD/YYYY"

tt721p_close_modals

echo "PASS: verify-tt721-project-details-period (TT-721) — the project-side assignment period (DS_Assignment_ProjectStatus) renders MM/DD/YYYY"
