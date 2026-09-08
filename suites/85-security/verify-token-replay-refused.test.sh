#!/usr/bin/env bash
# tt-timeout: 12m
# verify-token-replay-refused.test.sh
#
# An approval token is a one-way door per entry: once the client has approved a
# timesheet through the emailed link, re-opening that same link does not offer the
# same timesheet again. And when the link has nothing left to offer, it says so.
#
# WHY THIS EXISTS. The customer-approval link is the application's ONLY
# unauthenticated write path. Everything else needs a password; this needs a
# 44-character string that travels through email, sits in inboxes and forwarded
# threads indefinitely, and is not revoked by being used. Three of its four
# properties already have coverage:
#
#   a wrong-length token       -> suites/10-smoke/verify-anon-bad-token
#   a right-length forgery     -> suites/85-security/verify-anon-token-value-gate
#   a genuine approve / reject -> suites/30-approval/verify-customer-token-{approve,reject}
#
# The fourth is REPLAY, and nothing tests it. verify-customer-token-approve does
# watch the approved row disappear, but from the same live page, moments after the
# click - which a client-side re-render satisfies just as well as a server that
# has stopped offering the entry. This reloads the identical URL in a COLD
# anonymous session, which only the server can answer.
#
# WHAT A REPLAY WOULD MEAN. Not an unauthorised approval - the entry has already
# left AwaitingCustomerApproval, so a second approve has nothing to act on. The
# risk is the opposite one: a link that still presents an approved week invites
# the client to approve it twice, and every one of those clicks is a support call
# about a timesheet that "will not go through". It also tells anyone holding an
# old email what the consultant worked, long after the approval is done.
#
# WHAT IT ASSERTS
#   A. The link works: a cold anonymous session gets the approval page.
#   B. After approving one entry, a COLD RELOAD of the same link no longer offers
#      that consultant + week.
#   C. When the link's queue is empty, the page shows its "nothing to approve"
#      state - Main.Customer_Approval's containerNoPendingApprovals, captioned
#      "You're all caught up" - rather than a bare empty gallery. That is the
#      second half of TT-744, and Josh's decision was that it lives ON the normal
#      page rather than on a page of its own.
#
# C IS BOUNDED, AND SAYS SO. The token is scoped to the APPROVER, not to one
# project, so emptying it means approving every project that approver is the
# contact on. This drains up to TOKEN_DRAIN_MAX entries and, if rows are still
# there afterwards, reports that C could not be reached instead of failing - a
# queue that deep is a data condition, not a defect. A and B always run.
#
# CONSUMES the client-approval queue for this approver. Every step that needs one
# seeds its own, and the ones that run before this in the suite have already had
# theirs.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

PROJECT="${TT_REPLAY_PROJECT:-E2E Customer Approval}"
CONSULTANT_NAME="${TT_REPLAY_CONSULTANT:-E2E Consultant}"
TOKEN_DRAIN_MAX="${TOKEN_DRAIN_MAX:-10}"

# --------------------------------------------------------- 1. get a live token
tt_mail_prepare
TS=$(date +%s%3N)
tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_click_text "CLIENT APPROVAL"
sleep 2

if WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT"); then
  echo "  reminded an existing pending entry (week: $WEEK)"
else
  echo "  no pending '$CONSULTANT_NAME' entry - creating one via the consultant"
  tt_login "e2e_consultant" "My Timesheets"
  tt_consultant_submit_project_row "$PROJECT"
  # Reset the inbox high-water mark BEFORE opening the HR dashboard: tt_mail_prepare
  # signs in as the administrator to read Emails Sent, so calling it afterwards
  # navigates away from the dashboard and the remind then hunts for a week picker on
  # the admin's page. verify-customer-token-approve documents this at length.
  tt_mail_prepare
  TS=$(date +%s%3N)
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "CLIENT APPROVAL"
  sleep 2
  WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT") \
    || tt_fail "still no pending '$CONSULTANT_NAME' entry after creating one"
  echo "  reminded a newly-created entry (week: $WEEK)"
fi
[ -n "$WEEK" ] || tt_fail "could not determine the week under test"

LINK=$(tt_mail_token "$TS") || tt_fail "token email not received within timeout"
case "$LINK" in
  *"/p/customer-approval/"*) ;;
  *) tt_fail "the email link is not a customer-approval link: $LINK" ;;
esac

# The HR tab and the token page render the same week differently, so match on the
# leading "Mon DD" that every rendering contains. The page is already scoped to one
# approver, so the fragment is not doing the identifying on its own.
WEEKFRAG="$(printf '%s' "$WEEK" | grep -oE '^[A-Za-z]{3} [0-9]{1,2}' || true)"
[ -n "$WEEKFRAG" ] || WEEKFRAG="$WEEK"

# ---------------------------------------------------------------- helpers
# open_cold — throw the session away and open the link as a first-time visitor.
#
# cookie-clear alone is not enough: the runtime re-issues a session on the next
# request, so this navigates afterwards and waits for the client to paint. The
# point of the whole test is that the SERVER is asked again, so a warm reuse of
# the page we already had would silently make B untestable.
open_cold() {
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$LINK" >/dev/null 2>&1
  local i
  for i in $(seq 1 25); do
    playwright-cli eval "() => String(!!document.querySelector('.mx-name-galPendingEntries') || !!document.querySelector('.mx-name-containerNoPendingApprovals'))" 2>/dev/null | grep -qiw true && { sleep 1; return 0; }
    sleep 1
  done
  return 1
}

# rows_offered — how many pending rows the page is currently offering.
rows_offered() {
  playwright-cli eval "() => String([...document.querySelectorAll('.mx-name-galPendingEntries .mx-name-btnView')].filter(b=>b.offsetParent!==null).length)" 2>/dev/null | _tt_eval_str
}

