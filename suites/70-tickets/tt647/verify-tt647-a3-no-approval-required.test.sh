#!/usr/bin/env bash
# TT-647 angle 3 — an entry that reached ToProcess with NO approval step reads
# 'N/A' on both lines, and above all NOT the consultant's own name.
#
# Main.ACT_AssignmentEntry_Submit routes a zero-hour entry straight to ToProcess
# (Status = if TotalHours = 0 then ToProcess ...) and logs it with
# ChangeMethod=Consultant_Solo, which the approval filter excludes. With no
# genuine approval row in the cycle, both lines fall back to the literal 'N/A'.
#
# This is the case that would otherwise credit the consultant as their own
# approver, which is the misleading output Josh explicitly ruled out.
#
# Seeds a zero-hour week for e2e_consultant2 on the sandbox project if the To
# Process tab has no such card yet. Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

CUSER="${TT_A3_USER:-e2e_consultant2}"
CNAME="${TT_A3_NAME:-E2E Consultant Two}"
EXPECT="N/A"

# Seed: step to an editable week, force every day box to 0, submit.
# Zeroing uses the native value setter (a plain fill does not always commit a
# Mendix decimal box) - same technique as the TT-692/693 zero-hours test.
#
# Records the seeded week in TT_A3_SEEDED_WEEK, in the "MMM DD - MMM DD" form the
# HR week picker uses, so the caller can pin the week it just created instead of
# walking every week on the tab.
#
# DIALOG HANDLING. This used to run its own dismiss loop built on
#   document.querySelector('.mx-dialog,.mx-window,[role=dialog],.modal-dialog,[class*=modal]')
# which is the dead-node trap lib/_login.sh documents at tt_clear_dialogs: Mendix
# leaves CLOSED dialogs in the DOM, and querySelector returns the FIRST in document
# order, not the live one. Probed against dev on 2026-08-31 mid-submit there were
# four such nodes and the first was invisible - so "Yes" was clicked on a corpse
# while the real "Timesheet Confirmation / Are you Sure?" window stayed up. The
# submit never committed, the loop gave up silently, and the test reported
# "zero-hour entry did not reach the To Process tab" - which reads like a routing
# defect in Main.ACT_AssignmentEntry_Submit and is not. tt_clear_dialogs takes the
# LAST VISIBLE dialog and says what blocked it; use it, and never re-inline a
# querySelector dismiss loop here.
seed_zero_hour_week() {
  local i n week
  tt_login "$CUSER" "My Timesheets"
  for i in $(seq 1 10); do
    if playwright-cli eval "() => { const dm=document.querySelector('.mx-name-txtDayMon input'); return String(!!dm && !dm.disabled && !dm.readOnly && !!document.querySelector('.mx-name-btnSubmit')); }" 2>/dev/null | grep -qiw true; then
      break
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | grep -qiw true \
    || tt_fail "$CUSER: no editable week with a Submit button found to seed a zero-hour entry"

  # The consultant caption and the HR week picker word the same week differently
  # ("This week · Aug 30 – Sep 5" against "Aug 30 - Sep 05, 2026"), so take the
  # canonical key -- tt647_select_exact_week prefix-matches it against the picker.
  week="$(tt_current_week)"
  [ -n "$week" ] || tt_fail "$CUSER: could not read the week label off .mx-name-txtWeekRange to seed against"
  TT_A3_SEEDED_WEEK="$week"
  echo "  seeding zero hours into week '$week'"

  n=$(playwright-cli eval "() => { const ins=[...document.querySelectorAll('.mx-name-galAssignmentRows input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled); const set=(t,v)=>{ t.focus(); Object.getOwnPropertyDescriptor(t.__proto__,'value').set.call(t,v); t.dispatchEvent(new Event('input',{bubbles:true})); t.dispatchEvent(new Event('change',{bubbles:true})); t.blur(); }; ins.forEach(i=>set(i,'0')); return String(ins.length); }" 2>/dev/null | sed -n '2p' | tr -d '"')
  echo "  zeroed ${n:-0} day box(es)"
  [ "${n:-0}" != "0" ] || tt_fail "$CUSER: no editable day boxes in '$week' - nothing to zero, so no entry would be created"

  # WAIT FOR THE ZEROES TO REACH THE SERVER, don't sleep and hope.
  #
  # Each day box hands its value to Mendix on BLUR (lib/_login.sh, tt_commit_focused)
  # and every commit is a separate server round trip. Fourteen boxes on cloud dev is
  # several seconds of round trips, and this used to fire Submit after a flat 2s.
  # Measured against dev on 2026-08-31: two seconds after the write the last box
  # still read a raw "0" - unformatted, the widget's uncommitted signature - beside
  # its row total of 7.00, so the server still had the OLD hours for that row.
  #
  # That is not cosmetic, it decides the routing. Main.SUB_AssignmentEntry_Submit
  # re-reads the hours server-side and sets, PER ENTRY:
  #   TotalHours = 0                  -> ToProcess
  #   else Project/ApprovalFromManager -> AwaitingManagerApproval
  #   else Project/ApprovalFromCustomer -> AwaitingCustomerApproval
  # E2E Consultant Two's two assignments are exactly one of each (verified on dev:
  # E2E Sandbox with hours goes to MANAGER APPROVAL, E2E EmailTest with hours goes
  # to CLIENT APPROVAL), so a zero that has not landed sends BOTH rows to approval
  # queues and NOTHING to To Process. The test then reported "zero-hour entry did
  # not reach the To Process tab", which reads like a routing defect in the product
  # and is not - the seed simply submitted hours it believed it had cleared.
  #
  # The row total is the honest gate: .mx-name-txtRowTotal only reads 0.00 after the
  # server has recalculated the row, which is the same number Submit will read.
  for i in $(seq 1 15); do
    ZERO_STATE=$(playwright-cli eval "() => { const tot=[...document.querySelectorAll('.mx-name-txtRowTotal input')]; const days=[...document.querySelectorAll('.mx-name-galAssignmentRows input')].filter(i=>i.offsetParent!==null && !i.readOnly && !i.disabled); const bad=tot.filter(t=>parseFloat(t.value||'0')!==0).length + days.filter(d=>!/^0(\\.0+)?$/.test((d.value||'').trim()) || (d.value||'').trim()==='').length; return bad===0 ? 'zeroed' : 'pending:' + tot.map(t=>t.value).join(',') + ' days=' + days.map(d=>d.value).join(','); }" 2>/dev/null | _tt_eval_str)
    case "$ZERO_STATE" in zeroed) break ;; esac
    sleep 2
  done
  case "$ZERO_STATE" in
    zeroed) echo "  every row total reads 0.00 - the zeroes are committed" ;;
    *) tt_fail "$CUSER: the zeroed hours never reached the server for week '$week' after ~30s, so Submit would route these entries by their OLD hours: $ZERO_STATE" ;;
  esac

  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  # ONE confirm popup: btnSubmit calls Main.ACT_Timesheet_Submit_Start, which
  # evaluates the warnings and opens Main.Consultant_OverFortyHours once. A zero-hour
  # week is under 40, so this consultant sees "Submit Anyway"; a clean week shows a
  # plain "Submit". Both captions are in tt_clear_dialogs' default accept list.
  tt_clear_dialogs 8 \
    || tt_fail "$CUSER: the submit confirmation was never dismissed, so the zero-hour week was never submitted: ${TT_DIALOG_BLOCKED:-unknown dialog}"
  sleep 3

  # Postcondition: Submit is hidden once the week leaves Draft/Rejected. Without
  # this the seed can "succeed" having changed nothing, and the failure surfaces
  # later as a missing card on the HR tab.
  playwright-cli eval "() => String(!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | grep -qiw true \
    || tt_fail "$CUSER: Submit is still on the page after confirming, so week '$week' never left Draft"
  echo "  submitted '$week' with zero hours"
}

