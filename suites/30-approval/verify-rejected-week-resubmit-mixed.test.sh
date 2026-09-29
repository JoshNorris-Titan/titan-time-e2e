#!/usr/bin/env bash
# tt-timeout: 14m
# verify-rejected-week-resubmit-mixed.test.sh
#
# RED UNTIL bug #1 (reset-editable-only) IS DEPLOYED.
#
# A consultant corrects the ONE line the project manager sent back, on a week whose
# other line the project manager already approved, then saves and resubmits. Only
# the corrected line may go back through approval; the approved line keeps its
# status and its hours, and the week's badge follows the lines.
#
# THE BUG (bug #1, confirmed on dev 2026-09-28). Main.ACT_Timesheet_Draft - behind
# both Save and Submit - reset EVERY line on the week to Draft: its loop split "Set
# to draft?" was the literal `true`. Submit then filtered on _IsEditable, which the
# reset had just made true for every line, so the approved line was routed through
# approval a second time: the PM was asked again, and a line already with HR or
# already exported could be counted twice.
#
# THE FIX (model, saved 2026-09-29, not yet deployed to dev when this was written):
#   Main.ACT_Timesheet_Draft   resets only _IsEditable lines, and sets the week to
#                              Draft only if it reset one;
#   Main.ACT_Timesheet_Submit  re-derives the week's status from its lines
#                              (SUB_AssignmentEntry_UpdateTimesheetStatus) after
#                              submitting.
# The spec's logic is the fixed behaviour. On a build without the fix it goes red at
# assertions A1, A4 and A6 below, which IS the bug.
#
# THE WEEK (lib/_mixedweek.sh). e2e_consultant2, a fresh week:
#   E2E Manager Approval  MW_KEEP_H h/day, approved by e2e_pm  -> ToProcess
#   E2E Sandbox           MW_REJ_H  h/day, rejected by e2e_pm  -> Rejected
# The week is Rejected. ToProcess (approved, waiting for HR) is as far along as the
# approved line goes here: taking it on to AwaitingExport means pressing HR's Process
# button on Main.AssignmentEntry_Process, whose widget name is generated
# (actionButton3), and this suite does not add new uses of generated names. The
# fixtures give e2e_consultant2 only these two projects, so a third line is not
# available either.
#
# WHAT IT ASSERTS. The consultant raises Monday on the Sandbox row (the correction),
# presses Save, then Submit.
#   after Save
#     A1  the approved line keeps its status (ToProcess) and its hours;
#     A2  the corrected line is Draft;
#     A3  the week is Draft, and the badge says so ("Draft");
#   after Submit
#     A4  the approved line STILL keeps its status and hours;
#     A5  the corrected line is back with its approver, with the corrected hours;
#     A6  the PM's pending list holds the corrected line for this week and NOT the
#         approved one - only the corrected line went back to its approver;
#     A7  the week is Awaiting_Approval and the badge reads "Submitted" - or, when
#         the corrected line's project needs no approval at all, Approved /
#         "Approved". Which one is derived from FX_PROJECTS (lib/_fixtures.sh), not
#         assumed, so a change to the Sandbox project's approval flags moves the
#         expectation with it.
# Every assertion is checked and reported; the step fails at the end if any failed,
# so one red run shows the whole picture rather than the first symptom.
#
# Side effect on a build WITHOUT the fix: the resubmit re-routes the approved line
# and sends e2e_pm a second approval mail. That is the bug, reproduced on the
# suite's own accounts.
#
# Env: TT_BASE_URL, TT_ROLE_PASS. Optional TT_EVIDENCE_DIR for screenshots.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_entries.sh"
source "$TT_ROOT/lib/_mixedweek.sh"
source "$TT_ROOT/lib/_fixtures.sh"

fails=0
bad() { echo "  FAILED: $*"; fails=$((fails+1)); }

FIX_MON=5    # the corrected Monday on the Sandbox row (was MW_REJ_H)
KEEP_HOURS="$(mw_hours_fmt "$(( MW_KEEP_H * 5 ))")"
REJ_FIXED_HOURS="$(mw_hours_fmt "$(( MW_REJ_H * 4 + FIX_MON ))")"

# What Submit must make of the corrected line and the week, from the corrected
# line's project configuration.
rej_cfg=""
for row in "${FX_PROJECTS[@]}"; do
  [ "${row%%|*}" = "$MW_REJ" ] && rej_cfg="$row"
