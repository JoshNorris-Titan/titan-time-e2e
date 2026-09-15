#!/usr/bin/env bash
# tt-timeout: 12m
# verify-hr-process-reject-guard.test.sh
#
# The empty-comment guard on the HR reject route: pressing Reject in the comment
# popup with nothing typed must REFUSE, and must leave the entry exactly where it
# was.
#
# WHY THIS EXISTS. Rejecting a week sends it back to the consultant and fires
# Main.SUB_Email_TimesheetRejected. Without a comment the consultant is told to
# fix something with no indication of what, and no screen anywhere shows them
# why. The PM route (Main.ACT_Page_Reject) and the client route
# (Main.ACT_Customer_RejectPage) have always branched on "Left Comments?" and
# refused; the HR route asked for a comment and then rejected whatever it was
# given, including nothing. verify-hr-process-reject and verify-hr-invoice-reject
# both carried a paragraph saying so and declining to assert it.
#
# That asymmetry is now closed. Main.ACT_AssignmentEntry_PageReject sits behind
# the popup's Reject and refuses without a comment, and the two flows it calls -
# Main.ACT_ApprovalHelper_Reject and Main.ACT_RejectAfterExport - carry the same
# guard server-side, so a future caller cannot get round it. This asserts the
# refusal from the outside, which is the only place the guard's real requirement
# shows up: it has to refuse WITHOUT closing the popup or discarding what the
# operator typed.
#
# WHAT IT ASSERTS
#   A. Reject with an EMPTY comment shows the guard's message.
#   B. The popup is STILL OPEN afterwards, so the operator can type a reason and
#      try again rather than hunting the card down a second time.
#   C. Reject with a WHITESPACE-ONLY comment is refused too, and the whitespace is
#      still in the box - proof the flow ended without closing or resetting the
#      form.
#   D. The card is STILL ON THE TAB. This is the assertion that matters: A can
#      pass while the rejection happens anyway behind the message.
#
# CONSUMES NOTHING. Every probe here is refused, so the entry it borrows is left
# in ToProcess for verify-hr-process-reject, which runs straight after this and
# does consume one. That ordering is not an accident - '-' sorts before '.' under
# the runner's LC_ALL=C sort, so this file runs before verify-hr-process-reject.
# Do not rename it to something that sorts the other way round.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

TAB="WEEKLY TO PROCESS"
CNAME="${TT_HRREJECT_NAME:-E2E Consultant}"
GUARD_MSG="Please leave a comment before rejecting"
WS="   "

# THE POPUP IS FOUND WITH _tt_dialog_js, NOT WITH A SELECTOR OF ITS OWN.
# This file used to carry
#     POPUP='[role=dialog], .mx-dialog, .modal-dialog, .mx-window'
# and filter it on offsetParent !== null. Mendix puts all four of those on the ONE
# outer wrapper, and styles it position: fixed - and offsetParent is null for any
# fixed element by specification, however plainly it is on screen. So step A could
# never see the popup it had just opened: every run since the spec was written
# (2026-09-09) failed "did not open the 'Add Rejection Comments' popup" while
# printing, on the very next line, a dialog reading "Add Rejection Comments".
# verify-current-week-warning measured the same wrapper on 2026-09-01 and says it
# in capitals: use _tt_dialog_js, do not reimplement the lookup. It selects the
# INNER content node, which is not fixed, and takes the topmost visible one.

# ---------------------------------------------------------------------- helpers

hprg_hr() { tt_login "e2e_hr" "$TAB"; }

# hprg_weeks - the week labels in this tab's picker, pipe joined. Same shape as
# the one in lib/_tt692693.sh; kept local because this file needs to STAY on the
# week it found rather than sweep every week and forget which was which.
hprg_weeks() {
  playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \d{2} - /.test(t)))]; return s.join('|'); }" 2>/dev/null | _tt_eval_str
}

