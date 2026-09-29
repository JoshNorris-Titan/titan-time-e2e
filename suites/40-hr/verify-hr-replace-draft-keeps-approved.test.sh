#!/usr/bin/env bash
# tt-timeout: 16m
# verify-hr-replace-draft-keeps-approved.test.sh
#
# Regression spec for bug #1 (reset-editable-only), fixed in model a3463c1b.
#
# HR's "replace draft" - Create Timesheet, pick a consultant, confirm "This will
# replace <name>'s current draft for this week. Continue?" - blanks only the lines
# of that week that can still be changed. A line the project manager already
# approved keeps its hours, and the week's total is what is left. On a week where
# nothing can be reset, HR is told so and nothing changes.
#
# THE BUG (bug #1, the HR door; gate1.md item 1). Main.SUB_Timesheet_BlankForHR
# refused only an Awaiting_Approval or Approved week. A Rejected week - one line sent
# back, the others approved - passed that guard, and EVERY line was blanked and set
# to Draft, the approved ones included, and the week's totals were zeroed.
#
# THE FIX (model a3463c1b, deployed to dev 2026-09-29).
# BlankForHR blanks only _IsEditable lines, sets the week to Draft only when it reset
# one, recomputes the totals from the lines (SUB_Timesheet_RecalcAll), and returns
# whether it reset anything; Main.ACT_Timesheet_HRPrepare shows the warning
#   "This consultant has already submitted or had approved their timesheet for this
#    week, so it cannot be overwritten."
# when it did not. On a build without the fix, B2 and B4 below go red (every line
# blanked, the week zeroed).
#
# THE WEEK (lib/_mixedweek.sh). e2e_consultant2, a fresh week:
#   E2E Manager Approval  MW_KEEP_H h/day, approved by e2e_pm  -> ToProcess
#   E2E Sandbox           MW_REJ_H  h/day, rejected by e2e_pm  -> Rejected
#
# WHAT IT ASSERTS.
#   A   after the consultant submits and BEFORE the PM decides (both lines awaiting
#       the PM, week Awaiting_Approval - nothing on it can be reset):
#       A1  HR's replace draft shows the warning above, verbatim;
#       A2  and changes nothing: both lines keep status and hours.
#   B   after the PM approves one line and rejects the other (week Rejected):
#       B1  HR's replace draft shows NO warning;
#       B2  the approved line keeps its status (ToProcess) and its hours;
#       B3  the rejected line is blanked: Draft, 0 hours;
#       B4  the week's total equals the approved line's hours, and the week is Draft.
# Every assertion in a phase is checked and reported before the step fails, so one
# red run shows the whole picture.
#
# DRIVING CREATE TIMESHEET. Picking a consultant in cbCreateForAccount opens
# Main.HR_ConfirmRewriteTimesheet for the page's CURRENT week, and the page opens on
# today's week. To aim it at the week under test, HR first picks E2E Consultant Three
# (no assignments, so no lines to touch), closes that popup WITHOUT confirming, steps
# the page's week with btnWeekNext, and only then picks E2E Consultant Two - which
# opens the popup for the week under test. The first popup is dismissed with Escape:
# it has no close control, and its Cancel button's name is generated. Picking Three creates an empty
# timesheet for it on the weeks the page passes; Three is in TT_E2E_CONSULTANTS, so
# the bookend clears remove it.
#
# JOSH MUST RENAME a widget before this can pass anywhere, fix or no fix:
#   Main.HR_ConfirmRewriteTimesheet  actionButton1 ("Replace Draft")
#                                    -> btnConfirmReplaceDraft
# The suite selects on .mx-name-* only and never on a generated name. Until the
# rename is deployed the step fails at the confirm with a message naming it.
#
# Env: TT_BASE_URL, TT_ROLE_PASS. Optional TT_EVIDENCE_DIR for screenshots.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_entries.sh"
source "$TT_ROOT/lib/_mixedweek.sh"

HR_CONFIRM=".mx-name-btnConfirmReplaceDraft"
DECOY="E2E Consultant Three"
WARNING="This consultant has already submitted or had approved their timesheet for this week, so it cannot be overwritten."
KEEP_HOURS="$(mw_hours_fmt "$(( MW_KEEP_H * 5 ))")"
REJ_HOURS="$(mw_hours_fmt "$(( MW_REJ_H * 5 ))")"
ZERO="$(mw_hours_fmt 0)"

fails=0
bad() { echo "  FAILED: $*"; fails=$((fails+1)); }

