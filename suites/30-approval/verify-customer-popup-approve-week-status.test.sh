#!/usr/bin/env bash
# tt-timeout: 12m
# verify-customer-popup-approve-week-status.test.sh
#
# When the client approves the last open entry of a week from the REVIEW POPUP, the
# consultant's week must become Approved. Bug-reproduction spec: RED UNTIL THE MODEL
# FIX LANDS.
#
# THE BUG (bug-verify.md #5, confirmed statically on the 2026-09-28 16:03 build).
# The anonymous token page offers two ways to approve an entry: the list row's own
# Approve (Main.ACT_Customer_ApproveHelper, which calls
# SUB_AssignmentEntry_UpdateTimesheetStatus at its step 45) and the Approve inside
# the entry's review popup (Main.Customer_ReviewTimesheetEntry.btnCustomerApprove ->
# Main.ACT_Customer_ApprovePage). The popup path changes the entry to ToProcess and
# returns WITHOUT recomputing the week, so Main.Timesheet.Status stays at the
# Awaiting_Approval that ACT_Timesheet_Submit hard-set, and the consultant's history
# badge reads "Submitted" indefinitely. ToProcess counts as accepted
# (UT_SUB_UpdateTimesheetStatus_ToProcessCountsAsAccepted), so a week whose every
# entry is ToProcess must read Approved.
#
# THE SCENARIO
#   1. e2e_consultant: a fresh week, hours on the E2E Customer Approval row only, Submit.
#      The customer entry -> AwaitingCustomerApproval; the week's other (zero-hour)
#      entries go straight to ToProcess ("TotalHours = 0 -> ToProcess").
#   2. HR reminds a pending client entry, which emails the approver a token link.
#   3. Anonymous, on that link: View our week's row, Approve inside the popup.
#   4. ASSERT from the data layer: every entry in the week is accepted (the
#      precondition that makes Approved the right answer) and the week is Approved.
#      Buggy: Awaiting_Approval.
#
# CONTROL: TT_BR5_VIA=list approves with the list row's Approve instead; that path
# recomputes the week and should PASS - run it once to prove the red is the popup's.
#
# Mail is read from the app's own Emails Sent page (administrator), like the other
# three token specs.
#
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_*. Optional TT_EVIDENCE_DIR.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"
source "$TT_ROOT/lib/_entries.sh"

CUSER="e2e_consultant"
CONSULTANT_NAME="E2E Consultant"
PROJECT="E2E Customer Approval"

# br5_week_is_fresh — actionable, no hours anywhere on the week, editable $PROJECT row.
br5_week_is_fresh() {
  playwright-cli eval "() => { if(!document.querySelector('.mx-name-btnSubmit')) return 'false'; const ins=[...document.querySelectorAll('.mx-name-galAssignmentRows [class*=mx-name-txtDay] input')]; if(!ins.length) return 'false'; const hours=ins.some(i=>{ const v=parseFloat((i.value||'').replace(',','.')); return !isNaN(v) && v!==0; }); return String(!hours); }" 2>/dev/null | _tt_eval_str
}

tt_mail_prepare

# ------------------------------------------------------ 1. submit a fresh week
tt_login "$CUSER" "My Timesheets"
fresh=""
for i in $(seq 1 14); do
  if [ "$(br5_week_is_fresh)" = "true" ] && [ "$(tt_week_row_of "$PROJECT" editable)" != "0" ]; then
    fresh=1; break
  fi
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ -n "$fresh" ] || tt_fail "no fresh week with an editable '$PROJECT' row in the next 14 weeks for $CUSER"
WEEK="$(tt_current_week)"
[ -n "$WEEK" ] || tt_fail "could not read the week caption"
echo "  week under test: $WEEK"

ROW="$(tt_week_row_of "$PROJECT" editable)"
for d in Mon Tues Wed Thurs Fri; do
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, $ROW)" "8"
done
tt_commit_focused
sleep 1
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 3
tt_clear_dialogs 4 >/dev/null 2>&1 || true
tt_refetch_week
mon="$(playwright-cli eval "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$ROW - 1]||{}).value||'')" 2>/dev/null | _tt_eval_str)"
case "$mon" in ""|0|0.00|0.0) tt_fail "hours did not persist on the '$PROJECT' row (Monday reads '$mon'); a zero-hour entry skips the client stage" ;; esac
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
sleep 2
tt_clear_dialogs 8 || tt_fail "submit blocked by a dialog: $TT_DIALOG_BLOCKED"
sleep 3

S0="$(tt_week_entries "$CUSER" "$WEEK")"
echo "  after submit: $S0"
[ "$(tt_entry_status_of "$S0" "$PROJECT")" = "AwaitingCustomerApproval" ] \
  || tt_fail "precondition: the '$PROJECT' entry should be AwaitingCustomerApproval after submit ($S0)"

# ------------------------------------------------ 2. a token link for the approver
# Reset the inbox mark FIRST (it logs in as the administrator), open HR LAST - the
# order verify-customer-token-approve documents.
tt_mail_prepare
TS=$(date +%s%3N)
tt_login "e2e_hr" "$TT_HR_READY"
tt_hr_click_tab "Client approval"
sleep 2
RWEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT") \
  || tt_fail "HR could not remind any pending '$CONSULTANT_NAME' / '$PROJECT' entry, so no approval link was mailed"
