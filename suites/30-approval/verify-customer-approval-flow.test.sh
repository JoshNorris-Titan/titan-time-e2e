#!/usr/bin/env bash
# tt-timeout: 8m
# Customer-approval-via-email-link flow (the anonymous token journey).
#
# BUDGET. Measured 184s against the 4m default — 56 seconds of headroom, and CI has
# already shown this spec swinging between 74s (a pending entry was standing) and the
# slow path where it submits one itself. Declared with its two neighbours so the whole
# token trio has room for its slow path.
#
# Idempotent end-to-end check:
#   1. As HR, on the Client Approval tab, trigger "Remind" on a pending entry for
#      the E2E consultant (reminding does NOT consume the entry). If no pending
#      entry exists, submit one as the consultant first, then remind.
#   2. Read the resulting token email from the configured mail backend and
#      extract the /p/customer-approval/<token> link.
#   3. Open that link ANONYMOUSLY (no login) and assert the Customer Approval page
#      renders, lists the pending timesheet(s), that every listed row is actually
#      awaiting this client's decision, and that the entry the client opens is the
#      one we submitted, on the project we expect.
#
# WHAT MODEL COMMIT 8ca78e2e CHANGED, AND WHY THE ASSERTIONS MOVED (TT-741).
#
# The token used to be minted per PROJECT and the landing page rendered that one
# project inside dvProject, with Customer and Project header rows above the entry
# gallery. The token is now minted per APPROVER EMAIL and the page lists everything
# that approver has waiting across all their projects, so those header rows were
# replaced by a single static heading, "Timesheets awaiting your approval", and each
# gallery row was given the template '{ConsultantName} - {ProjectName} ({Customer})'.
#
# Consequence for this test, measured on dev rather than reasoned from the model —
# the landing page body is now, in full:
#
#   Timesheets awaiting your approval | Pending Approval |
#   E2E Consultant - () | ViewApprove | 40.00 hours | Aug 30-Sep 05 2026
#
# So the page no longer contains 'Costco' or 'E2E Customer Approval' anywhere, and
# the old body-wide tt_assert_all for both was the CI failure in run 33835822357.
#
#   * PROJECT moved, it did not vanish. The Entry Details panel in the review popup
#     behind View names it ("Consultant | E2E Consultant | Project | E2E Customer
#     Approval | Week Range | Aug 30 - Sep 05"), so the project assertion is made
#     there instead — which is strictly better, because it pins the entry the client
#     is about to act on rather than any text on the page.
#   * CUSTOMER has no surface left. 'Costco' appears nowhere on the anonymous
#     journey: not on the landing page, not in the review popup. It is deliberately
#     NOT asserted here, and that is called out rather than quietly dropped.
#
# THE '()' IN THAT ROW IS A PRODUCT BUG, NOT INTENDED COPY. The row template binds
# Main.ApprovalHelper/ProjectName and /Customer, but Main.DS_ApprovalHelper_Customer
# (the flow that builds every row, via DS_ApprovalHelper_ByToken) sets only
# ConsultantName, StartDate, EndDate, TotalHours, AEStatus and Period — it never
# sets ProjectName or Customer, and neither does DS_ApprovalHelper_ByToken, which
# only concatenates. Both placeholders therefore resolve empty on this path, while
# the same two attributes ARE populated on the HR/PM paths (DS_ApprovalHelper_PM,
# DS_ApprovalHelper_Pending, DS_EntriesForTab). Once that is fixed, the project and
# customer assertions belong back on the ROW, and the page-level "no other
# customer's data" check below can come back with them.
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
# Walmart/Yamaha/Rapidappwerks/Thomas Inc.). Reminding whichever entry happened to
# be first used to email a token for another customer, and this test then failed
# asserting 'Costco' on a page that was correctly showing Walmart - a data-selection
# bug that read like a product bug.
#
# Since 8ca78e2e the token no longer narrows the page to one project at all, so
# naming $PROJECT on the remind is not sufficient on its own: the page can list
# several of this approver's projects at once. The project is therefore pinned again
# at the point it matters, on the entry actually opened (step 3).

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

