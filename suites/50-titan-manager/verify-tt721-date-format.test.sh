#!/usr/bin/env bash
# Regression test for TT-721 — assignment dates must render MM/DD/YYYY (08/23/2026).
#
# Before TT-721 the same date appeared in three different shapes depending on which
# surface you were looking at, because Titan Time has no app-wide date setting and
# every format is set per widget or per expression:
#
#   Assignment_NewEdit          date pickers, custom format "MMM dd, yyyy"  -> Aug 23, 2026
#   ConsultantAssignment_Popup  text params, "MMM dd" and "MMM dd, YYYY"    -> Aug 23 / Aug 23, 2026
#   DS_Assignment_*Status       formatDateTimeUTC(..., 'MMM dd YYYY')       -> Aug 23 2026
#
# This asserts all three now read MM/DD/YYYY, and — just as important — that none of
# them still reads in the old month-name shape. A pattern check alone would pass on a
# surface that renders nothing at all, so every assertion below also proves the text
# it matched was actually there.
#
# NOT COVERED: Main.Assignment_Overview. That grid's Start date / End date columns
# were changed too, but the page has no navigation entry and no URL, so there is no
# supported way to reach it from a signed-in session. Check it by hand from the
# Administrator dashboard, or give the page a URL and extend this test.
#
# Read-only: opens the edit form to read the pickers, then cancels. Env: TT_BASE_URL,
# TT_ROLE_PASS. Needs the 00-setup fixtures (E2E Consultant + its assignments).
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

CONSULTANT="${TT721_CONSULTANT:-E2E Consultant}"

NEW_RE='[0-9]{2}/[0-9]{2}/[0-9]{4}'
# The shape TT-721 removed: a three-letter month followed by a day number. Written
# out rather than [A-Z][a-z]{2} so it cannot collide with an ordinary capitalised
# word ahead of a number (a project called "Sandbox 2026", say).
OLD_RE='(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ?[0-9]{1,2}'

# tt721_modal_text — text of the topmost visible modal, whitespace collapsed.
tt721_modal_text() {
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; return d ? (d.innerText||'').replace(/\\s+/g,' ') : ''; }" 2>/dev/null | _tt_eval_str
}

tt721_close_modals() {
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.modal-content button, .modal-header button')].filter(x=>x.offsetParent!==null); if(b.length) b[0].click(); }" >/dev/null 2>&1
  sleep 2
}

# tt721_open_consultant <name> — search the Consultants card and click that card,
# leaving the Consultant Details popup open.
tt721_open_consultant() {
  local name="$1" r
  fx_view "cardConsultants" "galConsultants" >/dev/null
  fx_search "txtConsultantSearch" "galConsultants" "$name" >/dev/null
  r="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galConsultants'); if(!g) return 'NOGAL'; const c=[...g.querySelectorAll('*')].find(e=>getComputedStyle(e).cursor==='pointer' && (e.innerText||'').indexOf('$name')>=0); if(!c) return 'NOCARD'; c.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
  [ "$r" = "ok" ] || tt_fail "TT-721: could not open the details popup for '$name' ($r) — check the 00-setup fixtures ran"
  sleep 4
}

tt_login "e2e_tm" "Add Customer"

# ---------------------------------------------------------------- A. Period string
#
# AssignmentViewHelper.Period is built in Main.DS_Assignment_ConsultantStatus and
# rendered in the popup's assignment list. It is a STRING, so the only thing that can
# change its shape is the microflow expression — a date format on the widget showing
# it is inert.
tt721_open_consultant "$CONSULTANT"
popup="$(tt721_modal_text)"
[ -n "$popup" ] || tt_fail "TT-721: the Consultant Details popup rendered no text"

case "$popup" in
  *"$CONSULTANT"*) : ;;
  *) tt_fail "TT-721: the open popup is not '$CONSULTANT' — got: ${popup:0:160}" ;;
esac

echo "$popup" | grep -Eq "$NEW_RE - $NEW_RE" \
  || tt_fail "TT-721: no 'MM/DD/YYYY - MM/DD/YYYY' period in the Consultant Details popup — got: ${popup:0:240}"