# 1) Look for an existing no-approval card, otherwise seed one.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
if ! tt647_select_week_with "$CNAME" >/dev/null; then
  echo "no To Process entry for '$CNAME' — seeding a zero-hour week"
  seed_zero_hour_week
  tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
  # Submit routes the entry into the queue ASYNCHRONOUSLY, so pin the week the
  # seed just wrote and POLL for the card rather than walking the tab once.
  # tt647_wait_for_card also separates "the week was never offered" (a filter left
  # set on the tab) from "the week is there but holds no such card" (routing) --
  # collapsing those is what made this read as a product defect.
  # On failure, say which queue the entry DID reach before blaming the routing --
  # an entry submitted with hours still on it lands in an approval queue, and that
  # is a seed problem, not a product one. See tt647_locate_entry.
  #
  # GALLERY PAGING. This is the third thing to have failed here, and the one that
  # produced "no card in it matches after ~60s" with a correctly routed entry:
  # galTabEntries renders only four cards until it is scrolled, and this test's two
  # seeded entries sorted past that. tt647_load_cards now runs inside the week
  # selection, so the read below sees the whole week. Verified against dev
  # 2026-08-31: every WEEKLY TO PROCESS week showed 4 cards under a heading reading
  # "(5)", and one scroll took it to 5.
  tt647_wait_for_card "$TT_A3_SEEDED_WEEK" "$CNAME" "" 10 \
    || tt_fail "zero-hour entry for '$CNAME' did not reach the To Process tab: $TT647_WAIT_ERR
       Week '$TT_A3_SEEDED_WEEK' for '$CNAME' is currently on: $(tt647_locate_entry "$TT_A3_SEEDED_WEEK" "$CNAME"). If that names an APPROVAL QUEUE, the seeded hours were not zero when Submit ran. If it names no tab at all, the entries are Draft, Rejected or AwaitingExport — they were never submitted, or something moved them on."
fi

tt647_require_widgets "To Process tab"

LINES="$(tt647_card_lines "$CNAME")"
L1="${LINES%%~~*}"
L2="${LINES#*~~}"
echo "line1: '$L1'"
echo "line2: '$L2'"

[ "$L1" = "$EXPECT" ] \
  || tt_fail "expected line 1 to read '$EXPECT' for an entry with no approval step, got: '$L1'"

# No approval at either stage, so line 2 carries the same empty marker.
[ "$L2" = "$EXPECT" ] || tt_fail "line 2 should also read '$EXPECT', got: '$L2'"

# Guard the specific wrong output this scenario exists to prevent: if the cycle
# filter ever let a submit/draft ChangeLog through, the consultant's own name
# would appear here as their own approver.
case "$L1$L2" in
  *"$CNAME"*) tt_fail "the consultant is being credited as their own approver: line1='$L1' line2='$L2'" ;;
esac

echo "PASS: verify-tt647-a3-no-approval-required — no-approval entry renders '$L1'"