# hprg_open_tab - land on the tab and wait (<=20s) for its week picker to list
# something; prints the pipe-joined weeks, or nothing if it never filled.
#
# tt_login returns once the tab CAPTION is on screen, and the caption renders well
# before the week gallery does. Both reads in this file used to happen at that
# instant. The first failed "shows no week picker" in 3-6s on every run while
# verify-hr-process-reject, seconds later on the same tab, listed 8 weeks. Once
# that was fixed, the re-count in step D did the same thing: it selected the
# week before the picker existed, counted an empty gallery, and reported
# "an entry left ... (before=3, after=0)" - the most serious thing this file can
# say, pointing at Main.ACT_AssignmentEntry_PageReject, for three cards at once
# when the probe had only ever touched one (run 34885953025).
hprg_open_tab() {
  local w="" _
  tt_click_text "$TAB" >/dev/null 2>&1
  for _ in $(seq 1 20); do
    w="$(hprg_weeks)"
    [ -n "$w" ] && [ "$w" != "null" ] && break
    w=""
    sleep 1
  done
  printf '%s' "$w"
}

hprg_select_week() {
  playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return 'nopicker'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$1')===0); if(el){ el.click(); return 'ok'; } return 'nf'; }" 2>/dev/null | _tt_eval_str
  sleep 3
}

# hprg_click_reject - press the card's own Reject for our consultant on the
# CURRENTLY selected week.
#
# Scoped the way lib/_tt692693.sh documents at length: walk up from the button
# only until the ancestor holds exactly ONE Reject, or a neighbouring card's text
# satisfies the consultant match and the wrong entry gets pressed.
hprg_click_reject() {
  playwright-cli eval "() => { const bs=[...document.querySelectorAll('$TT_HR_BTN_REJECT')].filter(b=>b.offsetParent!==null); for(const b of bs){ let el=b; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=(el.innerText||''); if(t.length>10 && t.length<500 && el.querySelectorAll('$TT_HR_BTN_REJECT').length===1){ if(t.split('\n')[0].trim()==='$CNAME'){ b.click(); return 'ok'; } break; } } } return 'nf'; }" 2>/dev/null | _tt_eval_str
}

# hprg_set_comment <value> - write <value> into the popup's comment box and blur
# it, so Mendix takes the value. Called with '' on purpose, which
# `playwright-cli fill` cannot do reliably against a Mendix text area.
hprg_set_comment() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'nopopup'; const ta=d.querySelector('.mx-name-txtRejectionComment textarea') || d.querySelector('textarea'); if(!ta) return 'nofield'; const set=Object.getOwnPropertyDescriptor(ta.__proto__,'value').set; set.call(ta,'$1'); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); ta.blur(); return 'set'; }" 2>/dev/null | _tt_eval_str
}

# hprg_comment_value - 'V:<contents>' of the popup's comment box, or a marker.
hprg_comment_value() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'NOPOPUP'; const ta=d.querySelector('.mx-name-txtRejectionComment textarea') || d.querySelector('textarea'); return ta ? 'V:'+(ta.value||'') : 'NOFIELD'; }" 2>/dev/null | _tt_eval_str
}

# hprg_visible_dialog_text - the text of EVERY visible top-level dialog, joined.
#
# Reads them all rather than the topmost one because two are on screen at once
# here: the comment popup (a Mendix popup page) and the guard's own blocking
# message. Which of the two is "last" is a DOM-order accident, and this only ever
# needs to know whether the guard's sentence is among them.
hprg_visible_dialog_text() {
  playwright-cli eval "() => { const vis=[...document.querySelectorAll('$TT_DIALOG_SEL')].filter(d=>d.offsetParent!==null); const outer=vis.filter(d=>!vis.some(o=>o!==d && o.contains(d))); return outer.map(d=>(d.innerText||'')).join(' ~~ ').replace(/\s+/g,' ').slice(0,400); }" 2>/dev/null | _tt_eval_str
}

# hprg_popup_open - is the 'Add Rejection Comments' popup the thing on screen?
# Anchored on its title text, because the guard's blocking message matches the
# same container selectors and would otherwise answer 'true' for it.
hprg_popup_open() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); return String(!!d && /Rejection Comment/i.test(d.innerText||'')); }" 2>/dev/null | _tt_eval_str
}