done
[ -n "$rej_cfg" ] || tt_fail "lib/_fixtures.sh FX_PROJECTS has no row for '$MW_REJ'"
IFS='|' read -r _ rej_mgr rej_cust _ <<< "$rej_cfg"
if [ "$rej_mgr" = "Yes" ]; then
  WANT_REJ_STATUS="AwaitingManagerApproval"; WANT_WEEK="Awaiting_Approval"; WANT_BADGE="Submitted"
elif [ "$rej_cust" = "Yes" ]; then
  WANT_REJ_STATUS="AwaitingCustomerApproval"; WANT_WEEK="Awaiting_Approval"; WANT_BADGE="Submitted"
else
  WANT_REJ_STATUS="ToProcess"; WANT_WEEK="Approved"; WANT_BADGE="Approved"
fi
echo "  '$MW_REJ' approval config: manager=$rej_mgr customer=$rej_cust -> after Submit expect line $WANT_REJ_STATUS, week $WANT_WEEK ('$WANT_BADGE')"

# --------------------------------------------------------------- 1-2. the mixed week
mw_submit_fresh_week
mw_pm_decide
KEEP_STATUS="$(tt_ledger_status "$MW_S1" "$MW_KEEP")"
[ "$(tt_ledger_hours "$MW_S1" "$MW_KEEP")" = "$KEEP_HOURS" ] \
  || tt_fail "precondition: '$MW_KEEP' should carry $KEEP_HOURS hours after the PM approved it ($MW_S1)"

# ------------------------------------------------- 3. correct the rejected line, Save
mw_goto_week || tt_fail "could not step the consultant grid back to week $MW_WEEK"
[ "$(tt_week_actionable)" = "true" ] \
  || tt_fail "the Rejected week $MW_WEEK shows no Save/Submit/Clear buttons - the consultant cannot correct it"
ROW_REJ="$(tt_week_row_of "$MW_REJ" editable)"
[ "$ROW_REJ" != "0" ] || tt_fail "the rejected '$MW_REJ' row is not editable on week $MW_WEEK"
tt_evidence "mixed-before-save"
mw_fill_row "$ROW_REJ" "$FIX_MON" "Mon"
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 4
tt_clear_dialogs 4 >/dev/null 2>&1
tt_refetch_week
[ "$(tt_current_week)" = "$MW_WEEK" ] || tt_fail "the grid left week $MW_WEEK while re-reading it after Save"
tt_evidence "mixed-after-save"

S2="$(mw_ledger)"
echo "  after Save: $S2"
case "$S2" in ERR:*|NOWEEK|'') tt_fail "could not read week $MW_WEEK back after Save ($S2) - NOT evidence either way" ;; esac
BADGE2="$(mw_badge)"
echo "  badge after Save: '$BADGE2'"

# A1
if [ "$(tt_ledger_status "$S2" "$MW_KEEP")" != "$KEEP_STATUS" ] || [ "$(tt_ledger_hours "$S2" "$MW_KEEP")" != "$KEEP_HOURS" ]; then
  bad "A1 Save moved the approved '$MW_KEEP' line: it was $KEEP_STATUS@$KEEP_HOURS and is now $(tt_ledger_status "$S2" "$MW_KEEP")@$(tt_ledger_hours "$S2" "$MW_KEEP"). Only the rejected '$MW_REJ' line was the consultant's to change (bug #1: Main.ACT_Timesheet_Draft reset every line)."
fi
# A2
[ "$(tt_ledger_status "$S2" "$MW_REJ")" = "Draft" ] \
  || bad "A2 the corrected '$MW_REJ' line should be Draft after Save, reads '$(tt_ledger_status "$S2" "$MW_REJ")'"
# A3
[ "$(tt_ledger_status "$S2" WEEK)" = "Draft" ] \
  || bad "A3 the week should be Draft after Save (a line was reset), reads '$(tt_ledger_status "$S2" WEEK)'"
[ "$BADGE2" = "Draft" ] \
  || bad "A3 the week badge should read 'Draft' after Save, reads '$BADGE2'"

