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
# Mail — step 2 reads from testmail.app. Needs TT_TESTMAIL_APIKEY,
# TT_TESTMAIL_NAMESPACE, and optionally TT_TESTMAIL_CUSTAPPROVAL_TAG
# (default: custapproval).
#
# Prerequisite data on the target env: a project with ApprovalFromCustomer=Yes
# whose approver email is that inbox, with the E2E consultant assigned.

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"

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
if WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME"); then
  echo "reminded existing pending entry (week: $WEEK)"
else
  echo "no pending '$CONSULTANT_NAME' entry — creating one via the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_entry || tt_fail "consultant: failed to submit a timesheet for setup"
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "CLIENT APPROVAL"
  sleep 2
  # Submitting the timesheet above may itself have sent mail, so reset the
  # inbox again — otherwise the poll could latch onto that instead.
  tt_mail_prepare
  TS=$(date +%s%3N)
  WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME") \
    || tt_fail "still no pending '$CONSULTANT_NAME' entry after creating one"
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

tt_assert_all "customer-approval page" "$CONSULTANT_NAME" "$CUSTOMER" "$PROJECT"

playwright-cli eval "() => String(document.querySelectorAll('.mx-name-btnView').length >= 1)" 2>/dev/null | grep -qiw true \
  || tt_fail "customer-approval page shows no pending entries"

# Scoping: this token belongs to one customer — no other customer's pending
# timesheets may appear on it.
if playwright-cli eval "() => String(/Thomas Urech|Rapidappwerks|Data Migration/i.test(document.body.innerText))" 2>/dev/null | grep -qiw true; then
  tt_fail "customer-approval page leaked another customer's data (scoping broken)"
fi

echo "PASS: customer-approval email-link flow (remind -> token email -> anonymous scoped page)"
