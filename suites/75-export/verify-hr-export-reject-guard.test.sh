#!/usr/bin/env bash
# tt-timeout: 12m
# verify-hr-export-reject-guard.test.sh
#
# The empty-comment guard on the POST-EXPORT reject route: pressing Reject on a
# Sent-tab card must ask for a comment, and pressing the popup's Reject with
# nothing typed must refuse and leave the exported entry where it was.
#
# WHY THIS EXISTS SEPARATELY FROM THE WEEKLY ONE. The Sent tab was not merely
# missing the guard - it never captured a comment at all. btnRejectAfterExport
# called Main.ACT_RejectAfterExport directly, and that flow hardcoded
#
#     RejectionComment = 'Rejected by HR after export.'
#
# over whatever was there, so the canned string was what landed in the ChangeLog
# and in the consultant's rejection email. Of the four routes to Rejected this was
# the only one where the operator could not say why even if they wanted to.
#
# The button now opens Main.AssignmentEntry_RejectPage like the Weekly and Monthly
# ones do, and the canned assignment is gone, so the comment that reaches the
# consultant is the one HR typed. Two things therefore need asserting here and
# nowhere else: that the button opens the popup at all, and that the guard behind
# it refuses an empty comment on THIS route (a different flow, with a different
# split order - Main.ACT_RejectAfterExport checks 'Exported?' first, so a guard
# wired in the wrong place would be unreachable from this tab).
#
# WHAT IT ASSERTS
#   A. The Sent tab's Reject opens the comment popup rather than rejecting on the
#      click.
#   B. Reject with an EMPTY comment shows the guard's message.
#   C. The popup stays open, so the operator can type a reason and try again.
#   D. The card is STILL ON THE TAB - the assertion that matters, because B can
#      pass while the rejection happens anyway behind the message. On this route
#      that would also have subtracted the entry's hours from its assignment.
#
# CONSUMES NOTHING, and runs FIRST in this folder on purpose: 'export-reject'
# sorts before 'invoice-reject' and 'reject-after-export' under the runner's
# LC_ALL=C sort, so it borrows a Sent card while 70-tickets/tt683 has just filled
# the tab, and leaves it for verify-hr-reject-after-export, which does consume
# one. Renaming this file changes that order.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"
source "$TT_ROOT/lib/_tt683.sh"

CNAME="${TT_EXPORT_CONSULTANT:-E2E Consultant}"
GUARD_MSG="Please leave a comment before rejecting"

POPUP='[role=dialog], .mx-dialog, .modal-dialog, .mx-window'
BTN='.mx-name-btnRejectAfterExport'

# ---------------------------------------------------------------------- helpers

# herg_open_reject_tab - land on whichever HR tab exposes the post-export Reject.
#
# Same discovery as verify-hr-reject-after-export, and for the same reason: the
# tab-switch controls were never named, and which tab carries this button is a
# model decision. tt_try_click_text rather than tt_click_text - the fatal version
# exits the whole test when a caption is missing, which is exactly wrong in a loop
# over candidate tabs.
herg_open_reject_tab() {
  local lbl labels
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  if [ "$(herg_has_button)" = "true" ]; then echo "(landing tab)"; return 0; fi
  labels="$(tt683_tab_labels)"
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    unset IFS
    tt_try_click_text "$lbl" || { IFS='|'; continue; }
    sleep 2
    if [ "$(herg_has_button)" = "true" ]; then echo "$lbl"; return 0; fi
    IFS='|'
  done
  unset IFS
  return 1
}

herg_has_button() {
  playwright-cli eval "() => String([...document.querySelectorAll('$BTN')].some(b => b.offsetParent !== null))" 2>/dev/null | _tt_eval_str
}

# herg_count - Sent cards for our consultant, scoped from each Reject button and
# capped so a walk up the tree cannot swallow a neighbouring card.
herg_count() {
  playwright-cli eval "() => { const bs=[...document.querySelectorAll('$BTN')].filter(b=>b.offsetParent!==null); let m=0; for(const b of bs){ let el=b; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<800 && el.querySelectorAll('$BTN').length===1){ if(t.indexOf('$CNAME')>=0) m++; break; } } } return String(m); }" 2>/dev/null | _tt_eval_str
}

herg_click_reject() {
  playwright-cli eval "() => { const bs=[...document.querySelectorAll('$BTN')].filter(b=>b.offsetParent!==null); for(const b of bs){ let el=b; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<800 && el.querySelectorAll('$BTN').length===1){ if(t.indexOf('$CNAME')>=0){ b.click(); return 'ok'; } break; } } } return 'nf'; }" 2>/dev/null | _tt_eval_str
}

herg_set_comment() {
  playwright-cli eval "() => { const d=document.querySelector('$POPUP'); if(!d) return 'nopopup'; const ta=d.querySelector('.mx-name-txtRejectionComment textarea') || d.querySelector('textarea'); if(!ta) return 'nofield'; const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'$1'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); ta.blur(); return 'set'; }" 2>/dev/null | _tt_eval_str
}