# ---------------------------------------------------------------------- 4. Submit
[ "$(tt_week_actionable)" = "true" ] || tt_fail "week $MW_WEEK shows no Submit button after Save"
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
sleep 2
tt_clear_dialogs 8 || tt_fail "submit blocked by a dialog: $TT_DIALOG_BLOCKED"
sleep 3
tt_refetch_week
[ "$(tt_current_week)" = "$MW_WEEK" ] || tt_fail "the grid left week $MW_WEEK while re-reading it after Submit"
tt_evidence "mixed-after-submit"

S3="$(mw_ledger)"
echo "  after Submit: $S3"
case "$S3" in ERR:*|NOWEEK|'') tt_fail "could not read week $MW_WEEK back after Submit ($S3) - NOT evidence either way" ;; esac
BADGE3="$(mw_badge)"
echo "  badge after Submit: '$BADGE3'"

# A4
if [ "$(tt_ledger_status "$S3" "$MW_KEEP")" != "$KEEP_STATUS" ] || [ "$(tt_ledger_hours "$S3" "$MW_KEEP")" != "$KEEP_HOURS" ]; then
  bad "A4 Submit moved the approved '$MW_KEEP' line: it was $KEEP_STATUS@$KEEP_HOURS and is now $(tt_ledger_status "$S3" "$MW_KEEP")@$(tt_ledger_hours "$S3" "$MW_KEEP") - an approved line was sent back through approval (bug #1)."
fi
# A5
[ "$(tt_ledger_status "$S3" "$MW_REJ")" = "$WANT_REJ_STATUS" ] \
  || bad "A5 the corrected '$MW_REJ' line should be $WANT_REJ_STATUS after Submit, reads '$(tt_ledger_status "$S3" "$MW_REJ")'"
[ "$(tt_ledger_hours "$S3" "$MW_REJ")" = "$REJ_FIXED_HOURS" ] \
  || bad "A5 the corrected '$MW_REJ' line should carry the corrected $REJ_FIXED_HOURS hours, reads '$(tt_ledger_hours "$S3" "$MW_REJ")'"
# A7
[ "$(tt_ledger_status "$S3" WEEK)" = "$WANT_WEEK" ] \
  || bad "A7 the week should be $WANT_WEEK after Submit, reads '$(tt_ledger_status "$S3" WEEK)'"
[ "$BADGE3" = "$WANT_BADGE" ] \
  || bad "A7 the week badge should read '$WANT_BADGE' after Submit, reads '$BADGE3'"

# A6 - the PM's pending list. Only meaningful when the corrected line needs the PM;
# waits for it to arrive, then counts the approved line's rows for the same week.
if [ "$WANT_REJ_STATUS" = "AwaitingManagerApproval" ]; then
  n_rej=""; n_keep=""
  for _ in 1 2 3 4 5 6; do
    mw_pm_load
    n_rej="$(mw_pm_count "$MW_REJ")"
    [ "$n_rej" = "1" ] && break
    sleep 6
  done
  n_keep="$(mw_pm_count "$MW_KEEP")"
  echo "  PM pending for $MW_CNAME / $MW_WEEK: '$MW_REJ'=$n_rej '$MW_KEEP'=$n_keep"
  tt_evidence "mixed-pm-pending"
  [ "$n_rej" = "1" ] \
    || bad "A6 the corrected '$MW_REJ' line should be back in e2e_pm's pending list exactly once for $MW_WEEK, found [$n_rej]. Rows: $(mw_pm_dump)"
  [ "$n_keep" = "0" ] \
    || bad "A6 the approved '$MW_KEEP' line is back in e2e_pm's pending list for $MW_WEEK ([$n_keep] row(s)) - the PM is being asked to approve it a second time (bug #1). Rows: $(mw_pm_dump)"
else
  echo "  A6 not applicable: '$MW_REJ' needs no manager approval, so nothing goes to e2e_pm"
fi

if [ "$fails" -gt 0 ]; then
  echo "FAIL: verify-rejected-week-resubmit-mixed - $fails assertion(s) failed on week $MW_WEEK"
  echo "      after PM decisions: $MW_S1"
  echo "      after Save:         $S2 (badge '$BADGE2')"
  echo "      after Submit:       $S3 (badge '$BADGE3')"
  exit 1
fi
echo "PASS: verify-rejected-week-resubmit-mixed - correcting and resubmitting the rejected '$MW_REJ' line on $MW_WEEK left the approved '$MW_KEEP' line at $KEEP_STATUS@$KEEP_HOURS and sent only the corrected line back"
