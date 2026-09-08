#!/usr/bin/env bash
# tt-timeout: 15m
# verify-hr-process-reject.test.sh
#
# HR sends a week back from WEEKLY TO PROCESS (state transition ToProcess ->
# Rejected) - and the card LEAVES the tab when they do, which is TT-686.
#
# WHY THIS EXISTS. Two reasons, and the second is the interesting one.
#
# 1. It is the last unasserted route to Rejected that a human drives. The client
#    route is covered (verify-customer-token-reject), the after-export route is
#    covered (verify-hr-reject-after-export), the manager route is covered as of
#    verify-pm-reject-action. This one existed only as un-asserted setup: the
#    lib/_tt692693.sh fixtures reject entries so later steps have something to
#    resubmit, and nothing checks that the reject did what it claims.
#
# 2. IT SETTLES A CONTRADICTION THE SUITE HAS CARRIED SINCE AUGUST.
#    lib/_tt692693.sh:16 states that the inline dashboard buttons
#    btn<Tab>Reject / btn<Tab>Approve / btnProcessEntry are "dead controls (no
#    server call)". TT-686 - "Sent, weekly, and Monthly: selecting the reject
#    button keeps the timesheet on the screen" - is the ticket that FIXED them,
#    and it closed on 2026-08-18. Both cannot be true. A read of the model says
#    btnProcessReject calls Main.ACT_HRDashboard_ApproveOrReject, which is a real
#    server action, so the comment is stale - but a model read cannot prove the
#    button reaches it, which is what this asserts.
#
#    So a failure here is not automatically a test defect. If the card does not
#    leave the tab, TT-686 has regressed and that is a product finding.
#
# WHAT IT ASSERTS
#   A. Pressing the card's own Reject opens the comment page - the control is
#      live, not dead.
#   B. After rejecting with a comment, the card is GONE from WEEKLY TO PROCESS.
#      That is TT-686 stated exactly: the complaint was that the timesheet stayed
#      on screen after a reject.
#   C. The entry arrives back in the consultant's Rejected Entries, so the week
#      can actually be corrected.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT. There is no empty-comment guard on this
# path, and this does not pretend there is. The PM route (Main.ACT_Page_Reject)
# and the client route (Main.ACT_Customer_RejectPage) both branch on "Left
# Comments?" and refuse to reject without one; the HR route runs
# Main.NACT_AssignmentEntry_PageReject -> Main.ACT_ApprovalHelper_Reject, which
# has no such branch and rejects whatever it is given. That asymmetry is real and
# worth a ticket, but asserting a guard that was never built would be asserting a
# wish. Noted here so the next person does not "fix" the test.
#
# WHERE THE ENTRY COMES FROM. WEEKLY TO PROCESS holds entries in ToProcess, which
# is where an approved entry lands, so by the time 40-hr runs the earlier approval
# steps have usually left several. When the tab is empty this seeds its own: the
# consultant submits a manager-approval week and the PM approves it, which is the
# cheapest route to ToProcess that needs no line items.
#
# CONSUMES ONE ENTRY.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

TAB="WEEKLY TO PROCESS"
CUSER="${TT_HRREJECT_USER:-e2e_consultant}"
CNAME="${TT_HRREJECT_NAME:-E2E Consultant}"
PROJECT="${TT_HRREJECT_PROJECT:-E2E Manager Approval}"
COMMENT="E2E automated HR send-back - please correct and resubmit"

# hpr_hr() — sign in as HR and land on the dashboard.
hpr_hr() { tt_login "e2e_hr" "$TAB"; }

# hpr_seed — push one entry into ToProcess: consultant submits, PM approves.
#
# Deliberately NOT the line-items project, whose day cells are read-only, and not
# a direct status write: this drives the same route a real entry takes, so a seed
# that succeeds is itself evidence the approval chain works.
hpr_seed() {
  echo "  seeding: $CUSER submits '$PROJECT', then the PM approves it"
  tt_login "$CUSER" "My Timesheets"
  tt_consultant_submit_project_row "$PROJECT" || return 1
  local i
  for i in 1 2 3 4 5 6; do
    tt_login "e2e_pm" "Project Manager Dashboard"
    if playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; for(const b of btns){ let el=b; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=el.innerText||''; if(t.indexOf('$PROJECT')>=0 && t.length<200){ b.click(); return 'true'; } } } return 'false'; }" 2>/dev/null | _tt_eval_str | grep -qiw true; then
      sleep 4
      return 0
    fi
    sleep 6
  done
  return 1
}