# empty_state — is the "nothing to approve" block rendered and visible?
empty_state() {
  playwright-cli eval "() => { const c=document.querySelector('.mx-name-containerNoPendingApprovals'); return String(!!c && c.offsetParent!==null); }" 2>/dev/null | _tt_eval_str
}

# approve_first — open the first offered row and approve it. Echoes 'ok' or why not.
approve_first() {
  local clicked
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.mx-name-galPendingEntries .mx-name-btnView')].filter(x=>x.offsetParent!==null)[0]; if(!b) return 'norow'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str | grep -qiw ok || { echo "norow"; return 1; }
  sleep 3
  clicked="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerApprove'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
  [ "$clicked" = "clicked" ] || { echo "$clicked"; return 1; }
  # Both client actions carry a confirmation captioned with the action itself,
  # which the shared clearer does not accept unless told the verb.
  tt_clear_dialogs 8 "Approve" >/dev/null 2>&1 || true
  sleep 3
  echo "ok"
}

# --------------------------------------------- 2. A: the link opens at all
open_cold || tt_fail "the token link did not open an approval page in a cold anonymous session. Every assertion below is about what that page offers, so there is nothing to report - check the link itself: $LINK"

BEFORE="$(rows_offered)"
case "$BEFORE" in ''|*[!0-9]*) tt_fail "could not count the rows the token page is offering: [$BEFORE]" ;; esac
[ "$BEFORE" -gt 0 ] || tt_fail "the token page opened but offers no rows at all, moments after HR reminded a pending entry for '$CONSULTANT_NAME' / '$PROJECT'. Nothing can be approved, so replay cannot be tested. This is the TT-741 symptom - the email says there is a timesheet to approve and the link shows an empty page - and if it reproduces here it is a product finding, not a test defect."
echo "  the token link opens and offers $BEFORE row(s)"

[ "$(tt_token_row_present "$CONSULTANT_NAME" "$WEEKFRAG")" = "true" ] \
  || tt_fail "week '$WEEK' is not among the rows offered before the approval, so its later absence would prove nothing. Rows on offer: $(tt_token_log_rows "$CONSULTANT_NAME" 2>&1 | tr '\n' ' ')"

# ------------------------------------- 3. approve OUR week, then reload cold
opened="$(tt_token_open_row "$CONSULTANT_NAME" "$WEEKFRAG")"
[ "$opened" = "hit" ] || tt_fail "could not open the review popup for week '$WEEK' (got: $opened)"
tt_wait_for ".mx-name-btnCustomerApprove" "client Approve button on the review popup"
clicked="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerApprove'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
[ "$clicked" = "clicked" ] || tt_fail "could not click the client Approve button (state: $clicked)"
tt_clear_dialogs 8 "Approve" || tt_fail "the approval confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
sleep 4

open_cold || tt_fail "the token link stopped opening after one approval was made through it. The token is not consumed by use, so this is not the expected outcome - the page should still load and simply offer less."

if [ "$(tt_token_row_present "$CONSULTANT_NAME" "$WEEKFRAG")" = "true" ]; then
  echo "FAIL: after approving week '$WEEK', a COLD reload of the same token link still offers it."
  echo "      The row survives a fresh anonymous session, so the server is still"
  echo "      presenting an entry that is no longer AwaitingCustomerApproval - the"
  echo "      client is invited to approve the same week twice, and every one of those"
  echo "      clicks is a support call about a timesheet that will not go through."
  echo "      Rows still on offer: $(tt_token_log_rows "$CONSULTANT_NAME" 2>&1 | tr '\n' ' ')"
  exit 1
fi
echo "  B: after approving it, a cold reload of the same link no longer offers week '$WEEK'"

# ------------------------------------------- 4. C: drain, then the empty state
n="$(rows_offered)"; n="${n:-0}"
i=0
while [ "$n" -gt 0 ] && [ "$i" -lt "$TOKEN_DRAIN_MAX" ]; do
  r="$(approve_first)"
  [ "$r" = "ok" ] || { echo "  (stopped draining: $r)"; break; }
  i=$(( i + 1 ))
  open_cold || tt_fail "the token link stopped opening part-way through the drain, after $i approval(s)"
  n="$(rows_offered)"; n="${n:-0}"
done

if [ "$n" -gt 0 ]; then
  echo "  C not reached: $n row(s) still on offer after approving $i (cap TOKEN_DRAIN_MAX=$TOKEN_DRAIN_MAX)."
  echo "  That is a data condition rather than a defect - this approver is the contact"
  echo "  on more pending work than the cap allows. A and B above still stand."
  echo "PASS: verify-token-replay-refused - the approved week is not offered again by a cold reload of the same token link (empty-state check skipped: queue still $n deep)"
  exit 0
fi

if [ "$(empty_state)" != "true" ]; then
  echo "FAIL: the token link now offers nothing, but the page does not show its"
  echo "      'nothing to approve' state."
  echo "      Main.Customer_Approval carries containerNoPendingApprovals - the heading"
  echo "      \"You're all caught up\" over txtNoPendingTitle / txtNoPendingBody - which"
  echo "      is meant to appear exactly here. Its absence leaves the client looking at"
  echo "      a blank page and no way to tell 'already done' from 'broken link'. That"
  echo "      is TT-744's second half and TT-741's reported symptom."
  exit 1
fi

echo "PASS: verify-token-replay-refused - a cold reload of the token link no longer offers the approved week, and once the queue was drained ($i approval(s)) the page showed its 'nothing to approve' state"
