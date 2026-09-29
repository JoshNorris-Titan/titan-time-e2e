#!/usr/bin/env bash
# The client approves straight from the LIST - the Approve button on a row of the
# emailed link's page, without opening the review popup.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Main.Customer_Approval offers two ways to approve an entry: the
# popup's btnCustomerApprove (Main.ACT_Customer_ApprovePage), which
# verify-customer-token-approve drives, and a per-row btnApprove on the gallery
# itself (Main.ACT_Customer_ApproveHelper), which nothing drove at all. They are
# different microflows with different parameters - the row path takes the page's
# ApprovalHelper, not the entry - and the customer-link security change
# (2026-09-29) put the "does this link cover the entry?" check into each of them
# separately. A regression in either leaves the other green.
#
# WHAT IT PROVES
#   A. the link opens and lists OUR entry (consultant + week), and the review popup
#      for that row names the project - read, then closed with Cancel, so the
#      approval below cannot land on another project's row;
#   B. that row offers btnApprove, and pressing it removes the row;
#   C. read back as HR by guid: the entry left AwaitingCustomerApproval, and its
#      change log gained exactly one row, AwaitingCustomerApproval -> <new status>,
#      whose ChangeMethod is Token - the approval is attributed to the link, not to
#      a staff user standing in (ACT_Customer_ApproveHelper writes it that way).
#
# Row matching is by consultant + week, which is all a row carries (see
# _tt_token_row_js in lib/_login_tokens.sh). Since 'E2E Dual Approval' got its own
# approver address, this approver's link lists no other E2E project for the same
# consultant, and A reads the popup's project anyway before anything irreversible.
#
# Consumes: one E2E Consultant entry on E2E Customer Approval (reminds a pending one,
# or submits one when none is waiting).
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"   # FX_APPROVER_EMAIL: the approver on E2E Customer Approval
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_changelog.sh"
source "$TT_ROOT/lib/_customer_link.sh"

CONSULTANT_NAME="E2E Consultant"
PROJECT="E2E Customer Approval"
APPROVER="$FX_APPROVER_EMAIL"

# --------------------------------------------------------- 1. a pending entry + link
cl_fresh_link "$CONSULTANT_NAME" "$PROJECT" "$APPROVER"
WEEKKEY="$(tt_week_key "$CL_WEEK")"
[ -n "$WEEKKEY" ] || tt_fail "could not read a week range out of HR's week label '$CL_WEEK'"

# ------------------------------------------------ 2. the entry, as HR, before acting
tt_login "e2e_hr" "$TT_HR_READY"
GUID="$(cl_entry_guid "$CONSULTANT_NAME" "$PROJECT" "$WEEKKEY")"
case "$GUID" in
  ERR:*) tt_fail "HR could not read the entry under test ($GUID)" ;;
  "")    tt_fail "HR finds no AwaitingCustomerApproval entry for '$CONSULTANT_NAME' / '$PROJECT' in week '$WEEKKEY' - the one it just reminded" ;;
esac
L_BEFORE="$(cl_log_count "$GUID")"
case "$L_BEFORE" in ''|*[!0-9]*) tt_fail "could not count entry $GUID's change-log rows ([$L_BEFORE])" ;; esac
echo "  entry $GUID is AwaitingCustomerApproval with $L_BEFORE change-log row(s)"

# ------------------------------------------ 3. A: open the link, confirm the project
cl_open_link_cold "$CL_LINK" || tt_fail "the approval link did not open an approval page: $CL_LINK"
tt_token_log_rows "$CONSULTANT_NAME"
opened="$(tt_token_open_row "$CONSULTANT_NAME" "$CL_WEEKFRAG")"
case "$opened" in
  hit) ;;
  nomatch) tt_fail "the link lists entries but none for '$CONSULTANT_NAME' in week '$CL_WEEK'" ;;
  *) tt_fail "the link lists no pending entries at all" ;;