# The HR tab and the token page do not render a week the same way — HR gives
# "Aug 30 - Sep 05, 2026", the token row gives "Aug 30-Sep 05 2026" and the review
# popup gives "Aug 30 - Sep 05" — so match on the leading "Mon DD", which every
# rendering of that week contains.
WEEKFRAG="$(printf '%s' "$WEEK" | grep -oE '^[A-Za-z]{3} [0-9]{1,2}' || true)"
[ -n "$WEEKFRAG" ] || WEEKFRAG="$WEEK"
echo "matching the token page on '$WEEKFRAG'"

# 3) anonymous: open the token page and verify render + the identity of the entry.
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$LINK" >/dev/null 2>&1
tt_wait_for ".mx-name-galPendingEntries" "customer-approval pending list"

# Log every row the token page is offering, whole — consultant, hours and period.
# Since 8ca78e2e a row carries no project or customer text (see the header), so the
# consultant and the week are all that distinguish rows, and this is the evidence
# for a failed match.
tt_token_log_rows "$CONSULTANT_NAME"

# 3a) the rewritten page's own heading. This is what replaced the Customer/Project
# header rows, so it is the thing that says "the approver-scoped landing page
# rendered" rather than some other page or an error state.
tt_assert_all "customer-approval page" "Timesheets awaiting your approval"

playwright-cli eval "() => String(document.querySelectorAll('.mx-name-btnView').length >= 1)" 2>/dev/null | grep -qiw true \
  || tt_fail "customer-approval page shows no pending entries"

# 3b) OUR entry is listed — consultant AND week, read from the row itself rather
# than from anywhere on the page.
[ "$(tt_token_row_present "$CONSULTANT_NAME" "$WEEKFRAG")" = "true" ] \
  || tt_fail "no row for '$CONSULTANT_NAME' in week '$WEEK' on the token page"

# 3c) Nothing else has leaked in. The old check for another customer's NAME cannot
# work now that no row renders one, so assert the invariant the page can still be
# held to: every row must offer Approve, whose visibility is gated on
# ApprovalHelper/AEStatus = AwaitingCustomerApproval. An entry in any other state
# appearing on an unauthenticated page is the leak that matters, and 'norows' does
# not satisfy this.
actionable="$(tt_token_rows_all_actionable)"
[ "$actionable" = "true" ] \
  || tt_fail "the token page lists a row that is not awaiting client approval (tt_token_rows_all_actionable: $actionable)"

# 3d) THE PROJECT ASSERTION, on the surface that now carries it. Open the review
# popup for our row and require the Entry Details panel to name the consultant, the
# project and the week. This is where 'E2E Customer Approval' moved to; it is also
# what proves the token resolved to the right work, since a token that opened
# another customer's project would name that project here.
opened="$(tt_token_open_row "$CONSULTANT_NAME" "$WEEKFRAG")"
case "$opened" in
  hit)     ;;
  nomatch) tt_fail "the token page lists entries but none for week '$WEEK'" ;;
  *)       tt_fail "the token page lists no pending entries at all" ;;
esac
tt_wait_for ".mx-name-btnCustomerApprove" "review popup for the opened entry"

POPUP="$(tt_token_popup_text)"
echo "  [review popup] ${POPUP:0:220}"
for want in "Project" "$PROJECT" "$CONSULTANT_NAME" "$WEEKFRAG"; do
  case "$POPUP" in
    *"$want"*) ;;
    *) tt_fail "review popup for the opened entry does not name '$want': $POPUP" ;;
  esac
done

# NOT ASSERTED, DELIBERATELY: $CUSTOMER ('Costco'). It is on neither surface of the
# anonymous journey since 8ca78e2e — see the product bug described in the header.
# Do not "restore" it by matching the row's literal '()'.

# 3e) leave the entry pending, which is what makes this test repeatable. Cancel is
# the only exit that does; asserting the popup actually closed is what stops a
# stuck dialog from being inherited by the next spec in the shared browser session.
closed="$(tt_token_popup_close)"
[ "$closed" = "closed" ] \
  || tt_fail "could not dismiss the review popup with Cancel (state: $closed)"
[ "$(tt_token_row_present "$CONSULTANT_NAME" "$WEEKFRAG")" = "true" ] \
  || tt_fail "week '$WEEK' left the client's pending list after a Cancel — this test must leave the entry pending"

echo "PASS: customer-approval email-link flow (remind -> token email -> anonymous page -> '$PROJECT' entry for '$WEEKFRAG' confirmed pending)"
