#!/usr/bin/env bash
# verify-customer-token-approve.test.sh
#
# The client actually APPROVES from the emailed token link.
#
# WHY THIS EXISTS. verify-customer-approval-flow walks the whole token journey —
# remind, read the mail, open the link anonymously, check scoping — and then stops
# one click short, deliberately, so it can run repeatedly against standing data.
# The consequence is that the app's ONLY unauthenticated write path had no test:
# nothing anywhere in the suite ever pressed the client's Approve button. An audit
# flagged it independently from five directions (page coverage, microflow coverage,
# role/security, the state machine, and the documented-scenario sweep).
#
# WHAT IT PROVES, beyond "the button was clickable":
#   * AwaitingCustomerApproval -> ToProcess actually happens (T11);
#   * the approver is recorded as the CLIENT, not as HR acting for them. That
#     distinction is the whole of TT-647/TT-649 and is invisible if you only assert
#     that the entry left the queue — a rollback or a delete looks identical.
#
# This step CONSUMES an entry, unlike verify-customer-approval-flow which leaves
# its one pending. It reminds an existing pending entry when there is one and
# creates its own when there is not.
#
# Selectors: Main.Customer_ReviewTimesheetEntry's buttons were auto-named
# (actionButton1/2/3) and were renamed to btnCustomerCancel / btnCustomerReject /
# btnCustomerApprove so this test could target them by name rather than caption.
# A rename in Studio Pro is what makes .mx-name-* a contract; do not go back to
# matching on button text here.
#
# Mail: read from the app's own Emails Sent admin page, so this needs the
# administrator account and nothing else — no catcher, no SMTP, no secret.
# Prerequisite data: a project with ApprovalFromCustomer=Yes and an approver email
# set, with the E2E consultant assigned.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

CONSULTANT_NAME="E2E Consultant"
CUSTOMER="Costco"
PROJECT="E2E Customer Approval"

# Fail fast on a misconfigured mail backend, before the login/click sequence.
tt_mail_prepare

# --------------------------------------------------------- 1. get a pending entry
tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_click_text "CLIENT APPROVAL"
sleep 2

TS=$(date +%s%3N)
if WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME"); then
  echo "reminded existing pending entry (week: $WEEK)"
else
  echo "no pending '$CONSULTANT_NAME' entry — creating one via the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_entry || tt_fail "consultant: failed to submit a timesheet for setup"
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "CLIENT APPROVAL"
  sleep 2
  # Submitting may itself have sent mail; reset so the poll cannot latch onto it.
  tt_mail_prepare
  TS=$(date +%s%3N)
  WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME") \
    || tt_fail "still no pending '$CONSULTANT_NAME' entry after creating one"
  echo "reminded newly-created entry (week: $WEEK)"
fi
[ -n "$WEEK" ] || tt_fail "could not determine the week under test"

# ------------------------------------------------------------- 2. the token link
LINK=$(tt_mail_token "$TS") || tt_fail "token email not received within timeout"
case "$LINK" in
  *"/p/customer-approval/"*) ;;
  *) tt_fail "email link is not a customer-approval link: $LINK" ;;
esac

# ------------------------------------------------ 3. anonymous: open the entry
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
tt_wait_for ".mx-name-galPendingEntries" "customer-approval pending list"

# Open the review popup for OUR week. Falling back to the first row would make the
# later assertions describe an entry we did not choose, so a miss is a failure.
opened="$(playwright-cli eval "() => { const vs=[...document.querySelectorAll('.mx-name-btnView')]; for(const v of vs){ let p=v; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; if((p.innerText||'').indexOf('$WEEK')>=0){ v.click(); return 'hit'; } } } return vs.length ? 'nomatch' : 'empty'; }" 2>/dev/null | _tt_eval_str)"
case "$opened" in
  hit)     ;;
  nomatch) tt_fail "the token page lists entries but none for week '$WEEK'" ;;
  *)       tt_fail "the token page lists no pending entries at all" ;;
esac

# This also proves the Studio Pro rename landed: before it, these were actionButton2/3.
tt_wait_for ".mx-name-btnCustomerApprove" "client Approve button on the review popup"

# ------------------------------------------------------------------ 4. approve
clicked="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerApprove'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
[ "$clicked" = "clicked" ] || tt_fail "could not click the client Approve button (state: $clicked)"

# Both client actions carry a confirmation; its button is captioned with the action
# itself, which the shared clearer does not accept unless told to.
tt_clear_dialogs 8 "Approve" \
  || tt_fail "approval confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
sleep 3

# The entry must leave the client's pending list — the anonymous half of the
# transition. Poll: the workflow commits asynchronously.
gone=""
for _ in $(seq 1 10); do
  still="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galPendingEntries'); return String(!!g && (g.innerText||'').indexOf('$WEEK') >= 0); }" 2>/dev/null | _tt_eval_str)"
  [ "$still" = "false" ] && { gone=1; break; }
  sleep 3
done
[ -n "$gone" ] || tt_fail "entry for week '$WEEK' is still pending on the token page after Approve"

# ------------------------------------------- 5. the transition, seen from inside
# Leaving one queue is not the same as arriving in the next: a rollback or a delete
# would also empty the list above. Assert the destination and the approver.
tt647_hr_open_tab "WEEKLY TO PROCESS"
tt647_select_exact_week "$WEEK" \
  || tt_fail "week '$WEEK' is not listed on the To Process tab — the entry did not arrive there"
tt647_require_widgets "To Process tab"

LINES="$(tt647_card_lines "$PROJECT" "$CONSULTANT_NAME")"
[ -n "$LINES" ] \
  || tt_fail "no To Process card for '$PROJECT' / '$CONSULTANT_NAME' in week '$WEEK' after client approval"

case "$LINES" in
  *"(Client)"*) ;;
  *"on behalf of"*)
    tt_fail "approver reads as HR acting for the client, not the client: $LINES" ;;
  *)
    tt_fail "To Process card does not credit the client as approver: $LINES" ;;
esac

echo "PASS: verify-customer-token-approve — client approved via token; week '$WEEK' reached To Process credited to (Client)"
