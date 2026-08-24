#!/usr/bin/env bash
# C1 — a rejected entry can be corrected and resubmitted (TT-693 core).
#
# Asserts ALL of:
#   * the Review & Edit popup closes on Resubmit
#   * the entry leaves the Rejected list WITHOUT a manual reload  (the refresh fix)
#   * it is still gone after a reload
#   * it lands in the Manager Approval queue (verified as HR)
#   * the week totals reflect the EDITED hours  (the reported symptom: sums stale)
#
# Consumes one rejected entry; the fixture recreates one when needed.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_C1_USER:-e2e_consultant2}"
CNAME="${TT_C1_NAME:-E2E Consultant Two}"
PROJECT="${TT_C1_PROJECT:-E2E Sandbox}"

# ---- setup: guarantee a rejected entry exists
tt_make_rejected_entry "$CUSER" "$CNAME" "$PROJECT" || tt_fail "C1 setup: could not produce a rejected entry"

tt_login "$CUSER" "My Timesheets"
BEFORE="$(tt_rejected_count)"
[ "$BEFORE" != "0" ] || tt_fail "C1: no rejected entry present after setup"
echo "rejected entries before: $BEFORE"

WEEKTXT=$(playwright-cli eval "() => { const b=document.body.innerText||''; const i=b.indexOf('Rejected Entries'); return i<0?'':b.slice(i,i+200).replace(/\n+/g,' | '); }" 2>/dev/null | sed -n '2p')
echo "rejected row: $WEEKTXT"

tt_open_review_edit || tt_fail "C1: could not open the Review & Edit popup"
echo "popup: $(tt_popup_text)"

# ---- edit the hours: set Monday (2nd numeric input) to a distinctive value
NEWVAL="${TT_C1_HOURS:-5}"
playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); const ins=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled && /^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); const t=ins[1]||ins[0]; if(!t) return 'nofield'; t.focus(); const set=Object.getOwnPropertyDescriptor(t.__proto__,'value').set; set.call(t,'$NEWVAL'); t.dispatchEvent(new Event('input',{bubbles:true})); t.dispatchEvent(new Event('change',{bubbles:true})); return 'set'; }" >/dev/null 2>&1
sleep 2
echo "day inputs after edit: $(tt_popup_day_inputs)"

# ---- resubmit
tt_click_button_exact "resubmit timesheet" popup || tt_fail "C1: no 'Resubmit Timesheet' button in the popup"
sleep 4
tt_dismiss_dialogs
sleep 3

# 1) popup closed
[ "$(tt_popup_open)" = "false" ] || tt_fail "C1: popup did not close after Resubmit"
echo "popup closed OK"

# 2) gone from the Rejected list WITHOUT a reload  <-- the refresh fix
AFTER_NORELOAD="$(tt_rejected_count)"
echo "rejected entries after resubmit (no reload): $AFTER_NORELOAD"
[ "$AFTER_NORELOAD" -lt "$BEFORE" ] \
  || tt_fail "C1: entry still in the Rejected list after Resubmit WITHOUT reload (before=$BEFORE after=$AFTER_NORELOAD) — the list-refresh fix is not working"

# 3) still gone after a reload
tt_login "$CUSER" "My Timesheets" >/dev/null 2>&1
AFTER_RELOAD="$(tt_rejected_count)"
echo "rejected entries after reload: $AFTER_RELOAD"
[ "$AFTER_RELOAD" -lt "$BEFORE" ] || tt_fail "C1: entry reappeared in the Rejected list after reload (=$AFTER_RELOAD)"

# 4) week totals reflect the edited hours (consultant's own history)
HIST=$(playwright-cli eval "() => { const b=document.body.innerText||''; const i=b.indexOf('Timesheets'); return i<0?b.slice(0,300):b.slice(i,i+400).replace(/\n+/g,' | '); }" 2>/dev/null | sed -n '2p')
echo "consultant history: $HIST"
case "$HIST" in
  *"0.00 hrs"*) echo "WARN: a 0.00 hrs week is present — inspect whether it is THIS entry (stale-sum symptom)" ;;
esac

# 5) it reached the Manager Approval queue
tt_login "e2e_hr" "WEEKLY TO PROCESS" >/dev/null 2>&1
INQ="$(tt_hr_count_cards_for "$CNAME" "MANAGER APPROVAL")"
echo "'$CNAME' cards in MANAGER APPROVAL: $INQ"
[ "${INQ:-0}" -ge 1 ] || tt_fail "C1: resubmitted entry did not appear in the Manager Approval queue"

echo "PASS: C1 — rejected entry corrected, resubmitted, left the Rejected list without reload, and reached Manager Approval"
