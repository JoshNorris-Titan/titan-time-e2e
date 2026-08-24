#!/usr/bin/env bash
# TT-654 A3 — the NeedsLineItems branch of Main.SUB_AssignmentEntry_Submit.
#
# ── WHAT CHANGED ABOUT THIS TEST, AND WHY ───────────────────────────────────────
# This test used to drive the timesheet grid's .mx-name-btnSubmit and claim it
# was covering the extraction. It was not. In Main.SNIP_Timesheet that button is
# `show_page Main.Confirmation_timesheet` -> Main.ACT_Timesheet_Precheck ->
# Main.ACT_Timesheet_Submit, which is the WEEKLY submit and keeps its own inline
# line-items handling. Main.ACT_AssignmentEntry_Submit — the microflow that was
# gutted into Main.SUB_AssignmentEntry_Submit — is referenced from exactly one
# widget in the whole model: the "Resubmit Timesheet" button on
# Main.AssignmentEntry_RejectionReview. So the only way to reach the refactored
# sub from the UI is a REJECTED entry's resubmit, which is what this now does.
# ────────────────────────────────────────────────────────────────────────────────
#
# The branch under test: when AssignmentEntry/NeedsLineItems is true,
# Main.SUB_AssignmentEntry_Submit does four extra things before committing the
# change log —
#   retrieve the LineItems -> commit them -> Main.SUB_LineItem_ToString ->
#   write the result onto ChangeLog.LineItems
# Those four activities were transcribed during the extraction and have never
# run: verify-tt692693-c1-resubmit (the only other test on this path) uses
# "E2E Sandbox", which is not a line-items project.
#
# The MCP SubmitWeek tool deliberately REFUSES line-items projects — that
# refusal is asserted separately by verify-tt654-a7 — so the resubmit popup is
# the only route to this branch.
#
# Asserts:
#   - a rejected line-items entry can be resubmitted from the Review & Edit popup
#   - the popup closes and the entry leaves the Rejected list (the sub ran and
#     returned OK; NOT_EDITABLE or a save failure would leave it in place)
#   - it reaches an approval queue, i.e. the status expression ran too
#
# Does NOT assert ChangeLog.LineItems content — that is not on screen. Check it
# on a local F5 with tests/oql-changelog-attribution.sh.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"
source "$TT_ROOT/lib/_tt692693.sh"

PROJ="$TT654_PROJECT_LINEITEMS"
CUSER="$TT654_CONSULTANT"
CNAME="${TT654_CONSULTANT_NAME:-E2E Consultant}"

# ------------------------------------------------------------- local helpers
#
# tt_make_rejected_entry (lib/_tt692693.sh) cannot seed this project: it fills
# the aggregate day cells directly, and on a NeedsLineItems row those are
# read-only — hours come from the task rows. So the seed below uses the TT-654
# line-item helpers instead.
#
# Both helpers target the card/row by PROJECT as well as by consultant. The
# weekly Submit submits every assignment row on the week at once, so this
# consultant will usually have several entries in flight, and a
# first-match-by-name helper would happily reject or reopen the wrong one — a
# run that proves nothing while reporting green.

# hr_reject_card_for_project <consultant> <project> <tab>
hr_reject_card_for_project() {
  local who="$1" proj="$2" tab="$3" lbl labels opened=""
  tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
  tt_click_text "$tab" "HR '$tab' tab"
  sleep 3
  labels=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - /.test(t)))]; return s.join('|'); }" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//')
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
    sleep 3
    if playwright-cli eval "() => { const vs=[...document.querySelectorAll('.mx-name-btnView, button')].filter(b=>/^view/i.test((b.innerText||'').trim())); for(const v of vs){ let el=v; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<500 && t.indexOf('$proj')>=0 && t.split('\n')[0].trim()==='$who'){ v.click(); return 'ok'; } } } return 'nf'; }" 2>/dev/null | grep -qiw ok; then
      opened=1; echo "  (rejecting '$proj' in week $lbl)"; break
    fi
    IFS='|'
  done
  unset IFS
  [ -n "$opened" ] || return 1
  sleep 4
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return 'nopopup'; const ta=d.querySelector('textarea') || [...d.querySelectorAll('input[type=text]')].pop(); if(ta){ const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'E2E automated reject for TT-654 A3'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); return 'typed'; } return 'nofield'; }" >/dev/null 2>&1
  sleep 1
  tt_click_button_exact "reject" popup || return 1
  sleep 3
  tt_dismiss_dialogs
  return 0
}