if echo "$popup" | grep -Eq "$OLD_RE"; then
  tt_fail "TT-721: the Consultant Details popup still shows a month-name date (DS_Assignment_ConsultantStatus not updated?) — got: ${popup:0:240}"
fi
echo "  ok: Consultant Details popup period is MM/DD/YYYY"

# ------------------------------------------------- B. Assignment details popup
#
# Clicking an assignment row opens Main.TitanManager_ConsultantAssignment_Popup.
# Its two date widgets are auto-named (text9 / text10), which is exactly the kind of
# name that renumbers when the page is edited, so this anchors on the STATIC labels
# next to them instead.
#
# Find the row by ROLE, not by cursor. A Mendix clickable list-view row renders as
# <li role="button"> with an onclick and a computed cursor of *default* — Atlas puts
# the pointer on gallery CARDS, not on list-view rows. The cursor==='pointer' probe
# that opens the consultant popup a few lines up works for exactly that reason, and
# copying it down here found nothing: the four assignment rows are present and
# clickable, but the only pointer element in the whole modal is not a row. That is
# what NOROW was reporting, on every run since this test was written.
r="$(playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; if(!d) return 'NOMODAL'; const lv=d.querySelector('.mx-name-listView1') || d; const c=[...lv.querySelectorAll('li[role=button]')].find(e=>e.offsetParent!==null && (e.innerText||'').trim().length>0); if(!c) return 'NOROW'; c.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
[ "$r" = "ok" ] || tt_fail "TT-721: no clickable assignment row in the Consultant Details popup ($r)"
sleep 4

detail="$(tt721_modal_text)"
case "$detail" in
  *"START DATE"*) : ;;
  *) tt_fail "TT-721: the assignment details popup did not open (no START DATE label) — got: ${detail:0:200}" ;;
esac

# Assert the token that FOLLOWS each label, not merely that the popup contains some
# date somewhere. START DATE previously rendered "MMM dd" with no year at all, so a
# whole-popup match would have been satisfied by the END DATE field alone.
for label in "START DATE" "END DATE"; do
  after="${detail#*"$label" }"
  token="${after%% *}"
  echo "$token" | grep -Eq "^$NEW_RE$" \
    || tt_fail "TT-721: '$label' on the assignment popup reads '$token', expected MM/DD/YYYY"
done
echo "  ok: assignment popup START DATE and END DATE are MM/DD/YYYY"

# --------------------------------------------------------- C. the edit form
#
# dpStartDate / dpEndDate are explicitly named, and their custom date format is what
# the picker uses to PARSE typed input as well as to display — which is why
# lib/_fixtures.sh has to type its dates in this same shape.
# Scoped to the popup on purpose: "Edit" also appears behind the modal on the
# dashboard, and tt_click_text would happily click that one instead.
r="$(playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; if(!d) return 'NOMODAL'; const b=[...d.querySelectorAll('button, a')].find(e=>(e.innerText||'').trim()==='Edit'); if(!b) return 'NOEDIT'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
[ "$r" = "ok" ] || tt_fail "TT-721: no Edit button on the assignment details popup ($r)"
sleep 2
tt_wait_for ".mx-name-dpStartDate input" "TT-721 assignment edit form"

for w in dpStartDate dpEndDate; do
  v="$(playwright-cli eval "() => { const e=document.querySelector('.mx-name-$w input'); return e ? (e.value||'') : 'NOWIDGET'; }" 2>/dev/null | _tt_eval_str)"
  [ "$v" != "NOWIDGET" ] || tt_fail "TT-721: $w not found on the assignment edit form"
  [ -n "$v" ] || tt_fail "TT-721: $w is empty — pick an assignment that has both dates set (TT721_CONSULTANT)"
  echo "$v" | grep -Eq "^$NEW_RE$" \
    || tt_fail "TT-721: $w reads '$v', expected MM/DD/YYYY"
done
echo "  ok: dpStartDate and dpEndDate display MM/DD/YYYY"

# Leave the app as we found it: cancel out of the form and close the popups.
playwright-cli click ".mx-name-btnCancel" >/dev/null 2>&1
sleep 2
tt721_close_modals
tt721_close_modals

echo "PASS: verify-tt721-date-format (TT-721) — assignment dates render MM/DD/YYYY on the period string, the details popup and the edit form"