# ------------------------------------------------------------------ helpers

# hr_dialog_text — the text of the topmost visible dialog, or NONE.
hr_dialog_text() {
  playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'NONE'; return (d.innerText||'').replace(/\\s+/g,' ').trim(); }" 2>/dev/null | _tt_eval_str
}

# hr_wait_dialog <needle> — wait (<=20s) for a visible dialog whose text holds
# <needle>. Prints its text, or NONE.
hr_wait_dialog() {
  local t="NONE"
  for _ in $(seq 1 20); do
    t="$(hr_dialog_text)"
    case "$t" in *"$1"*) break ;; esac
    sleep 1
  done
  printf '%s' "$t"
}

# hr_close_popup — close the replace-draft popup WITHOUT confirming it, by pressing
# Escape. The popup has no close control of its own, and its Cancel button carries a
# generated name (actionButton2), which the suite never selects. Prints ok once no
# visible dialog still offers to replace a draft, or what is still showing.
hr_close_popup() {
  local t
  playwright-cli press Escape >/dev/null 2>&1
  for _ in $(seq 1 10); do
    sleep 1
    t="$(hr_dialog_text)"
    case "$t" in *"replace"*) ;; *) echo ok; return 0 ;; esac
  done
  printf 'still open: %s' "$t"
}

# hr_pick <consultant> — pick <consultant> in the Create Timesheet picker and wait
# for the confirm popup it opens ("This will replace <consultant>'s current draft").
hr_pick() {
  tt_combobox_select_text ".mx-name-cbCreateForAccount" "$1" \
    || tt_fail "could not pick '$1' in the Create Timesheet consultant picker (cbCreateForAccount)"
  local t; t="$(hr_wait_dialog "replace")"
  case "$t" in
    *"$1"*) ;;
    *) tt_fail "picking '$1' did not open the replace-draft confirmation naming them (dialog: $t)" ;;
  esac
}

# hr_open_week — as HR, open Create Timesheet and leave the confirm popup for
# MW_CNAME / MW_WEEK open.
hr_open_week() {
  local i r
  tt_login "e2e_hr" "$TT_HR_READY"
  tt_click_text "Create Timesheet" "HR Create Timesheet nav item"
  sleep 3
  tt_wait_for ".mx-name-cbCreateForAccount" "Create Timesheet consultant picker"
  hr_pick "$DECOY"
  r="$(hr_close_popup)"
  [ "$r" = "ok" ] || tt_fail "could not close the replace-draft popup for '$DECOY' without confirming it ($r)"
  sleep 2
  tt_wait_for ".mx-name-txtWeekRange" "Create Timesheet week header"
  for i in $(seq 1 16); do
    [ "$(tt_current_week)" = "$MW_WEEK" ] && break
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  [ "$(tt_current_week)" = "$MW_WEEK" ] \
    || tt_fail "Create Timesheet did not reach week $MW_WEEK (shows '$(tt_current_week)')"
  hr_pick "$MW_CNAME"
}

# hr_replace — press the popup's Replace Draft. Prints the text of the dialog that
# follows within ~10s, or NONE.
hr_replace() {
  local r
  r="$(playwright-cli eval "() => { const d=$(_tt_dialog_js); if(!d) return 'nodialog'; const b=[...d.querySelectorAll('$HR_CONFIRM')].find(x=>x.offsetParent!==null); if(!b) return 'nobutton'; (b.querySelector('button')||b).click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
  case "$r" in
    ok) ;;
    nobutton) tt_fail "the replace-draft popup has no '$HR_CONFIRM'. Josh must rename actionButton1 (\"Replace Draft\") on Main.HR_ConfirmRewriteTimesheet to btnConfirmReplaceDraft - the suite never selects a generated widget name" ;;
    *) tt_fail "could not press Replace Draft ($r)" ;;
  esac
  sleep 4
  hr_wait_dialog "cannot be overwritten" | head -c 400
}

# ------------------------------------------------ A. nothing can be reset yet
mw_submit_fresh_week
S0="$(mw_ledger "$MW_CNAME")"

hr_open_week
tt_evidence "hr-replace-awaiting-confirm"
T_A="$(hr_replace)"
echo "  replace on the Awaiting_Approval week -> dialog: $T_A"
tt_evidence "hr-replace-awaiting-result"
# A1
case "$T_A" in
  *"$WARNING"*) ;;
  *) bad "A1 replace draft on a week with nothing to reset should warn '$WARNING' - dialog read: $T_A" ;;
