#!/usr/bin/env bash
# A button that is present but unavailable still sits on its row, not below it.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. A Mendix action button has no disabled state, only shown or
# hidden, so a button that must stay VISIBLE while unavailable is modelled as two
# controls: the real one, and an inert look-alike wrapped in a Tooltip that says
# why. The Tooltip widget renders its trigger inside two <div>s, and a div is
# block-level -- so the look-alike could not share a line with its siblings and
# dropped onto a second row. On the HR dashboard's Client Approval card that
# pushed the (since removed) "Reissue link" button down; on the Pending card it
# stacked "Submit 0-hour entries" under "Remind". Rows with an unavailable action
# were visibly taller than the rows around them and the buttons stopped lining
# up down the list.
#
# "Reissue link" is gone (approval links are now one per email and nothing
# cancels them), so the gated look-alike is alone in its action container
# (cntClientCardR0C1) and there is no same-container sibling left to share a
# line with. B therefore measures against what the eye still compares: the
# View / Approve buttons in the adjacent container (cntClientCardR0C2) on the
# SAME card, and the height of a card whose Remind is still available.
#
# The fix is Atlas's own "Show inline" design property on the Tooltip, which adds
# .widget-tooltip-inline (display: inline-block). This test asserts the RENDERED
# RESULT, not the class: a class can be present and overridden, and the thing
# anybody actually notices is whether the two buttons share a line.
#
# WHY IT CAN FAIL. Before the fix the wrapper computed display:block and the two
# buttons' top edges differed by a full button height (~39px measured in the
# mirror). Assertion B compared those top edges, so it went red on the old model
# and went green on the new one. With the look-alike alone in its container, a
# block wrapper no longer has a sibling to push it down -- C (the wrapper is not
# a block box) is now the assertion that catches the original regression
# directly, and B catches its visible symptom by any route (a taller card, a
# gated button out of line with the card's other actions). That is the property this suite keeps asking for
# and rarely gets -- see "Assertions that cannot fail" in CLAUDE.md.
#
# WHAT IT ASSERTS
#   A. the Client Approval tab shows a GATED card -- btnClientRemindBlocked is
#      present. Fatal otherwise: everything below would be vacuous.
#   B. the gated look-alike sits on its card's button line and does not make
#      the card taller:
#        B1. its top edge agrees, within half a button height, with the first
#            of btnClientView / btnClientApprove on the same card;
#        B2. if any card on the tab still shows an available Remind, the gated
#            card's height agrees with that card's within half a button height.
#            When every card is gated there is nothing to compare, and B2 says
#            so rather than passing.
#   C. the Tooltip wrapper around the look-alike is not a block box.
#
# HOW IT REACHES THE GATED STATE. Reminding a customer twice about the same
# timesheet on the same day is refused, and the card then swaps btnClientRemind
# for btnClientRemindBlocked -- see suites/60-email/verify-hr-remind-daily-gate.
# The e2e projects share one approver address, so by the time 40-hr runs the
# 30-approval token specs have usually already gated every pending client card.
# If nothing is gated yet, this test presses Remind itself rather than passing
# vacuously.
#
# Consumes: may send one reminder email to the fixture approver address.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CONSULTANT="${TT_REMIND_CONSULTANT:-E2E Consultant}"
PROJECT="${TT_REMIND_PROJECT:-E2E Customer Approval}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

count_sel() { playwright-cli eval "() => String(document.querySelectorAll('$1').length)" 2>/dev/null | _tt_eval_str; }

tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_click_text "CLIENT APPROVAL"
sleep 3

# --------------------------------------------------------- A. a gated card to measure
GATED="$(count_sel "$TT_HR_BTN_REMIND_BLOCKED")"
case "$GATED" in *ERR*|'') tt_fail "could not read the Client Approval tab's remind buttons" ;; esac
note "gated card(s) on arrival: $GATED"

if [ "${GATED:-0}" -eq 0 ]; then
  OPEN="$(count_sel "$TT_HR_BTN_REMIND")"
  if [ "${OPEN:-0}" -eq 0 ]; then
    tt_fail "the Client Approval tab shows no pending entry at all, so there is no card to gate and this step has no verdict. suites/30-approval puts one there; run the suite in order."
  fi
  note "nothing gated yet; reminding '$CONSULTANT' / '$PROJECT' to produce the gated state"
  tt_hr_remind_e2e_entry "$CONSULTANT" "$PROJECT" >/dev/null || \
    note "note: no remindable card matched; measuring whatever the tab shows"
  sleep 3
  tt_click_text "CLIENT APPROVAL"
  sleep 3
  GATED="$(count_sel "$TT_HR_BTN_REMIND_BLOCKED")"
fi

if [ "${GATED:-0}" -eq 0 ]; then
  tt_fail "A: no card reached the gated state, so the unavailable-button layout cannot be measured. Either the remind did not send, or the once-per-day gate did not fire (suites/60-email/verify-hr-remind-daily-gate covers that rule itself)."
fi
note "A ok: $GATED card(s) show the gated state"

