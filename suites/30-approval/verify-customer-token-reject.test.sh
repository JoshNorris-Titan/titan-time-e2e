#!/usr/bin/env bash
# verify-customer-token-reject.test.sh
#
# The client REJECTS from the emailed token link (state transition T12,
# AwaitingCustomerApproval -> Rejected), and the comment guard that protects it.
#
# WHY THIS EXISTS. Rejection is how a wrong timesheet gets corrected, and until now
# it existed in the suite only as un-asserted setup inside other tests: something
# rejects an entry so a later step has one to resubmit. Nobody checked that the
# CLIENT can reject, or that rejecting does what it claims. Together with
# verify-customer-token-approve this closes both halves of the anonymous token
# surface — the app's only unauthenticated write path.
#
# THE COMMENT GUARD. Main.ACT_Customer_RejectPage branches on "Left Comments?": with
# no comment it shows a message and ends WITHOUT rejecting. That guard is the reason
# a rejection always carries a reason the consultant can act on, so this test
# asserts it directly — press Reject with an empty comment first and require that
# nothing happens. A silent regression there would turn every rejection into a
# mystery for the consultant, and no other test would notice.
#
# Selectors: btnCustomerReject was renamed from actionButton2 in Studio Pro so this
# could target it by name. The comment box is txtRejectionComment, which lives in
# Main.SNIP_AssignmentEntry_Details and is already properly named.
#
# Consumes one pending client-approval entry: it reminds an existing one when there
# is one and creates its own when there is not.
#
# Mail: read from the app's own Emails Sent admin page, so this needs the
# administrator account and nothing else — no catcher, no SMTP, no secret.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

CONSULTANT_USER="e2e_consultant"
CONSULTANT_NAME="E2E Consultant"
PROJECT="E2E Customer Approval"
NOTE="E2E client rejection $(date +%H%M%S)"

tt_mail_prepare

# --------------------------------------- 0. baseline, as the consultant who owns it
# Counting is safe here only because it is scoped to one e2e consultant's own
# rejected list — never assert on a count you do not own.
tt_login "$CONSULTANT_USER" "My Timesheets"
BEFORE="$(tt_rejected_count)"
case "$BEFORE" in ''|*[!0-9]*) tt_fail "could not read the consultant's rejected-entry count (got '$BEFORE')" ;; esac
echo "rejected entries before: $BEFORE"

# --------------------------------------------------------- 1. get a pending entry
tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_click_text "CLIENT APPROVAL"
sleep 2

TS=$(date +%s%3N)
if WEEK=$(tt_hr_remind_e2e_entry "$CONSULTANT_NAME" "$PROJECT"); then
  echo "reminded existing pending entry (week: $WEEK)"
else
  echo "no pending '$CONSULTANT_NAME' entry — creating one via the consultant"
  tt_login "$CONSULTANT_USER" "My Timesheets"
  # Must be an entry on THIS project: a generic submit can land on any assignment,
  # and only $PROJECT produces a token for $CUSTOMER.
  tt_consultant_submit_project_row "$PROJECT"
  tt_login "e2e_hr" "WEEKLY TO PROCESS"
  tt_click_text "CLIENT APPROVAL"
  sleep 2
  tt_mail_prepare
  TS=$(date +%s%3N)
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

# Log every row the token page is offering. One token page covers a whole
# CUSTOMER, so it can list several projects; when a match fails, this shows
# exactly what was on offer instead of leaving "none for week X" unexplained.
playwright-cli eval "() => { const g=document.querySelector('.mx-name-galPendingEntries'); if(!g) return '(no pending list)'; const rows=[...g.querySelectorAll('.mx-name-btnView')].map(v=>{ let p=v; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||'').replace(/\\s+/g,' ').trim(); if(t.length>25) return t.slice(0,120); } return '(row text unavailable)'; }); return rows.length ? rows.join('  ||  ') : '(no rows)'; }" 2>/dev/null | _tt_eval_str | sed 's/^/  [token-page rows] /'


opened="$(playwright-cli eval "() => { const vs=[...document.querySelectorAll('.mx-name-btnView')]; for(const v of vs){ let p=v; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; const t=p.innerText||''; if(t.indexOf('$WEEKFRAG')>=0 && t.indexOf('$PROJECT')>=0){ v.click(); return 'hit'; } } } return vs.length ? 'nomatch' : 'empty'; }" 2>/dev/null | _tt_eval_str)"
case "$opened" in
  hit)     ;;
  nomatch) tt_fail "the token page lists entries but none for week '$WEEK'" ;;
  *)       tt_fail "the token page lists no pending entries at all" ;;
