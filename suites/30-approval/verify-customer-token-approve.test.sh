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
if WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT"); then
  echo "reminded existing pending entry (week: $WEEK)"
else
  echo "no pending '$CONSULTANT_NAME' entry — creating one via the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  # Must be an entry on THIS project: a generic submit can land on any assignment,
  # and only $PROJECT produces a token for $CUSTOMER.
  tt_consultant_submit_project_row "$PROJECT"
  # ORDER IS LOAD-BEARING. Submitting may itself have sent mail, so the high-water
  # mark has to be reset — but tt_mail_prepare reads the Emails Sent page, which is
  # Administrator-only, so it LOGS IN AS THE ADMINISTRATOR and leaves the browser
  # there. Doing that after opening the HR dashboard navigates away from it, and the
  # remind below then hunts for the week picker on the admin's page and reports "no
  # pending entry" — with every HR widget reading ABSENT — for a queue it never
  # looked at. Reset the inbox FIRST, open the HR dashboard LAST. The primary path
  # above already has this order.
  tt_mail_prepare
  TS=$(date +%s%3N)
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "CLIENT APPROVAL"
  sleep 2
  WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT") \
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

# The HR tab and the anonymous token page do not render a week the same way: HR gave
# "Sep 27 - Oct 03, 2026" while the token page lists the same entry under a different
# form, so an exact match found nothing and the step failed claiming the entry was
# absent. Match on the leading "Mon DD" instead, which every rendering of that week
# contains. The token page is already scoped to one customer, so the fragment is not
# doing the identifying on its own.
WEEKFRAG="$(printf '%s' "$WEEK" | grep -oE '^[A-Za-z]{3} [0-9]{1,2}' || true)"
[ -n "$WEEKFRAG" ] || WEEKFRAG="$WEEK"
echo "matching the token page on '$WEEKFRAG'"

# ------------------------------------------------ 3. anonymous: open the entry
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
tt_wait_for ".mx-name-galPendingEntries" "customer-approval pending list"

# Log every row the token page is offering, whole — consultant, hours and period.
# The token page is scoped to ONE PROJECT (the token resolves to a single Project
# and the gallery is constrained to it), so what distinguishes rows here is the
# consultant and the week, and this is the evidence for a failed match.
tt_token_log_rows "$CONSULTANT_NAME"

# Open the review popup for OUR week. Falling back to the first row would make the
# later assertions describe an entry we did not choose, so a miss is a failure.
opened="$(tt_token_open_row "$CONSULTANT_NAME" "$WEEKFRAG")"
case "$opened" in
  hit)     ;;
  nomatch) tt_fail "the token page lists entries but none for week '$WEEK'" ;;
  *)       tt_fail "the token page lists no pending entries at all" ;;
esac

# This also proves the Studio Pro rename landed: before it, these were actionButton2/3.
tt_wait_for ".mx-name-btnCustomerApprove" "client Approve button on the review popup"

# ------------------------------------------------------------------ 4. approve
# Assert the row is PRESENT before clicking. The step below proves the entry left
# the queue, and a disappearance check that is never seen in its true state proves
# nothing at all — an unsatisfiable predicate reads exactly like a fast success.
[ "$(tt_token_row_present "$CONSULTANT_NAME" "$WEEKFRAG")" = "true" ] \
  || tt_fail "week '$WEEK' is not pending on the token page before Approve — the disappearance check below could not mean anything"
echo "entry for '$WEEKFRAG' confirmed pending before Approve"

clicked="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerApprove'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
[ "$clicked" = "clicked" ] || tt_fail "could not click the client Approve button (state: $clicked)"

# Both client actions carry a confirmation; its button is captioned with the action
# itself, which the shared clearer does not accept unless told to.
tt_clear_dialogs 8 "Approve" \
  || tt_fail "approval confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
sleep 3

# The entry must leave the client's pending list — the anonymous half of the
# transition. Poll: the workflow commits asynchronously.
#
# MATCH ON WEEK + CONSULTANT, which is all a row carries. Do NOT add the project:
# the row does not render it (it is a heading above the gallery, out of reach of
# the row walk), so requiring it makes this poll false on its first iteration and
# the step passes instantly whether or not anything was approved. Scoping is not
# lost by leaving it out — the token resolves to one project and the gallery is
# constrained to that project, so no other project's entry can appear here.
gone=""
for _ in $(seq 1 10); do
  still="$(tt_token_row_present "$CONSULTANT_NAME" "$WEEKFRAG")"
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

# WHAT THE CARD ACTUALLY SAYS. Main.SUB_ApprovalHelper_SetApprovalLines emits a BARE
# NAME per stage, and the literal 'N/A' when a stage has no approval in this
# submission cycle. Line 1 comes from the manager stage, line 2 from the client
# stage. For a TOKEN approval there is no signed-in user, so line 2 resolves to
# $Project/ContactName rather than an account name:
#
#   Line2 = if $ClientLog != empty
#           then (if $ClientLog/ChangeMethod = Main.ENUM_ChangeMethod.Token
#                 then $Project/ContactName else $ClientLog/ChangeBy)
#           else 'N/A'
#
# So this project's contact ('E2E Approver' on dev) IS the pass condition, and
# 'N/A~~E2E Approver' is a correct card. Do NOT assert "(Client)", "on behalf of",
# or any other part of the TT-647/648/649 sentence form "Approved by <name> (<role>)
# on <date>" — that design was abandoned and the tickets were never updated. See the
# warning in lib/_tt647.sh; this assertion was the one call site 9a37978 missed, and
# it failed every run afterwards against an app that was behaving correctly.
LINE2="${LINES##*~~}"

# Line 1 is deliberately not asserted: whether a manager stage exists is the fixture
# table's business (ApprovalFromManager), and this test is about the client stage.
case "$LINE2" in
  ""|"N/A")
    tt_fail "client stage recorded no approval — line 2 reads '${LINE2:-<empty>}' (full card: $LINES). The entry left the token page but nothing was written for the client, which is what a rollback looks like" ;;
esac

# THE SURVIVING GUARANTEE: the line names whoever ACTUALLY approved. An HR stand-in
# approving on the client's behalf shows the HR user, so seeing the HR user here
# would mean this token approval was not credited to the client. Read the HR name
# from the live session rather than hardcoding a fixture's full name, which is not
# recorded in this repo.
HRNAME="$(tt647_session_fullname)"
if [ -n "$HRNAME" ] && [ "$LINE2" = "$HRNAME" ]; then
  tt_fail "approver reads as the HR user ('$HRNAME'), not the client: $LINES"
fi

echo "PASS: verify-customer-token-approve — client approved via token; week '$WEEK' reached To Process credited to '$LINE2'"
