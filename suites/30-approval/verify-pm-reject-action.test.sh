#!/usr/bin/env bash
# tt-timeout: 10m
# verify-pm-reject-action.test.sh
#
# The project manager REJECTS a manager-approval entry (state transition
# AwaitingManagerApproval -> Rejected), and the comment guard that protects it.
#
# WHY THIS EXISTS. Rejection is how a wrong timesheet gets corrected, and the
# manager stage is the one route to Rejected that this suite has never asserted.
# It existed only as un-asserted setup: lib/_tt692693.sh rejects entries so that
# verify-tt692693-c1-resubmit has something to resubmit, and nothing anywhere
# checks that the manager CAN reject, or that rejecting does what it claims.
# verify-pm-approve-action covers the other half of the same screen.
#
# THE PATH IS NOT A BUTTON ON THE DASHBOARD. Main.ProjectManagerDashboard carries
# exactly two controls per row - btnPMApprove and btnPMApproveAll - and no reject
# of any kind. The reject lives one screen deeper: the row itself is clickable
# and calls Main.ACT_AssignmentEntry_ShowApprovalPage, which opens
# Main.ReviewTimesheetEntry, and that page carries btnApprove, btnReject,
# txtRejectionComment and btnCancel. So "the PM rejects" means: click the row,
# then Reject in the review page. A test that looked for a reject button on the
# dashboard would report a missing control that was never there.
#
# THE TWO GUARDS. Main.ACT_Page_Reject branches twice before it changes anything:
#
#   "Not awaiting approval?"  -> show a message, end. (Someone else got there first.)
#   "Left Comments?"          -> show a message, end WITHOUT rejecting.
#
# The second is the one asserted here. It is what guarantees a rejection always
# carries a reason the consultant can act on; if it silently stopped firing,
# every rejection would become a mystery and no other test would notice. So this
# presses Reject with an EMPTY comment first and requires that nothing happened -
# the entry is still in the queue afterwards.
#
# WHY THE EMPTY-COMMENT ATTEMPT COMES FIRST. It is the cheap half and it leaves
# the entry untouched, so the expensive half (a real rejection, which consumes
# the entry) still has its subject. Reversed, the guard could only be tested
# against an entry that had already left the queue, where "nothing happened" is
# true for the wrong reason.
#
# CONSUMES ONE ENTRY on the manager-approval project, and self-seeds when the
# queue is empty - the same seeding block verify-pm-approve-action uses, including
# its poll, because workflow routing into the PM queue is asynchronous.
#
# Selectors: btnPMApprove / galPMPendingEntries (dashboard), btnReject /
# txtRejectionComment (Main.ReviewTimesheetEntry). All real widget names.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

PROJECT="${TT_PMREJECT_PROJECT:-E2E Manager Approval}"
CUSER="${TT_PMREJECT_USER:-e2e_consultant}"
COMMENT="E2E automated PM reject - hours look wrong for $PROJECT"

# ---------------------------------------------------------------------- helpers

# pmr_count — pending rows for $PROJECT in the PM gallery.
#
# Scoped to the project the same way verify-pm-approve-action does: walk up from
# each Approve button until an ancestor mentions the project, with a length cap so
# the walk cannot escape into an ancestor spanning several rows.
pmr_count() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; let m=0; for(const b of btns){let el=b; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; if(/$PROJECT/.test(el.innerText||'')&&(el.innerText||'').length<200){m++;break;}}} return String(m); }" 2>/dev/null | _tt_eval_str
}

# pmr_open_review — click the first $PROJECT row so its review page opens.
#
# The click target is the ROW, not a button: the on-click sits on the gallery
# item. Mendix renders a clickable gallery item as an <li> carrying role=button,
# so this walks up from the row's Approve button to the first such ancestor and
# clicks that. Falls back to the matched ancestor itself when the item is not an
# <li>, and says which it used, because a silent wrong-element click would look
# exactly like "the review page does not open".
pmr_open_review() {
  local r
  r="$(playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; for(const b of btns){ let el=b, row=null; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; const t=el.innerText||''; if(t.indexOf('$PROJECT')>=0 && t.length<200){ row=el; break; } } if(!row) continue; let li=row; for(let k=0;k<6;k++){ if(li.tagName==='LI'||li.getAttribute('role')==='button'){ li.click(); return 'li'; } if(!li.parentElement) break; li=li.parentElement; } row.click(); return 'row'; } return 'nf'; }" 2>/dev/null | _tt_eval_str)"
  [ "$r" != "nf" ] || return 1
  echo "  (opened the review page by clicking the $r)"
  sleep 4
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnReject'))" 2>/dev/null | grep -qiw true
}

pm_login_dash() { tt_login "e2e_pm" "Project Manager Dashboard"; }