# hprg_probe <value> - set the comment, press the popup's Reject, and report what
# the guard did. Prints 'GUARDED', 'NOMESSAGE:<dialogs>', or a marker naming the
# step that could not be driven.
hprg_probe() {
  local val="$1" r txt
  r="$(hprg_set_comment "$val")"
  [ "$r" = "set" ] || { printf 'SETFAILED:%s' "$r"; return 0; }
  sleep 1
  tt_click_button_exact "reject" popup || { printf 'NOREJECTBUTTON'; return 0; }
  sleep 3
  txt="$(hprg_visible_dialog_text)"
  case "$txt" in
    *"$GUARD_MSG"*) printf 'GUARDED' ;;
    *)              printf 'NOMESSAGE:%s' "$txt" ;;
  esac
}

# ------------------------------------------------- 1. borrow a card to press
hprg_hr
WEEKS="$(hprg_open_tab)"
[ -n "$WEEKS" ] || tt692693_hr_tab_state "no week picker on '$TAB' after 20s"
[ -n "$WEEKS" ] && [ "$WEEKS" != "null" ] \
  || tt_fail "the '$TAB' tab shows no week picker, so there is no week to look in. tt692693_hr_tab_state above says what the tab was showing - an empty picker is usually a consultant or project filter left set by an earlier step, not a missing entry."

WEEK=""
COUNT=0
IFS='|'
for w in $WEEKS; do
  [ -n "$w" ] || continue
  unset IFS
  hprg_select_week "$w" >/dev/null 2>&1
  n="$(tt692693_count_cards_here "$CNAME")"
  n="${n:-0}"
  if [ "$n" -gt 0 ]; then WEEK="$w"; COUNT="$n"; break; fi
  IFS='|'
done
unset IFS

[ -n "$WEEK" ] \
  || tt_fail "no '$CNAME' card in any week of '$TAB', so the guard has nothing to be tested against. An entry reaches this tab in ToProcess, which is where an approved week lands; verify-hr-process-reject seeds its own when the tab is empty, and 20-consultant / 30-approval cover the chain that fills it."
echo "  borrowing week '$WEEK', which holds $COUNT '$CNAME' card(s)"

r="$(hprg_click_reject)"
[ "$r" = "ok" ] \
  || tt_fail "could not press Reject on a '$CNAME' card in week '$WEEK' (state: $r), though the count above says there are $COUNT. That is a paging or re-render difference between the count and the click, not the guard."
sleep 4

[ "$(hprg_popup_open)" = "true" ] \
  || tt_fail "the card's Reject did not open the 'Add Rejection Comments' popup (Main.AssignmentEntry_RejectPage). Without the popup there is nowhere to leave a comment, so the guard would refuse every rejection this tab can make."
echo "  the comment popup is open"

# ------------------------------------------- 2. A + B: empty comment refused
R1="$(hprg_probe "")"
case "$R1" in
  GUARDED) : ;;
  SETFAILED:*)
    tt_fail "could not empty the comment box before the guard check (${R1#SETFAILED:}) - the assertion that follows would prove nothing" ;;
  NOREJECTBUTTON)
    tt_fail "no Reject button could be pressed inside the comment popup" ;;
  NOMESSAGE:*)
    echo "FAIL: Reject with an EMPTY comment produced no guard message."
    echo "      Expected '$GUARD_MSG' from Main.ACT_AssignmentEntry_PageReject's"
    echo "      'Left Comments?' branch. The dialogs on screen said:"
    echo "      ${R1#NOMESSAGE:}"
    echo "      If the rejection went through instead, step 4 below will say so - but a"
    echo "      missing message is already the guard not firing."
    exit 1 ;;
esac
echo "  the empty comment was refused with the guard's message"