esac

tt_wait_for ".mx-name-btnCustomerReject" "client Reject button on the review popup"

# The comment box lives in the shared details snippet; if it is not rendered here
# the guard below cannot be satisfied at all, which is worth saying plainly.
present="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtRejectionComment'))" 2>/dev/null | _tt_eval_str)"
[ "$present" = "true" ] \
  || tt_fail "no .mx-name-txtRejectionComment on the client review popup — the client cannot give a reason, so Reject can never satisfy its own comment guard"

# ------------------------------------- 4. NEGATIVE: reject with no comment must fail
rc="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerReject'); if(!b) return 'missing'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
[ "$rc" = "clicked" ] || tt_fail "could not click Reject for the no-comment check (state: $rc)"
tt_clear_dialogs 6 "Reject" >/dev/null 2>&1 || true   # a confirmation, if the button has one
tt_clear_dialogs 6 >/dev/null 2>&1 || true            # the "please leave a comment" message
sleep 3

blocked="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnCustomerReject'))" 2>/dev/null | _tt_eval_str)"
[ "$blocked" = "true" ] \
  || tt_fail "Reject with an EMPTY comment closed the review popup — the 'Left Comments?' guard in ACT_Customer_RejectPage is not holding, so a client can reject with no reason"
echo "no-comment reject correctly refused"

# ------------------------------------------------- 5. reject properly, with a reason
tt_fill ".mx-name-txtRejectionComment textarea, .mx-name-txtRejectionComment input" "$NOTE" \
  || tt_fail "could not type a rejection comment"
sleep 1

rc="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnCustomerReject'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
[ "$rc" = "clicked" ] || tt_fail "could not click the client Reject button (state: $rc)"
tt_clear_dialogs 8 "Reject" \
  || tt_fail "rejection confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
sleep 3

# The entry must leave the client's queue. Poll — the workflow commits asynchronously.
#
# MATCH ON WEEK **AND** PROJECT, never the week alone. One token page covers a whole
# CUSTOMER, and a customer can own several client-approval projects the same
# consultant works on — on dev, Costco owns both 'E2E Customer Approval' and
# 'E2E Dual Approval'. With a week-only check, rejecting our entry left the OTHER
# project's entry for the same week sitting in the list, and this step reported
# "still pending after Reject" for a rejection that had in fact succeeded.
# WEEKFRAG is only "Mon DD", so it collides readily.
gone=""
for _ in $(seq 1 10); do
  still="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galPendingEntries'); if(!g) return 'false'; const rows=[...g.querySelectorAll('.mx-name-btnView')].map(v=>{ let p=v; for(let k=0;k<10;k++){ if(!p.parentElement) break; p=p.parentElement; const t=p.innerText||''; if(t.indexOf('$WEEKFRAG')>=0 || t.indexOf('$PROJECT')>=0) return t; } return ''; }); return String(rows.some(t => t.indexOf('$WEEKFRAG')>=0 && t.indexOf('$PROJECT')>=0)); }" 2>/dev/null | _tt_eval_str)"
  [ "$still" = "false" ] && { gone=1; break; }
  sleep 3
done
[ -n "$gone" ] || tt_fail "entry for week '$WEEK' is still pending on the token page after Reject"

# ------------------------------------------- 6. the destination, not just the exit
# Leaving the client queue is not the same as reaching Rejected: a rollback empties
# the list too. The consultant is where a rejection is supposed to surface.
tt_login "$CONSULTANT_USER" "My Timesheets"
AFTER=""
for _ in $(seq 1 8); do
  AFTER="$(tt_rejected_count)"
  [ "$AFTER" = "$((BEFORE + 1))" ] && break
  sleep 4
  playwright-cli reload >/dev/null 2>&1
  sleep 2
done

[ "$AFTER" = "$((BEFORE + 1))" ] \
  || tt_fail "consultant's rejected entries went from $BEFORE to ${AFTER:-?}, expected $((BEFORE + 1)) — the client's rejection did not come back to the consultant"

SEG="$(tt_consultant_week_status "Rejected Entries")"
case "$SEG" in
  *"$PROJECT"*) ;;
  *) echo "  note: rejected list does not name '$PROJECT' in its first 120 chars: $SEG" ;;
esac

echo "PASS: verify-customer-token-reject — empty comment refused; client rejected week '$WEEK' and it returned to the consultant as Rejected ($BEFORE -> $AFTER)"
