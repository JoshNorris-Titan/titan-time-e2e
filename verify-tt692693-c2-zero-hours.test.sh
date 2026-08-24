#!/usr/bin/env bash
# C2 — zero-hours resubmit routes to PROCESS (HR), not "Awaiting Manager Approval".
#
# Before the change the entry DISPLAYED "Awaiting Manager Approval" while the only
# live task was HR's Process task. So this checks BOTH: the status shown to the
# consultant AND the queue it actually lands in — and that they agree.

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt692693.sh"

CUSER="${TT_C2_USER:-e2e_consultant2}"
CNAME="${TT_C2_NAME:-E2E Consultant Two}"
PROJECT="${TT_C2_PROJECT:-E2E Sandbox}"

TT_FORCE_NEW_REJECT=1 tt_make_rejected_entry "$CUSER" "$CNAME" "$PROJECT" \
  || tt_fail "C2 setup: could not produce a rejected entry"

tt_login "$CUSER" "My Timesheets"
BEFORE="$(tt_rejected_count)"
[ "$BEFORE" != "0" ] || tt_fail "C2: no rejected entry present"

tt_open_review_edit || tt_fail "C2: could not open Review & Edit"

# zero every editable day box
ZEROED=$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); const ins=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled && /^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); const set=(t,v)=>{ t.focus(); Object.getOwnPropertyDescriptor(t.__proto__,'value').set.call(t,v); t.dispatchEvent(new Event('input',{bubbles:true})); t.dispatchEvent(new Event('change',{bubbles:true})); }; ins.forEach(i=>set(i,'0')); return String(ins.length); }" 2>/dev/null | sed -n '2p' | tr -d '"')
echo "zeroed $ZEROED day box(es)"
sleep 2
echo "day inputs now: $(tt_popup_day_inputs)"

tt_click_button_exact "resubmit timesheet" popup || tt_fail "C2: no Resubmit button"
sleep 4
tt_dismiss_dialogs
sleep 3
[ "$(tt_popup_open)" = "false" ] || tt_fail "C2: popup did not close"

# status shown to the consultant
tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
HIST=$(playwright-cli eval "() => { const b=document.body.innerText||''; const i=b.indexOf('Timesheets'); return i<0?'':b.slice(i,i+400).replace(/\n+/g,' | '); }" 2>/dev/null | sed -n '2p')
echo "consultant sees: $HIST"

# which queue did it actually land in?
tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
INMGR="$(tt_hr_count_cards_for "$CNAME" "MANAGER APPROVAL")"
INPROC="$(tt_hr_count_cards_for "$CNAME" "WEEKLY TO PROCESS")"
echo "'$CNAME' in MANAGER APPROVAL=$INMGR  |  in WEEKLY TO PROCESS=$INPROC"

FAILS=""
[ "${INPROC:-0}" -ge 1 ] || FAILS="$FAILS not-in-process-queue"
case "$HIST" in
  *"Awaiting Manager Approval"*)
    [ "${INMGR:-0}" -ge 1 ] || FAILS="$FAILS shows-AwaitingManagerApproval-but-not-in-manager-queue" ;;
esac

[ -z "$FAILS" ] || tt_fail "C2 FAIL:$FAILS
  consultant history: $HIST
  MANAGER APPROVAL=$INMGR  WEEKLY TO PROCESS=$INPROC
  (expected: zero-hours resubmit -> Process/HR queue, and the displayed status must match the real queue)"

echo "PASS: C2 — zero-hours resubmit routed to the Process queue and the displayed status matches"