herg_visible_dialog_text() {
  playwright-cli eval "() => { const vis=[...document.querySelectorAll('$TT_DIALOG_SEL')].filter(d=>d.offsetParent!==null); const outer=vis.filter(d=>!vis.some(o=>o!==d && o.contains(d))); return outer.map(d=>(d.innerText||'')).join(' ~~ ').replace(/\s+/g,' ').slice(0,400); }" 2>/dev/null | _tt_eval_str
}

# herg_popup_open - anchored on the popup's title, because the guard's blocking
# message matches the same container selectors.
herg_popup_open() {
  playwright-cli eval "() => { const ds=[...document.querySelectorAll('$POPUP')].filter(d=>d.offsetParent!==null); return String(ds.some(d=>/Rejection Comment/i.test(d.innerText||''))); }" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------ 1. borrow an exported card
TAB="$(herg_open_reject_tab)" \
  || tt_fail "no HR tab exposes $BTN, so there is no exported entry to press Reject on. verify-hr-reject-after-export documents the supply: entries reach Exported only via Process -> Export All, which suites/70-tickets/tt683/ drives. Run its seed step first. (If the Sent tab DOES show cards but none carries the button, post-export rejection has been removed from the UI and that is the real failure.)"
echo "  post-export reject lives on tab: $TAB"

BEFORE="$(herg_count)"
BEFORE="${BEFORE:-0}"
[ "$BEFORE" -gt 0 ] \
  || tt_fail "the '$TAB' tab exposes $BTN but holds no card for '$CNAME', so the guard has nothing to be tested against"
echo "  '$TAB' holds $BEFORE '$CNAME' card(s) before the probe"

# --------------------------------------------------- 2. A: the popup opens
r="$(herg_click_reject)"
[ "$r" = "ok" ] \
  || tt_fail "could not press Reject on a '$CNAME' card on '$TAB' (state: $r), though the count above says there are $BEFORE"
sleep 4

if [ "$(herg_popup_open)" != "true" ]; then
  echo "FAIL: the Sent tab's Reject did not open the 'Add Rejection Comments' popup."
  echo "      btnRejectAfterExport is meant to open Main.AssignmentEntry_RejectPage, the"
  echo "      same popup the Weekly and Monthly tabs use. If it is calling"
  echo "      Main.ACT_RejectAfterExport directly again, the post-export route has no way"
  echo "      to capture a comment at all - which is the state this route was in before,"
  echo "      when it wrote the canned 'Rejected by HR after export.' instead."
  echo "      Dialogs on screen: $(herg_visible_dialog_text)"
  exit 1
fi
echo "  the comment popup opened"

# ------------------------------------------ 3. B + C: empty comment refused
s="$(herg_set_comment "")"
[ "$s" = "set" ] \
  || tt_fail "could not empty the comment box before the guard check ($s) - the assertion that follows would prove nothing"
sleep 1

tt_click_button_exact "reject" popup \
  || tt_fail "no Reject button could be pressed inside the comment popup"
sleep 3

DIALOGS="$(herg_visible_dialog_text)"
case "$DIALOGS" in
  *"$GUARD_MSG"*) : ;;
  *)
    echo "FAIL: Reject with an EMPTY comment produced no guard message on the Sent tab."
    echo "      Expected '$GUARD_MSG'. Main.ACT_AssignmentEntry_PageReject checks the"
    echo "      comment BEFORE it splits on 'Exported?', and Main.ACT_RejectAfterExport"
    echo "      carries the same guard after its own 'Exported?' check, so this route has"
    echo "      two chances to refuse and took neither."
    echo "      The dialogs on screen said: $DIALOGS"
    exit 1 ;;
esac
echo "  the empty comment was refused with the guard's message"

tt_clear_dialogs 8 \
  || tt_fail "the guard's message could not be dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}. It is a blocking Show Message, so its only control is OK."
sleep 2

[ "$(herg_popup_open)" = "true" ] \
  || tt_fail "the comment popup CLOSED when the guard refused the rejection. The refusal path must end without closing the form, or the operator loses the card - and on this tab finding it again means walking the Sent gallery."
echo "  the popup survived the refusal"

# ----------------------------------------------- 4. D: the card never moved
tt_click_button_exact "close" popup >/dev/null 2>&1 || true
sleep 2
tt_clear_dialogs 8 >/dev/null 2>&1 || true

TAB="$(herg_open_reject_tab)" \
  || tt_fail "could not return to the post-export reject tab to re-count"
AFTER="$(herg_count)"
AFTER="${AFTER:-0}"
if [ "$AFTER" -lt "$BEFORE" ]; then
  echo "FAIL: an exported entry left '$TAB' during the guard probe (before=$BEFORE, after=$AFTER)."
  echo "      The guard's message was shown and the rejection happened anyway. On this"
  echo "      route that is worse than elsewhere: Main.ACT_RejectAfterExport also"
  echo "      subtracts the entry's hours from its assignment, so a rejection the"
  echo "      operator was told had failed has silently moved the hours too."
  exit 1
fi
echo "  the card is still on the tab (before=$BEFORE, after=$AFTER)"

echo "PASS: verify-hr-export-reject-guard - on '$TAB', the card's Reject opened the comment popup, an empty comment was refused with '$GUARD_MSG', the popup stayed open, and the exported card never left the tab ($BEFORE -> $AFTER)."