# open_review_for_project <project> — open Review & Edit for the rejected entry
# belonging to <project>, not merely the first rejected entry on the dashboard.
open_review_for_project() {
  local proj="$1"
  playwright-cli eval "() => { const bs=[...document.querySelectorAll('.mx-name-btnReviewRejected')]; for(const b of bs){ let el=b; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<500 && t.indexOf('$proj')>=0){ b.click(); return 'ok'; } } } return 'nf'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok || return 1
  sleep 4
  [ "$(tt_popup_open)" = "true" ]
}

# ---------------------------------------------------------------- 1) fixture
# Seed a line-items week: hours live on the task row, not the day cells.
tt_login "$CUSER" "My Timesheets"
tt654_find_editable_row "$PROJ"
ORD="$TT654_ORD"
WEEK="$TT654_WEEK"
echo "seeding '$PROJ' on week: ${WEEK:-<unknown>} (row $ORD)"
tt654_fill_row "$ORD" "$TT654_HOURS"
TASK_IDX="$(tt654_add_task "$ORD" "TT654 A3 LineItem Task" "$TT654_HOURS")"
echo "added task #$TASK_IDX"
tt654_save_draft

ORD="$(tt654_row_ordinal "$PROJ")"
[ -n "$ORD" ] && [ "$ORD" != "0" ] || tt_fail "'$PROJ' row is no longer editable after Save Draft — nothing to submit"
tt654_submit_row "$ORD" >/dev/null 2>&1 || true

# Reject it so the resubmit path becomes reachable. The project may sit in
# either approval queue depending on its flags, so try both.
REJECTED=""
for TAB in "MANAGER APPROVAL" "CLIENT APPROVAL"; do
  for _ in 1 2 3; do
    if hr_reject_card_for_project "$CNAME" "$PROJ" "$TAB"; then REJECTED=1; break; fi
    sleep 6
  done
  [ -n "$REJECTED" ] && break
done
[ -n "$REJECTED" ] \
  || tt_fail "HR could not find a '$PROJ' card for '$CNAME' to reject in either approval queue — without a rejected entry the resubmit path (the only caller of Main.ACT_AssignmentEntry_Submit) cannot be reached"

tt_login "$CUSER" "My Timesheets"
BEFORE="$(tt_rejected_count)"
[ "$BEFORE" != "0" ] || tt_fail "no rejected entry present after the fixture ran"
echo "rejected entries before resubmit: $BEFORE"

# ------------------------------------------------- 2) resubmit via the popup
open_review_for_project "$PROJ" \
  || tt_fail "no Review & Edit control for a rejected '$PROJ' entry — the fixture rejected something else, so this run would exercise the non-line-items path and report a misleading pass"
POPUP="$(tt_popup_text)"
echo "popup: $POPUP"

case "$POPUP" in
  *"$PROJ"*) : ;;
  *) tt_fail "the Review & Edit popup is not showing the '$PROJ' entry (got: ${POPUP:0:200})" ;;
esac

tt_click_button_exact "resubmit timesheet" popup \
  || tt_fail "no 'Resubmit Timesheet' button in the popup — that button is the only caller of Main.ACT_AssignmentEntry_Submit"
sleep 4
tt_dismiss_dialogs
sleep 3

[ "$(tt_popup_open)" = "false" ] \
  || tt_fail "the popup did not close after Resubmit — Main.ACT_AssignmentEntry_Submit did not reach its 'close page', so SUB_AssignmentEntry_Submit returned something other than OK (a required field on Main.ChangeLog in the line-items branch would do this)"
echo "popup closed"

# ------------------------------------------------------------- 3) it submitted
AFTER="$(tt_rejected_count)"
echo "rejected entries after resubmit: $AFTER"
[ "$AFTER" -lt "$BEFORE" ] \
  || tt_fail "the '$PROJ' entry is still in the Rejected list (before=$BEFORE after=$AFTER) — the line-items branch of SUB_AssignmentEntry_Submit did not complete"

# Still gone after a real re-fetch, i.e. it committed rather than just repainting.
tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
RELOADED="$(tt_rejected_count)"
[ "$RELOADED" -lt "$BEFORE" ] \
  || tt_fail "the entry reappeared in the Rejected list after reload (=$RELOADED) — the commit inside the line-items branch rolled back"

# ------------------------------------------------ 4) the status expression ran
tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
INQ="$(tt_hr_count_cards_for "$CNAME" "MANAGER APPROVAL")"
echo "'$CNAME' cards in MANAGER APPROVAL: $INQ"
[ "${INQ:-0}" -ge 1 ] \
  || tt_fail "the resubmitted line-items entry did not reach an approval queue — SUB_AssignmentEntry_Submit's status expression did not route it"

echo "PASS: verify-tt654-a3-lineitems-submit — the NeedsLineItems branch of SUB_AssignmentEntry_Submit ran end to end via the resubmit path"