# ------------------------------------------- 1. make sure there is one to reject
pm_login_dash
if [ "$(pmr_count)" = "0" ]; then
  echo "  no pending '$PROJECT' entry - submitting one as $CUSER"
  tt_login "$CUSER" "My Timesheets"
  tt_consultant_submit_project_row "$PROJECT"
  # Workflow routing to the PM's pending queue is asynchronous - poll rather than
  # looking once, which is what made an arriving entry read as an absent one.
  for _ in 1 2 3 4 5 6; do
    pm_login_dash
    [ "$(pmr_count)" != "0" ] && break
    sleep 6
  done
fi

BEFORE="$(pmr_count)"
[ "$BEFORE" != "0" ] || tt_fail "could not obtain a pending '$PROJECT' entry to reject (asynchronous workflow routing, or the project's ApprovalFromManager flag has changed - see lib/_fixtures.sh)"
echo "  the PM queue holds $BEFORE '$PROJECT' entr(y/ies)"

# ------------------------------------------------ 2. Reject with no comment
pmr_open_review || tt_fail "the review page did not open from the PM dashboard - Main.ACT_AssignmentEntry_ShowApprovalPage is behind the row's own on-click, and no .mx-name-btnReject appeared after clicking it"

# Deliberately do NOT touch txtRejectionComment. A comment left over from an
# earlier run would make this half pass for the wrong reason, so clear it first
# and prove it is empty before pressing anything.
playwright-cli fill ".mx-name-txtRejectionComment" "" >/dev/null 2>&1
tt_commit_focused
empty="$(playwright-cli eval "() => { const e=document.querySelector('.mx-name-txtRejectionComment'); if(!e) return 'absent'; const i=e.querySelector('textarea,input')||e; return String((i.value||'').trim().length); }" 2>/dev/null | _tt_eval_str)"
[ "$empty" = "0" ] || tt_fail "could not empty the rejection comment before the guard check (read back: [$empty]) - the assertion that follows would prove nothing"

playwright-cli click ".mx-name-btnReject" >/dev/null 2>&1
sleep 3
tt_dismiss_dialogs

pm_login_dash
GUARDED="$(pmr_count)"
if [ "$GUARDED" -lt "$BEFORE" ]; then
  echo "FAIL: Reject with an EMPTY comment removed an entry from the queue (before=$BEFORE, after=$GUARDED)."
  echo "      Main.ACT_Page_Reject's 'Left Comments?' branch is meant to show a message"
  echo "      and end WITHOUT rejecting. A rejection with no reason leaves the consultant"
  echo "      nothing to act on, and nothing else in this suite would notice."
  exit 1
fi
echo "  the empty-comment guard held (queue still $GUARDED)"

# --------------------------------------------- 3. Reject with a real comment
pmr_open_review || tt_fail "the review page did not reopen for the real rejection (it opened once already, so the row is there - suspect the first Reject left a dialog on screen)"

tt_fill_commit ".mx-name-txtRejectionComment" "$COMMENT"
typed="$(playwright-cli eval "() => { const e=document.querySelector('.mx-name-txtRejectionComment'); if(!e) return 'absent'; const i=e.querySelector('textarea,input')||e; return String((i.value||'').trim().length); }" 2>/dev/null | _tt_eval_str)"
case "$typed" in
  ''|*[!0-9]*) tt_fail "could not read the rejection comment back: [$typed]" ;;
  0) tt_fail "the rejection comment did not commit - a Mendix text area hands its value over on BLUR, so an uncommitted comment would trip the very guard this half is trying to get past" ;;
esac

playwright-cli click ".mx-name-btnReject" >/dev/null 2>&1
sleep 4
tt_dismiss_dialogs

# ------------------------------------------------------ 4. it left the queue
pm_login_dash
AFTER="$(pmr_count)"
[ "$AFTER" -lt "$BEFORE" ] || tt_fail "the rejected entry did not leave the PM queue (before=$BEFORE, after=$AFTER). The comment committed, so this is the rejection itself failing rather than the guard refusing it"
echo "  the entry left the PM queue (before=$BEFORE, after=$AFTER)"

# --------------------------------- 5. it came back to the consultant, rejected
tt_login "$CUSER" "My Timesheets"
tt_consultant_history_load >/dev/null 2>&1 || true
if [ "$(tt_rejected_has_project "$PROJECT")" != "true" ]; then
  echo "FAIL: the entry left the PM queue but did not arrive in the consultant's Rejected Entries."
  echo "      Rejected Entries currently shows: $(tt_rejected_projects)"
  echo "      A rejection that removes the entry from the approver's queue without"
  echo "      returning it to the consultant loses the week entirely - the consultant"
  echo "      has nothing to correct and HR never sees it again."
  exit 1
fi

echo "PASS: verify-pm-reject-action - the project manager rejected a '$PROJECT' entry (queue $BEFORE -> $AFTER), the empty-comment guard refused to reject without a reason, and the entry came back to $CUSER as Rejected"