esac
tt_clear_dialogs 4 >/dev/null 2>&1
SA="$(mw_ledger "$MW_CNAME")"
echo "  after replace (Awaiting_Approval week): $SA"
case "$SA" in ERR:*|NOWEEK|'') tt_fail "HR could not read week $MW_WEEK back ($SA) - NOT evidence either way" ;; esac
# A2
for p in "$MW_KEEP" "$MW_REJ"; do
  [ "$(tt_ledger_status "$SA" "$p")" = "AwaitingManagerApproval" ] \
    || bad "A2 replace draft on a week with nothing to reset changed '$p' to '$(tt_ledger_status "$SA" "$p")'"
done
[ "$(tt_ledger_hours "$SA" "$MW_KEEP")" = "$KEEP_HOURS" ] \
  || bad "A2 '$MW_KEEP' should keep $KEEP_HOURS hours, reads '$(tt_ledger_hours "$SA" "$MW_KEEP")'"
[ "$(tt_ledger_hours "$SA" "$MW_REJ")" = "$REJ_HOURS" ] \
  || bad "A2 '$MW_REJ' should keep $REJ_HOURS hours, reads '$(tt_ledger_hours "$SA" "$MW_REJ")'"

# ------------------------------------------------ B. the mixed (Rejected) week
mw_pm_decide
KEEP_STATUS="$(tt_ledger_status "$MW_S1" "$MW_KEEP")"

hr_open_week
tt_evidence "hr-replace-mixed-confirm"
T_B="$(hr_replace)"
echo "  replace on the Rejected week -> dialog: $T_B"
tt_evidence "hr-replace-mixed-result"
# B1
case "$T_B" in
  *"$WARNING"*) bad "B1 replace draft on a week with a rejected line should NOT warn - it did: $T_B" ;;
esac
tt_clear_dialogs 4 >/dev/null 2>&1
SB="$(mw_ledger "$MW_CNAME")"
echo "  after replace (Rejected week): $SB"
case "$SB" in ERR:*|NOWEEK|'') tt_fail "HR could not read week $MW_WEEK back ($SB) - NOT evidence either way" ;; esac
# B2
if [ "$(tt_ledger_status "$SB" "$MW_KEEP")" != "$KEEP_STATUS" ] || [ "$(tt_ledger_hours "$SB" "$MW_KEEP")" != "$KEEP_HOURS" ]; then
  bad "B2 replace draft blanked the approved '$MW_KEEP' line: it was $KEEP_STATUS@$KEEP_HOURS and is now $(tt_ledger_status "$SB" "$MW_KEEP")@$(tt_ledger_hours "$SB" "$MW_KEEP"). Only the rejected '$MW_REJ' line was HR's to reset (bug #1: Main.SUB_Timesheet_BlankForHR reset every line of a Rejected week)."
fi
# B3
[ "$(tt_ledger_status "$SB" "$MW_REJ")" = "Draft" ] \
  || bad "B3 the rejected '$MW_REJ' line should be Draft after replace draft, reads '$(tt_ledger_status "$SB" "$MW_REJ")'"
[ "$(tt_ledger_hours "$SB" "$MW_REJ")" = "$ZERO" ] \
  || bad "B3 the rejected '$MW_REJ' line should be blanked to $ZERO hours, reads '$(tt_ledger_hours "$SB" "$MW_REJ")'"
# B4
[ "$(tt_ledger_hours "$SB" WEEK)" = "$KEEP_HOURS" ] \
  || bad "B4 the week total should equal the approved line's $KEEP_HOURS hours, reads '$(tt_ledger_hours "$SB" WEEK)'"
[ "$(tt_ledger_status "$SB" WEEK)" = "Draft" ] \
  || bad "B4 the week should be Draft after a line was reset, reads '$(tt_ledger_status "$SB" WEEK)'"

if [ "$fails" -gt 0 ]; then
  echo "FAIL: verify-hr-replace-draft-keeps-approved - $fails assertion(s) failed on week $MW_WEEK"
  echo "      after submit:         $S0"
  echo "      after replace (A):    $SA"
  echo "      after PM decisions:   $MW_S1"
  echo "      after replace (B):    $SB"
  exit 1
fi
echo "PASS: verify-hr-replace-draft-keeps-approved - on $MW_WEEK HR's replace draft warned and changed nothing while the week awaited approval, then blanked only the rejected '$MW_REJ' line and kept the approved '$MW_KEEP' line at $KEEP_HOURS"