# ------------------------------------------------- 1. find or seed a card
hpr_hr
BEFORE="$(tt_hr_count_cards_for "$CNAME" "$TAB")"
BEFORE="${BEFORE:-0}"
if [ "$BEFORE" -eq 0 ]; then
  hpr_seed || tt_fail "could not seed an entry into $TAB - the consultant submit or the PM approve failed, so this step never got a subject. Both have their own coverage in 20-consultant and 30-approval; check those first."
  hpr_hr
  BEFORE="$(tt_hr_count_cards_for "$CNAME" "$TAB")"
  BEFORE="${BEFORE:-0}"
fi
[ "$BEFORE" -gt 0 ] || tt_fail "no '$CNAME' card on $TAB even after seeding one. tt692693_hr_tab_state above says what the tab was showing - an empty week picker usually means a consultant or project filter is still set from an earlier step, not that the entry is missing."
echo "  $TAB holds $BEFORE '$CNAME' card(s) before the reject"

# --------------------------------------------- 2. the reject control is live
# tt_hr_reject_card_for_project walks the week picker, scopes the card to ONE
# card (see its header for why that scoping is load-bearing), presses the card's
# own Reject, types the comment into the page that opens, and confirms.
#
# Its return value is the assertion for A: it returns non-zero when no comment
# page appeared, which is exactly what a dead control would look like.
if ! tt_hr_reject_card_for_project "$CNAME" "$PROJECT" "$TAB" "$COMMENT"; then
  echo "FAIL: pressing Reject on the '$PROJECT' card in $TAB did not lead to a rejection."
  echo "      Either no card for that consultant+project was found in any week of the"
  echo "      picker, or the Reject control did not open the comment page."
  echo "      The second is the one that matters: lib/_tt692693.sh:16 claims these inline"
  echo "      buttons are dead controls, TT-686 says they were fixed on 2026-08-18, and"
  echo "      Main.ACT_HRDashboard_ApproveOrReject is a real server action behind"
  echo "      btnProcessReject. If the control is genuinely dead, TT-686 has regressed."
  exit 1
fi
echo "  the Reject control opened the comment page and the rejection was confirmed"

# ------------------------------------------- 3. TT-686: the card left the tab
hpr_hr
AFTER="$(tt_hr_count_cards_for "$CNAME" "$TAB")"
AFTER="${AFTER:-0}"
if [ "$AFTER" -ge "$BEFORE" ]; then
  echo "FAIL: the rejected card is still on $TAB (before=$BEFORE, after=$AFTER)."
  echo "      This is TT-686 word for word: 'selecting the reject button keeps the"
  echo "      timesheet on the screen'. The entry may well have been rejected in the"
  echo "      database - what has regressed is the tab refresh that follows it"
  echo "      (Main.ACT_ApprovalHelper_Reject deletes the ApprovalHelper and calls the"
  echo "      tab refresh; a stale tab means one of those two stopped happening)."
  exit 1
fi
echo "  the card left $TAB (before=$BEFORE, after=$AFTER)"

# ------------------------------ 4. the consultant got it back, and can fix it
tt_login "$CUSER" "My Timesheets"
tt_consultant_history_load >/dev/null 2>&1 || true
if [ "$(tt_rejected_has_project "$PROJECT")" != "true" ]; then
  echo "FAIL: the card left $TAB but no '$PROJECT' row arrived in the consultant's Rejected Entries."
  echo "      Rejected Entries currently shows: $(tt_rejected_projects)"
  echo "      An entry that leaves HR's queue without returning to the consultant is lost:"
  echo "      nobody is holding it and no screen lists it."
  exit 1
fi

echo "PASS: verify-hr-process-reject - HR rejected a '$PROJECT' card from $TAB, the card left the tab (TT-686: $BEFORE -> $AFTER), and the entry came back to $CUSER as Rejected. The inline btnProcessReject control is live, not dead."