# ------------------------------------------------- B/C. measure the gated card's row
# One eval, one delimited string, decoded with _tt_eval_str -- grepping raw eval
# output matches the echoed source line and passes no matter what the page did
# (CLAUDE.md, "The eval/grep false pass").
REPORT="$(playwright-cli eval "() => {
  const blocked = document.querySelector('.mx-name-btnClientRemindBlocked');
  if (!blocked) return 'NO-BLOCKED';

  // The Tooltip wrapper is the look-alike's ancestor carrying widget-tooltip.
  const wrap = blocked.closest('.widget-tooltip');
  if (!wrap) return 'NO-WRAPPER';

  // The card is the lowest ancestor holding a View/Approve action -- at most
  // one of each -- and exactly one remind control (real or gated). Stopping
  // there keeps the search from climbing into the list and borrowing another
  // card's button.
  const ACT = '.mx-name-btnClientView, .mx-name-btnClientApprove';
  const REM = '.mx-name-btnClientRemind, .mx-name-btnClientRemindBlocked';
  const cardOf = (el) => {
    let c = el.parentElement;
    while (c && c.querySelectorAll(ACT).length === 0) c = c.parentElement;
    if (!c) return null;
    const n = (q) => c.querySelectorAll(q).length;
    if (n('.mx-name-btnClientView') > 1 || n('.mx-name-btnClientApprove') > 1 || n(REM) !== 1) return null;
    return c;
  };
  const card = cardOf(wrap);
  if (!card) return 'NO-SIBLING';
  const sib = card.querySelector(ACT);

  // A card whose Remind is still available, for the height comparison (B2).
  let refH = '';
  for (const r of document.querySelectorAll('.mx-name-btnClientRemind')) {
    const rc = cardOf(r);
    if (rc && rc !== card) { refH = String(Math.round(rc.getBoundingClientRect().height)); break; }
  }

  const wr = wrap.getBoundingClientRect();
  const sr = sib.getBoundingClientRect();
  const br = blocked.getBoundingClientRect();
  const cs = getComputedStyle(wrap);
  return [
    cs.display,
    Math.round(wr.top),
    Math.round(sr.top),
    Math.round(br.height),
    Math.round(sr.height),
    Math.round(card.getBoundingClientRect().height),
    refH
  ].join('|');
}" 2>/dev/null | _tt_eval_str)"

case "$REPORT" in
  NO-BLOCKED)  tt_fail "the gated look-alike vanished between counting it and measuring it" ;;
  NO-WRAPPER)  tt_fail "the gated look-alike is not inside a .widget-tooltip wrapper -- the two-control pattern changed shape, and this test no longer measures what it claims" ;;
  NO-SIBLING)  tt_fail "could not find the gated look-alike's card: no ancestor holds one card's btnClientView/btnClientApprove and exactly one remind control, so there is no sibling on the same card to measure against" ;;
  *ERR*|'')    tt_fail "could not measure the gated card's button row" ;;
esac

IFS='|' read -r DISPLAY WRAP_TOP SIB_TOP BLOCKED_H SIB_H CARD_H REF_H <<EOF
$REPORT
EOF

note "wrapper display=$DISPLAY  wrapper top=${WRAP_TOP}px  view/approve top=${SIB_TOP}px  heights ${BLOCKED_H}/${SIB_H}px  card ${CARD_H}px  available-remind card ${REF_H:-none}px"

# Half a button height: comfortably inside the same line, comfortably outside a
# stacked one (a wrapped row differed by a full button height).
TOL=$(( ${SIB_H:-38} / 2 ))
[ "$TOL" -lt 8 ] && TOL=8
DELTA=$(( WRAP_TOP - SIB_TOP )); [ "$DELTA" -lt 0 ] && DELTA=$(( -DELTA ))

if [ "$DELTA" -le "$TOL" ]; then
  note "B1 ok: the gated button is on its card's button line (top edges ${DELTA}px from View/Approve, tolerance ${TOL}px)"
else
  bad "B1: the gated button sits ${DELTA}px from the card's View/Approve top edge (tolerance ${TOL}px) -- the unavailable action has dropped off the card's button line, making this card taller than the rows around it."
fi

if [ -z "$REF_H" ]; then
  note "B2 not measured: every card on the tab is gated, so there is no card with an available Remind to compare heights against (B1 and C still ran)"
else
  HDELTA=$(( CARD_H - REF_H )); [ "$HDELTA" -lt 0 ] && HDELTA=$(( -HDELTA ))
  if [ "$HDELTA" -le "$TOL" ]; then
    note "B2 ok: the gated card is ${CARD_H}px tall against ${REF_H}px for a card with Remind available (tolerance ${TOL}px)"
  else
    bad "B2: the gated card is ${CARD_H}px tall against ${REF_H}px for a card with Remind available (tolerance ${TOL}px) -- the unavailable action is making its row taller than the rows around it."
  fi
fi

if [ "$DISPLAY" = "block" ]; then
  bad "C: the Tooltip wrapper around the gated button computes display:block, so it cannot share a line with its siblings. The 'Show inline' design property is missing from the Tooltip, or something overrides .widget-tooltip-inline."
else
  note "C ok: the Tooltip wrapper computes display:$DISPLAY, not block"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-blocked-button-inline — $fails problem(s) with the unavailable-button row layout."
  exit 1
fi

echo "PASS"