echo "  reminded week '$RWEEK' (the token lists every pending entry for this approver)"
LINK=$(tt_mail_token "$TS") || tt_fail "token email not received within timeout"
case "$LINK" in
  *"/p/customer-approval/"*) ;;
  *) tt_fail "email link is not a customer-approval link: $LINK" ;;
esac

# ------------------------------------------- 3. anonymous: approve from the popup
WEEKFRAG="${WEEK%% - *}"
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
tt_wait_for ".mx-name-galPendingEntries" "customer-approval pending list"
tt_token_log_rows "$CONSULTANT_NAME"
if [ "${TT_BR5_VIA:-popup}" = "list" ]; then
  # CONTROL (opt-in): approve with the list row's own Approve instead of the popup's.
  # That path calls SUB_AssignmentEntry_UpdateTimesheetStatus, so it should turn the
  # week Approved; it separates "the popup path skips the recompute" from "customer
  # approval never recomputes the week". The row carries no project, so this mode is
  # only safe where consultant + week identify one row (the log line above shows it).
  js="$(_tt_token_row_js "$CONSULTANT_NAME")"
  clicked="$(playwright-cli eval "() => { $js const rs=views().map(rowOf).filter(r=>r && txt(r).indexOf('$WEEKFRAG')>=0); if(rs.length!==1) return 'rows:'+rs.length; const b=rs[0].querySelector('.mx-name-btnApprove'); if(!b) return 'missing'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
  [ "$clicked" = "clicked" ] || tt_fail "control: could not click the list row's Approve ($clicked)"
  echo "  CONTROL: approved from the list row, not the popup"
else
  opened="$(tt_token_open_row "$CONSULTANT_NAME" "$WEEKFRAG")"
  [ "$opened" = "hit" ] || tt_fail "the token page has no row for '$CONSULTANT_NAME' week '$WEEKFRAG' ($opened)"
  tt_wait_for ".mx-name-btnCustomerApprove" "client Approve button on the review popup"
  POPUP="$(tt_token_popup_text)"
  case "$POPUP" in
    *"$PROJECT"*) ;;
    *) tt_fail "the opened entry is not on '$PROJECT' - refusing to approve it: $POPUP" ;;
  esac
  tt_evidence "br5-review-popup"
  clicked="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerApprove'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
  [ "$clicked" = "clicked" ] || tt_fail "could not click the popup's Approve (state: $clicked)"
fi
tt_clear_dialogs 8 "Approve" || tt_fail "approval confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
gone=""
for _ in $(seq 1 10); do
  [ "$(tt_token_row_present "$CONSULTANT_NAME" "$WEEKFRAG")" = "false" ] && { gone=1; break; }
  sleep 3
done
[ -n "$gone" ] || tt_fail "week '$WEEKFRAG' is still pending on the token page after Approve"

# ------------------------------------------------------------ 4. the assertion
tt_login "$CUSER" "My Timesheets"
S1=""
for _ in 1 2 3 4 5; do
  S1="$(tt_week_entries "$CUSER" "$WEEK")"
  case "$S1" in
    ERR:*|NOWEEK|'') sleep 3; continue ;;
  esac
  # Wait for the approval itself to be visible before judging the week.
  [ "$(tt_entry_status_of "$S1" "$PROJECT")" = "ToProcess" ] && break
  sleep 3
done
echo "  after the popup approval: $S1"
case "$S1" in ERR:*|NOWEEK|'') tt_fail "could not read week $WEEK back ($S1) - NOT evidence either way" ;; esac
[ "$(tt_entry_status_of "$S1" "$PROJECT")" = "ToProcess" ] \
  || tt_fail "the '$PROJECT' entry did not reach ToProcess after the client approved it ($S1)"

# Precondition: Approved is only the right answer when EVERY entry is accepted.
IFS='|' read -r -a parts <<< "$S1"
for p in "${parts[@]}"; do
  case "$p" in
    WEEK=*) continue ;;
    *=ToProcess|*=AwaitingExport|*=Exported) ;;
    *) tt_fail "precondition: week $WEEK holds an entry that is not accepted ($p), so it should not be Approved anyway - pick a cleaner week ($S1)" ;;
  esac
done

BADGE="$(tt_consultant_week_status "$WEEK")"
echo "  consultant history row: $BADGE"
tt_evidence "br5-consultant-history"
case "$S1" in
  WEEK=Approved\|*) ;;
  *)
    echo "FAIL: every entry in week $WEEK is accepted, but the week reads '${S1%%|*}' (history row: $BADGE)."
    echo "      The client approved from the review popup (Main.ACT_Customer_ApprovePage), which moves"
    echo "      the entry to ToProcess but never calls SUB_AssignmentEntry_UpdateTimesheetStatus, so the"
    echo "      week keeps the Awaiting_Approval that Submit hard-set and the badge says 'Submitted'."
    exit 1 ;;
esac

echo "PASS: verify-customer-popup-approve-week-status - approving the last entry from the client's review popup turned week $WEEK Approved"