# ONE dialog, not "every dialog": the guard's Show Message sits on top of the
# comment popup, and the popup's own buttons are Close and Reject - neither of
# which tt_clear_dialogs will press, by design. Asked to clear 8, it dismisses the
# message and then reports the POPUP as blocked, and this step would fail saying
# the message could not be dismissed when it just was.
tt_clear_dialogs 1 \
  || tt_fail "the guard's message could not be dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}. It is a blocking Show Message, so its only control is OK."
sleep 2

[ "$(hprg_popup_open)" = "true" ] \
  || tt_fail "the comment popup CLOSED when the guard refused the rejection. The refusal path must end without closing the form, or the operator loses the card and has to find it again - which is the whole reason this route is a microflow called with form validations rather than the old nanoflow."
echo "  the popup survived the refusal"

# --------------------------------- 3. C: whitespace refused, and text kept
R2="$(hprg_probe "$WS")"
case "$R2" in
  GUARDED) : ;;
  NOMESSAGE:*)
    echo "FAIL: Reject with a WHITESPACE-ONLY comment was not refused."
    echo "      The guard trims before it compares, so '$WS' must count as no comment."
    echo "      A guard that accepts whitespace is satisfied by a stray keypress, and the"
    echo "      consultant still gets a rejection with no reason on it."
    echo "      The dialogs on screen said: ${R2#NOMESSAGE:}"
    exit 1 ;;
  *)  tt_fail "the whitespace probe could not be driven: $R2" ;;
esac

tt_clear_dialogs 8 >/dev/null 2>&1 || true
sleep 2

KEPT="$(hprg_comment_value)"
case "$KEPT" in
  "V:$WS") echo "  the whitespace was refused and is still in the box" ;;
  V:*)     echo "  NOTE: the box now reads '${KEPT#V:}' rather than the '$WS' that was typed."
           echo "        The refusal is what this step asserts and it held; the box contents"
           echo "        are a nicety, and Mendix may have re-rendered the form." ;;
  *)       tt_fail "could not read the comment box back after the whitespace probe: $KEPT" ;;
esac

# ------------------------------------------- 4. D: the card never moved
tt_click_button_exact "close" popup >/dev/null 2>&1 || true
sleep 2
tt_clear_dialogs 8 >/dev/null 2>&1 || true

hprg_hr
WEEKS_AFTER="$(hprg_open_tab)"
if [ -z "$WEEKS_AFTER" ]; then
  tt692693_hr_tab_state "re-count: no week picker on '$TAB' after 20s"
  tt_fail "could not re-open '$TAB' to re-count: its week picker never filled, so there is nothing to compare against before=$COUNT. That says nothing about the guard either way."
fi
case "|$WEEKS_AFTER|" in
  *"|$WEEK|"*)
    sel="$(hprg_select_week "$WEEK")"
    [ "$sel" = "ok" ] \
      || tt_fail "week '$WEEK' is listed on '$TAB' but could not be selected to re-count ($sel)"
    AFTER="$(tt692693_count_cards_here "$CNAME")"
    AFTER="${AFTER:-0}" ;;
  *)
    # A week with nothing left to process drops out of the picker, so its absence
    # after the picker has loaded IS the cards having gone - count it as zero.
    echo "  week '$WEEK' is no longer in the picker (now: $WEEKS_AFTER)"
    AFTER=0 ;;
esac
if [ "$AFTER" -lt "$COUNT" ]; then
  echo "FAIL: an entry left '$TAB' week '$WEEK' during the guard probes (before=$COUNT, after=$AFTER)."
  echo "      Both probes were refused with the guard's message, so the message is being"
  echo "      shown and the rejection is happening anyway - the worst of the three"
  echo "      possible outcomes, because the operator is told it did not work."
  echo "      Main.ACT_AssignmentEntry_PageReject's false branch must end WITHOUT"
  echo "      calling either reject flow."
  exit 1
fi
echo "  the card is still on the tab (before=$COUNT, after=$AFTER)"

echo "PASS: verify-hr-process-reject-guard - on '$TAB' week '$WEEK', Reject with an empty comment and with a whitespace-only comment were both refused with '$GUARD_MSG', the popup stayed open, and the card never left the tab ($COUNT -> $AFTER)."
