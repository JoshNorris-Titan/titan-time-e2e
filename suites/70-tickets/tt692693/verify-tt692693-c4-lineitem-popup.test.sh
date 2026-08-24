#!/usr/bin/env bash
# C4 — line-item entry: aggregate day boxes are LOCKED, line items are EDITABLE.
#
# Baseline captured pre-change on a non-line-item entry: day boxes readonly =
# [false x7, true] (only TotalHours locked) and NO line-item editor in the popup.
# After the change, for a NeedsLineItems entry the popup must instead show:
#   * aggregate day boxes read-only / not editable
#   * a line-item editor (view/add/edit/delete)
# and correcting via the line items must re-derive the day values + totals.
#
# Requires a REJECTED entry on a NeedsLineItems project (E2E Line Items).

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CUSER="${TT_C4_USER:-e2e_consultant}"
CNAME="${TT_C4_NAME:-E2E Consultant}"
PROJECT="${TT_C4_PROJECT:-E2E Line Items}"

tt_make_rejected_entry "$CUSER" "$CNAME" "$PROJECT" \
  || tt_fail "C4 setup: could not produce a rejected entry on '$PROJECT' (NeedsLineItems)"

tt_login "$CUSER" "My Timesheets"
[ "$(tt_rejected_count)" != "0" ] || tt_fail "C4: no rejected entry present"

# Confirm the rejected row really is the line-items project.
ROWTXT=$(playwright-cli eval "() => { const b=document.body.innerText||''; const i=b.indexOf('Rejected Entries'); return i<0?'':b.slice(i,i+250).replace(/\n+/g,' | '); }" 2>/dev/null | sed -n '2p')
echo "rejected row: $ROWTXT"
case "$ROWTXT" in
  *"$PROJECT"*) ;;
  *) echo "WARN: the rejected entry does not look like '$PROJECT' — C4 assertions may not apply" ;;
esac

tt_open_review_edit || tt_fail "C4: could not open Review & Edit"
echo "popup: $(tt_popup_text)"

DAYS="$(tt_popup_day_inputs)"
echo "day inputs: $DAYS"

# 1) aggregate day boxes must be read-only.
EDITABLE=$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); const ins=[...d.querySelectorAll('input')].filter(i=>i.offsetParent!==null && /^\s*-?[0-9]*\.?[0-9]*\s*$/.test(i.value||'')); const lineish=(i)=>{ let p=i; for(let k=0;k<8;k++){ if(!p) break; const c=(p.className||'').toString(); if(/txtLine|LineItem/i.test(c)) return true; p=p.parentElement; } return false; }; const agg=ins.filter(i=>!lineish(i)); return String(agg.filter(i=>!i.readOnly && !i.disabled).length); }" 2>/dev/null | sed -n '2p' | tr -d '"')
echo "editable aggregate day boxes: $EDITABLE"

# 2) a line-item editor must be present.
LINEED=$(playwright-cli eval "() => { const d=document.querySelector('[role=dialog], .mx-dialog, .modal-dialog, .mx-window'); if(!d) return '{}'; return JSON.stringify({ lineWidgets: !!d.querySelector('[class*=txtLine],[class*=LineItem],[class*=btnAddTask]'), addTaskBtn: !!d.querySelector('.mx-name-btnAddTask'), mentionsTask: /task|line item/i.test(d.innerText||'') }); }" 2>/dev/null | sed -n '2p')
echo "line-item editor: $LINEED"

FAILS=""
[ "${EDITABLE:-99}" = "0" ] || FAILS="$FAILS aggregate-day-boxes-still-editable($EDITABLE)"
case "$LINEED" in *'"lineWidgets":true'*) ;; *) FAILS="$FAILS no-line-item-editor" ;; esac

tt_click_button_exact "cancel" popup >/dev/null 2>&1

[ -z "$FAILS" ] || tt_fail "C4 FAIL:$FAILS
  day inputs were: $DAYS
  (pre-change baseline for comparison: readonly=[false x7,true], no line-item editor)"

echo "PASS: C4 — aggregate day boxes locked and a line-item editor is present in the Review & Edit popup"
