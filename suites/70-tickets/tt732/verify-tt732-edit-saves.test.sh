#!/usr/bin/env bash
# Regression test for TT-732 — an existing assignment must be re-savable.
#
# THE BUG. Main.SUB_AssignmentValidation retrieves every other assignment on the same
# project to check for a duplicate consultant. Its constraint used to read
#
#     [Main.Assignment_Project = $Project]
#
# which matches the assignment being edited as well, because that row is already
# committed. So every edit of every existing assignment failed validation against
# ITSELF and was blocked with "Consultant is already assigned to this project."
# Editing an assignment was impossible; the workaround was archive-and-recreate.
#
# THE FIX. The constraint now excludes the object under edit:
#
#     [Main.Assignment_Project = $Project][id != $Assignment]
#
# WHY THIS TEST PRESSES SAVE WITHOUT CHANGING ANYTHING. Main.ACT_SaveConsultantAssignment
# calls SUB_AssignmentValidation on EVERY save and branches on its "Is Valid?" result, so
# the duplicate check runs whether or not a field was edited. A no-op re-save is therefore
# the smallest complete reproduction, and it deliberately avoids typing into cbConsultant,
# dpStartDate or dpEndDate — all three are `editable: Conditional` on this page, so a test
# that typed into them could fail for a reason that has nothing to do with TT-732.
# It also means the test writes nothing it has to clean up.
#
# NOT COVERED HERE: that the guard still rejects a GENUINE duplicate. A "fix" that simply
# deleted the validation would pass this test. That negative case needs two consultants on
# one project, which the 00-setup fixtures do not currently create, and lives in
# verify-tt732-guard-still-fires.test.sh.
#
# Read-only in effect: opens the edit form, re-saves the same values, closes the popups.
# Env: TT_BASE_URL, TT_ROLE_PASS. Needs the 00-setup fixtures (E2E Consultant + assignments).
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

CONSULTANT="${TT732_CONSULTANT:-E2E Consultant}"

# The exact text Main.SUB_AssignmentValidation shows when the duplicate guard fires,
# read verbatim from the model. Matching on a fragment rather than the whole sentence
# so a trailing-whitespace or punctuation tweak does not turn a real regression green.
BLOCK_MSG="already assigned to this project"

# tt732_modal_text — text of the topmost VISIBLE dialog, whitespace collapsed.
# Mendix leaves closed dialogs in the DOM, so this takes the last visible one via the
# shared _tt_dialog_js rather than a bare querySelector, which would happily return a
# corpse. See the tt_clear_dialogs header in lib/_login.sh for how that bit this suite.
tt732_modal_text() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\\s+/g,' ') : ''; }" 2>/dev/null | _tt_eval_str
}

tt732_close_modals() {
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.modal-content button, .modal-header button')].filter(x=>x.offsetParent!==null); if(b.length) b[0].click(); }" >/dev/null 2>&1
  sleep 2
}

# tt732_open_consultant <name> — search the Consultants card and open that consultant's
# details popup.
tt732_open_consultant() {
  local name="$1" r
  fx_view "cardConsultants" "galConsultants" >/dev/null
  fx_search "txtConsultantSearch" "galConsultants" "$name" >/dev/null
  r="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galConsultants'); if(!g) return 'NOGAL'; const c=[...g.querySelectorAll('*')].find(e=>getComputedStyle(e).cursor==='pointer' && (e.innerText||'').indexOf('$name')>=0); if(!c) return 'NOCARD'; c.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
  [ "$r" = "ok" ] || tt_fail "TT-732: could not open the details popup for '$name' ($r) — check the 00-setup fixtures ran"
  sleep 4
}

tt_login "e2e_tm" "Add Customer"

# ------------------------------------------------------- open an existing assignment
tt732_open_consultant "$CONSULTANT"

popup="$(tt732_modal_text)"
[ -n "$popup" ] || tt_fail "TT-732: the Consultant Details popup rendered no text"
case "$popup" in
  *"$CONSULTANT"*) : ;;
  *) tt_fail "TT-732: the open popup is not '$CONSULTANT' — got: ${popup:0:160}" ;;
esac

# Click the first assignment row to reach TitanManager_ConsultantAssignment_Popup.
r="$(playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'NOMODAL'; const lv=d.querySelector('.mx-name-listView1') || d; const c=[...lv.querySelectorAll('*')].find(e=>getComputedStyle(e).cursor==='pointer' && (e.innerText||'').trim().length>0); if(!c) return 'NOROW'; c.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
[ "$r" = "ok" ] || tt_fail "TT-732: no clickable assignment row for '$CONSULTANT' ($r) — the fixtures should give it at least one assignment"
sleep 4

detail="$(tt732_modal_text)"
case "$detail" in
  *"START DATE"*) : ;;
  *) tt_fail "TT-732: the assignment details popup did not open (no START DATE label) — got: ${detail:0:200}" ;;
esac

# Scoped to the popup on purpose: "Edit" also appears behind the modal on the dashboard,
# and an unscoped text click would happily press that one instead.
r="$(playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'NOMODAL'; const b=[...d.querySelectorAll('button, a')].find(e=>(e.innerText||'').trim()==='Edit'); if(!b) return 'NOEDIT'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
[ "$r" = "ok" ] || tt_fail "TT-732: no Edit button on the assignment details popup ($r)"
sleep 2
tt_wait_for ".mx-name-dpStartDate input" "TT-732 assignment edit form"

# Record the dates so the assertion afterwards can prove this really was a no-op save
# and not an edit that happened to succeed.
before_start="$(playwright-cli eval "() => { const e=document.querySelector('.mx-name-dpStartDate input'); return e ? (e.value||'') : 'NOWIDGET'; }" 2>/dev/null | _tt_eval_str)"
[ "$before_start" != "NOWIDGET" ] || tt_fail "TT-732: dpStartDate not found on the edit form"
echo "  edit form open; StartDate reads '$before_start'"

# ------------------------------------------------------------------------ save it
playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
sleep 4

# ASSERTION 1 — the duplicate guard must NOT have fired.
#
# This is the assertion that goes red if the [id != $Assignment] clause is ever removed
# from Main.SUB_AssignmentValidation: the row matches itself again and this dialog
# reappears on every save.
msg="$(tt732_modal_text)"
case "$msg" in
  *"$BLOCK_MSG"*)
    tt_fail "TT-732: saving an UNCHANGED existing assignment was blocked as a duplicate — SUB_AssignmentValidation is matching the row against itself again. Dialog: ${msg:0:200}" ;;
esac

# ASSERTION 2 — the save actually went through.
#
# Assertion 1 alone would pass if the Save button silently did nothing, so this proves
# the form closed, which only happens once ACT_SaveConsultantAssignment reaches its
# Close-page step down the "Is Valid? = true" branch.
still_open="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-dpStartDate'))" 2>/dev/null | _tt_eval_str)"
if [ "$still_open" = "true" ]; then
  tt_fail "TT-732: the edit form is still open after Save and no duplicate dialog appeared — the save did not complete. Last dialog text: ${msg:0:200}"
fi
echo "  ok: Save closed the edit form with no duplicate-assignment block"

# ------------------------------------------------------------- leave it as we found it
tt732_close_modals
tt732_close_modals

echo "PASS: verify-tt732-edit-saves (TT-732) — an existing assignment re-saves without tripping the duplicate-consultant guard"
