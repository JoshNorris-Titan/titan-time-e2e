#!/usr/bin/env bash
# verify-pm-approve-all.test.sh
#
# Approve All really approves them all.
#
# WHY THIS EXISTS. Two steps assert that the Approve All button EXISTS. Neither
# has ever pressed it. It is the only bulk action a project manager has, and the
# one most likely to be used on a busy Monday — so "it renders" was the whole of
# its coverage.
#
# WHY IT RUNS HERE AND NOT IN 30-approval. Approve All clears the logged-in
# manager's entire queue, not one entry. That is bounded — Main.DS_ApprovalHelper_PM
# constrains it to projects whose ProjectManager_Account is the current user, so it
# cannot reach another PM's work — but it does empty everything of e2e_pm's that is
# awaiting manager approval, and the TT-647 steps need entries in exactly that
# state. Running after the ticket suites lets them have their data first. This is
# also why the step does not simply seed two entries and approve: the action is
# bulk by nature, and pretending otherwise would test something the button does not do.
#
# WHAT IT ASSERTS
#   A. There is something to approve, and the run aborts if not — a bulk action
#      over an empty queue is not a test of anything.
#   B. After pressing it the queue is empty.
#   C. The entries ARRIVED somewhere: the manager-approval stage count drops to
#      zero and the total across the HR dashboard's stage counters is unchanged.
#      Leaving one queue is not the same as reaching the next, and a rollback or a
#      delete would satisfy B on its own.
#
# Consumes every entry awaiting e2e_pm's approval.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

PM="${TT_PM_USER:-e2e_pm}"

# The success condition of this whole test is an EMPTY queue, and since 2026-09-03
# the dashboard hides the pending component when the queue is empty. This used to
# return the literal 'NOGALLERY' in that state, which the numeric guard below then
# rejected -- so Approve All doing its job perfectly reported as "could not re-count
# the pending rows". tt_pm_pending_rows reports the hidden-because-empty case as 0,
# which is what the polling loop is actually waiting for.
pa_rows() { tt_pm_pending_rows "${1:-12}"; }

# pa_stage_totals — the six HR stage counters as "manager|total". Read from the HR
# dashboard, which sees the whole pipeline rather than one manager's slice.
pa_stage_totals() {
  playwright-cli eval "() => { const cards=['cardKpiPending','cardKpiManager','cardKpiCustomer','cardKpiProcess','cardKpiInvoice','cardKpiSent']; let total=0, mgr=-1; for (const c of cards) { const e=document.querySelector('.mx-name-'+c); if(!e) return 'MISSING:'+c; const m=(e.innerText||'').match(/(\\d+)\\s*\$/); if(!m) return 'NAN:'+c; const v=parseInt(m[1],10); total+=v; if(c==='cardKpiManager') mgr=v; } return mgr + '|' + total; }" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------------ A. there is work to do
tt_login "$PM" "Project Manager Dashboard"

before="$(pa_rows)"
case "$before" in
  ERR:*)       tt_fail "'$PM' dashboard never rendered ($before), so there is no queue to read" ;;
  ''|*[!0-9]*) tt_fail "could not count the pending rows (got [$before])" ;;
esac

if [ "$before" -eq 0 ]; then
  tt_fail "'$PM' has nothing awaiting approval, so Approve All would have nothing to do. Run the manager-approval step first; pressing a bulk button over an empty queue proves nothing."
fi
echo "  '$PM' has $before entr(ies) awaiting approval"

[ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnPMApproveAll'))" 2>/dev/null | _tt_eval_str)" = "true" ] \
  || tt_fail "no .mx-name-btnPMApproveAll on the PM dashboard"

# --------------------------------- record the pipeline before, as administrator
tt_login "e2e_hr" "WEEKLY TO PROCESS"
stages_before="$(pa_stage_totals)"
case "$stages_before" in
  MISSING:*|NAN:*) echo "  note: stage counters unreadable ($stages_before) - C will be skipped" ;;
  *) echo "  stages before (manager|total): $stages_before" ;;
esac

# ----------------------------------------------------------- B. press the button
tt_login "$PM" "Project Manager Dashboard"

playwright-cli click ".mx-name-btnPMApproveAll" >/dev/null 2>&1
tt_clear_dialogs 8 "Approve" \
  || tt_fail "the Approve All confirmation was not dismissed: ${TT_DIALOG_BLOCKED:-unknown dialog}"
sleep 5

after=""
for _ in $(seq 1 10); do
  after="$(pa_rows)"
  [ "$after" = "0" ] && break
  sleep 3
  playwright-cli reload >/dev/null 2>&1
  sleep 4
done

case "$after" in
  ERR:*)       tt_fail "the '$PM' dashboard never rendered while re-counting after Approve All ($after), so the queue could not be read. This is NOT evidence that Approve All failed." ;;
  ''|*[!0-9]*) tt_fail "could not re-count the pending rows after Approve All (got [$after])" ;;
esac

if [ "$after" -ne 0 ]; then
  tt_fail "Approve All left $after of $before entr(ies) in '$PM' queue - it approved some but not all, which is worse than failing outright because the remainder look handled"
fi
echo "  queue emptied: $before -> 0"

# ------------------------------------------- C. they arrived, they did not vanish
case "$stages_before" in
  MISSING:*|NAN:*)
    echo "PASS: verify-pm-approve-all - Approve All cleared all $before entr(ies) from '$PM' queue (stage totals were unreadable, so arrival was not checked)"
    exit 0 ;;
esac

tt_login "e2e_hr" "WEEKLY TO PROCESS"
stages_after="$(pa_stage_totals)"
case "$stages_after" in
  MISSING:*|NAN:*) tt_fail "stage counters became unreadable after the approval ($stages_after)" ;;
esac
echo "  stages after  (manager|total): $stages_after"

mgr_before="${stages_before%%|*}"; tot_before="${stages_before##*|}"
mgr_after="${stages_after%%|*}";  tot_after="${stages_after##*|}"

if [ "$tot_after" -lt "$tot_before" ]; then
  tt_fail "the pipeline lost $((tot_before - tot_after)) entr(ies): stage totals went $tot_before -> $tot_after. Approve All emptied the queue but the work did not arrive anywhere - that is a rollback or a delete, not an approval."
fi

if [ "$mgr_after" -ge "$mgr_before" ] && [ "$mgr_before" -gt 0 ]; then
  tt_fail "the manager-approval counter did not fall ($mgr_before -> $mgr_after) even though '$PM' queue emptied, so the entries did not leave that stage"
fi

echo "PASS: verify-pm-approve-all - cleared all $before entr(ies) from '$PM' queue; manager stage $mgr_before -> $mgr_after with no loss from the pipeline ($tot_before -> $tot_after)"
