#!/usr/bin/env bash
# Customer-approval-via-email-link flow (the anonymous token journey).
#
# Idempotent end-to-end check:
#   1. As HR, on the Client Approval tab, trigger "Remind" on a pending entry for
#      the E2E consultant (reminding does NOT consume the entry). If no pending
#      entry exists, submit one as the consultant first, then remind.
#   2. Read the resulting token email from the configured mail backend and
#      extract the /p/customer-approval/<token> link.
#   3. Open that link ANONYMOUSLY (no login) and assert the Customer Approval page
#      renders, is scoped to the right customer/project, lists the pending
#      timesheet(s), and does NOT leak any other customer's data.
#
# The entry is left pending (never approved), so the test can run repeatedly
# against the same standing data.
#
# Mail — step 2 reads the app's own Emails Sent admin page (Administrator only),
# optionally TT_MAIL_CUSTAPPROVAL_TAG
# (default: custapproval).
#
# Prerequisite data on the target env: a project with ApprovalFromCustomer=Yes
# whose approver email is that inbox, with the E2E consultant assigned.
#
# SCOPING IS LOAD-BEARING. Both the remind and the fallback submit below name
# $PROJECT explicitly. dev carries several client-approval projects for the same
# consultant on DIFFERENT customers (E2E ClientApproval B/C/D/E ->
# Walmart/Yamaha/Rapidappwerks/Thomas Inc.), and the approval token is per PROJECT.
# Reminding whichever entry happened to be first emailed a token for another
# customer, and this test then failed asserting 'Costco' on a page that was
# correctly showing Walmart - a data-selection bug that read like a product bug.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CONSULTANT_NAME="E2E Consultant"
CUSTOMER="Costco"
PROJECT="E2E Customer Approval"

# Fail fast on a misconfigured backend, before the login/click sequence.
tt_mail_prepare

# 1) HR: remind an existing pending entry (create one first if the pool is empty).
tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_click_text "CLIENT APPROVAL"
sleep 2

TS=$(date +%s%3N)
if WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT"); then
  echo "reminded existing pending entry (week: $WEEK)"
else
  echo "no pending '$CONSULTANT_NAME' entry on '$PROJECT' — creating one via the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  # Must be an entry on THIS project: a generic submit can land on any assignment,
  # and only $PROJECT routes to $CUSTOMER's approval token.
  tt_consultant_submit_project_row "$PROJECT"
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "CLIENT APPROVAL"
  sleep 2
  # Submitting the timesheet above may itself have sent mail, so reset the
  # inbox again — otherwise the poll could latch onto that instead.
  tt_mail_prepare
  TS=$(date +%s%3N)
  WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT") \
    || tt_fail "still no pending '$CONSULTANT_NAME' entry on '$PROJECT' after creating one"
  echo "reminded newly-created entry (week: $WEEK)"
fi

# 2) fetch the token link from the reminder email.
LINK=$(tt_mail_token "$TS") \
  || tt_fail "token email not received within timeout"
case "$LINK" in
  *"/p/customer-approval/"*) ;;
  *) tt_fail "email link is not a customer-approval link: $LINK" ;;
esac
echo "received token link"

# 3) anonymous: open the token page and verify render + scoping.
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
tt_wait_for ".mx-name-galPendingEntries" "customer-approval pending list"

# Log every row the token page is offering, whole — consultant, hours and period.
# The token page is scoped to ONE PROJECT (the token resolves to a single Project
# and the gallery is constrained to it), so what distinguishes rows here is the
# consultant and the week, and this is the evidence for a failed match.
tt_token_log_rows "$CONSULTANT_NAME"


tt_assert_all "customer-approval page" "$CONSULTANT_NAME" "$CUSTOMER" "$PROJECT"

playwright-cli eval "() => String(document.querySelectorAll('.mx-name-btnView').length >= 1)" 2>/dev/null | grep -qiw true \
  || tt_fail "customer-approval page shows no pending entries"

# Scoping: this token belongs to one customer — no other customer's pending
# timesheets may appear on it.
if playwright-cli eval "() => String(/Thomas Urech|Rapidappwerks|Data Migration/i.test(document.body.innerText))" 2>/dev/null | grep -qiw true; then
  tt_fail "customer-approval page leaked another customer's data (scoping broken)"
fi

echo "PASS: customer-approval email-link flow (remind -> token email -> anonymous scoped page)"