esac
tt_wait_for ".mx-name-btnCustomerApprove" "the review popup"
POPUP="$(tt_token_popup_text)"
case "$POPUP" in
  *"$PROJECT"*) echo "  A: the row for '$CL_WEEKFRAG' is on '$PROJECT'" ;;
  *) tt_fail "the row for week '$CL_WEEK' opens an entry that is not on '$PROJECT' - refusing to approve it from the list: $POPUP" ;;
esac
closed="$(tt_token_popup_close)" || tt_fail "the review popup would not close with Cancel ($closed), so the list's own Approve cannot be reached"

# ------------------------------------------------- 4. B: the row's own Approve button
[ "$(tt_token_row_present "$CONSULTANT_NAME" "$CL_WEEKFRAG")" = "true" ] \
  || tt_fail "the row for week '$CL_WEEK' is not listed before its Approve is pressed - the disappearance check below could not mean anything"
js="$(_tt_token_row_js "$CONSULTANT_NAME")"
clicked="$(playwright-cli eval "() => { $js for(const v of views()){ const r=rowOf(v); if(r && txt(r).indexOf('$CL_WEEKFRAG')>=0){ const b=r.querySelector('.mx-name-btnApprove'); if(!b) return 'nobutton'; if(b.offsetParent===null) return 'hidden'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; } } return 'norow'; }" 2>/dev/null | _tt_eval_str)"
case "$clicked" in
  clicked) echo "  B: pressed the row's Approve" ;;
  nobutton|hidden) tt_fail "the row for week '$CL_WEEK' offers no visible .mx-name-btnApprove ($clicked). Its visibility is ApprovalHelper.AEStatus = AwaitingCustomerApproval, so the row thinks the entry is in some other state" ;;
  *) tt_fail "could not press the row's Approve ($clicked)" ;;
esac
tt_clear_dialogs 8 "Approve" \
  || tt_fail "the row approval stopped on a dialog with no way forward: ${TT_DIALOG_BLOCKED:-unknown dialog}"

gone=""
for _ in $(seq 1 10); do
  [ "$(tt_token_row_present "$CONSULTANT_NAME" "$CL_WEEKFRAG")" = "false" ] && { gone=1; break; }
  sleep 3
done
[ -n "$gone" ] || tt_fail "the row for week '$CL_WEEK' is still listed after its Approve was pressed"
echo "  B: the row left the list"

# ------------------------------------------------ 5. C: what happened, as HR sees it
tt_login "e2e_hr" "$TT_HR_READY"
S_AFTER="$(cl_entry_status "$GUID")"
L_AFTER="$(cl_log_count "$GUID")"
case "$S_AFTER" in
  AwaitingCustomerApproval) tt_fail "the row left the list, but entry $GUID is STILL AwaitingCustomerApproval - the page removed a row the server never approved" ;;
  ERR:*|"") tt_fail "could not read entry $GUID back as HR ($S_AFTER)" ;;
esac
case "$L_AFTER" in ''|*[!0-9]*) tt_fail "could not count entry $GUID's change-log rows after the approval ([$L_AFTER])" ;; esac
[ "$L_AFTER" -eq $(( L_BEFORE + 1 )) ] \
  || tt_fail "entry $GUID's change log went from $L_BEFORE to $L_AFTER row(s); one row approval writes exactly one"

LINE="$(tt_cl_entries "[id = '$GUID']")"
case "$LINE" in ERR:*|"") tt_fail "could not read entry $GUID's change history ($LINE)" ;; esac
TRAIL="$(tt_cl_field "$LINE" 8)"
LAST="${TRAIL##*;}"
case "$LAST" in
  "AwaitingCustomerApproval>$S_AFTER/Token/"*) echo "  C: $S_AFTER, logged as $LAST" ;;
  *) tt_fail "the newest change-log row on $GUID is [$LAST]; a row approval from the link writes AwaitingCustomerApproval>$S_AFTER with ChangeMethod Token (full trail: $TRAIL)" ;;
esac

echo "PASS: verify-customer-row-approve — the list's own Approve moved entry $GUID from AwaitingCustomerApproval to $S_AFTER, logged once, as a Token approval"
