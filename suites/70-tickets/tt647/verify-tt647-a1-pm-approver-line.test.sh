#!/usr/bin/env bash
# TT-647 angle 1 — a PM-approved entry shows the PROJECT MANAGER as the approver.
#
# Path: consultant submits on "E2E Manager Approval" (ApprovalFromManager=Yes,
# ApprovalFromCustomer=No) -> PM approves from the PM dashboard -> entry lands in
# ToProcess. Main.ACT_ApprovalHelper_Approve records ChangeBy = the approving
# account's name, which on this path is the project's own PM.
#
# Asserts on the HR "Weekly Timesheets to Process" tab:
#   line 1 = "E2E ProjectManger"  (the manager-stage approver, a bare name)
#   line 2 = "N/A"                (a manager-only project has no client stage)
#
# Seeds and consumes its own manager-approval entry every run. Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

PROJECT="E2E Manager Approval"
PM_NAME="E2E ProjectManger"
CUSER="${TT_A1_USER:-e2e_consultant}"
CNAME="${TT_A1_CONSULTANT_NAME:-E2E Consultant}"

# WHICH ENTRY (2026-09-29). This used to approve the FIRST 'E2E Manager Approval'
# row in the PM queue - whatever an earlier step had left there - and then read the
# NEWEST To Process week that merely mentioned the project. In a full run those are
# different entries: verify-submit-empty-week submits E2E Consultant Two's blank
# week, and its zero-hour 'E2E Manager Approval' entry goes straight to ToProcess
# with no approval at all, so both lines legitimately read 'N/A'. Run 36553422511
# read that card (week Nov 08 - Nov 14) and reported it as a TT-647 defect.
# Now the step submits its OWN entry, approves THAT row (consultant, project and
# week all matched), and reads THAT card - the way a2/a6 already pin theirs.

# a1_pm_ordinal <week-key> - 1-based index of the btnPMApprove on the PM row for
# $CNAME / $PROJECT / <week-key>, or 0. A row is the smallest ancestor of the
# button that holds no other btnPMApprove; its first line is the consultant, which
# is compared EXACTLY because 'E2E Consultant' is a prefix of 'E2E Consultant Two'.
# (The row's text widgets are auto-named - text7/text3/text4 - so they are read as
# the row's text rather than by name.)
a1_pm_ordinal() {
  playwright-cli eval "() => { const btns=[...document.querySelectorAll('.mx-name-galPMPendingEntries .mx-name-btnPMApprove')]; for(let n=0;n<btns.length;n++){ let el=btns[n], row=null; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('.mx-name-btnPMApprove').length!==1) break; row=el; } if(!row) continue; const t=row.innerText||''; const first=t.split('\n').map(x=>x.trim()).filter(Boolean)[0]||''; if(first==='$CNAME' && t.indexOf('$PROJECT')>=0 && t.indexOf('$1')>=0) return String(n+1); } return '0'; }" 2>/dev/null | _tt_eval_str
}
pm_login_dash() { tt_login "e2e_pm" "Project Manager Dashboard"; }

# 1) Submit this step's own entry on the manager-approval project.
tt_login "$CUSER" "My Timesheets"
tt_consultant_submit_project_row "$PROJECT"
WEEK="$TT_SUBMITTED_WEEK"
[ -n "$WEEK" ] || tt_fail "could not record which week was submitted - cannot tell this step's entry from any other '$PROJECT' entry"
echo "seeded '$PROJECT' for $CNAME on week: $WEEK"

# 2) Approve THAT entry AS THE PM - this is what makes ChangeMethod = Manager.
#    Routing into the PM queue is asynchronous; poll rather than look once.
ORD=0
for _ in 1 2 3 4 5 6; do
  pm_login_dash
  ORD="$(a1_pm_ordinal "$WEEK")"
  case "$ORD" in ''|*[!0-9]*) ORD=0 ;; esac
  [ "$ORD" != "0" ] && break
  sleep 6
done
[ "$ORD" != "0" ] || tt_fail "no '$PROJECT' row for '$CNAME' in week '$WEEK' reached the PM queue (async workflow routing?)"

playwright-cli click ":nth-match(.mx-name-galPMPendingEntries .mx-name-btnPMApprove, ${ORD})" >/dev/null 2>&1
sleep 4

# 3) Read the approver lines off THAT entry's card on the HR To Process tab.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
tt647_wait_for_card "$WEEK" "$PROJECT" "$CNAME" \
  || tt_fail "no '$PROJECT' card for '$CNAME' in week '$WEEK' on the To Process tab after PM approval. ${TT647_WAIT_ERR:-}"
echo "matched To Process week: $WEEK"

tt647_require_widgets "To Process tab"

# The card whose consultant widget reads EXACTLY $CNAME (not a prefix match -
# E2E Consultant Two can have a '$PROJECT' card in the same week).
LINES="$(playwright-cli eval "() => { const g=document.querySelector('$TT_HR_ENTRIES_ANY'); if(!g) return ''; const c=[...g.querySelectorAll('$TT_HR_CARD_ANY')].find(x=>{ const who=x.querySelector('$TT_HR_TXT_CONSULTANT_ANY'); return who && (who.innerText||'').trim()==='$CNAME' && (x.innerText||'').indexOf('$PROJECT')>=0; }); if(!c) return ''; const a=c.querySelector('$TT_HR_TXT_APPROVER1'); const b=c.querySelector('$TT_HR_TXT_APPROVER2'); return (((a&&a.innerText)||'').trim())+'~~'+(((b&&b.innerText)||'').trim()); }" 2>/dev/null | _tt_eval_str)"
[ -n "$LINES" ] || tt_fail "the To Process week '$WEEK' shows no '$PROJECT' card whose consultant reads exactly '$CNAME'"
L1="${LINES%%~~*}"
L2="${LINES#*~~}"
echo "line1: '$L1'"
echo "line2: '$L2'"

[ -n "$L1" ] || tt_fail "To Process card for '$PROJECT' has an empty approver line 1"

# Line 1 is the manager-stage approver's name verbatim, nothing more.
[ "$L1" = "$PM_NAME" ]   || tt_fail "line 1 should be the PM's name for a PM-approved entry. got: '$L1' (wanted '$PM_NAME')"

# A manager-only project has no client stage, so line 2 is the empty marker.
[ "$L2" = "N/A" ]   || tt_fail "line 2 should be 'N/A' on a manager-only project, got: '$L2'"

echo "PASS: verify-tt647-a1-pm-approver-line — line1='$L1' line2='$L2'"
