#!/usr/bin/env bash
# C5 — Cancel really cancels.
#
# Before the change, typing into a day box in the Review & Edit popup committed on
# BLUR, so Cancel did not discard the edit. After the change, Cancel must discard.
#
# Non-destructive: never resubmits, so the rejected entry survives for other cases.

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt692693.sh"

CUSER="${TT_C5_USER:-e2e_consultant2}"
CNAME="${TT_C5_NAME:-E2E Consultant Two}"
PROJECT="${TT_C5_PROJECT:-E2E Sandbox}"
SENTINEL="${TT_C5_SENTINEL:-3}"

tt_make_rejected_entry "$CUSER" "$CNAME" "$PROJECT" || tt_fail "C5 setup: could not produce a rejected entry"
tt_login "$CUSER" "My Timesheets"
[ "$(tt_rejected_count)" != "0" ] || tt_fail "C5: no rejected entry present"

# ---- record the original day values
tt_open_review_edit || tt_fail "C5: could not open Review & Edit"
ORIG="$(tt_popup_day_inputs)"
echo "original day inputs: $ORIG"

# ---- type a sentinel into the first EDITABLE day box, then blur (the old trap)
CHANGED=$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); const ins=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled && /^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); if(!ins.length) return 'noeditable'; const t=ins[0]; t.focus(); const set=Object.getOwnPropertyDescriptor(t.__proto__,'value').set; set.call(t,'$SENTINEL'); t.dispatchEvent(new Event('input',{bubbles:true})); t.dispatchEvent(new Event('change',{bubbles:true})); t.blur(); return 'set'; }" 2>/dev/null | sed -n '2p' | tr -d '"')
if [ "$CHANGED" = "noeditable" ]; then
  echo "SKIP: no editable day box in the popup (expected for a NeedsLineItems entry — that is C4's assertion)"
  tt_click_button_exact "cancel" popup >/dev/null 2>&1
  exit 0
fi
sleep 3
echo "after typing sentinel: $(tt_popup_day_inputs)"

# ---- Cancel
tt_click_button_exact "cancel" popup || tt_fail "C5: no Cancel button in the popup"
sleep 3
tt_dismiss_dialogs
[ "$(tt_popup_open)" = "false" ] || tt_fail "C5: popup did not close on Cancel"

# ---- reload, reopen, compare
tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
[ "$(tt_rejected_count)" != "0" ] || tt_fail "C5: rejected entry vanished after Cancel (it must NOT have been submitted)"
tt_open_review_edit || tt_fail "C5: could not reopen Review & Edit"
NOW="$(tt_popup_day_inputs)"
echo "day inputs after reload: $NOW"
tt_click_button_exact "cancel" popup >/dev/null 2>&1

if [ "$NOW" = "$ORIG" ]; then
  echo "PASS: C5 — Cancel discarded the edit (values unchanged after reload)"
else
  tt_fail "C5 FAIL: Cancel did NOT discard the edit.
  before: $ORIG
  after : $NOW
  (this is the commit-on-blur trap the change is meant to close)"
fi
