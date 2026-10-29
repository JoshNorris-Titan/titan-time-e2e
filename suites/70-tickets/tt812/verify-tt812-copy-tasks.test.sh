#!/usr/bin/env bash
# tt-timeout: 10m
# verify-tt812-copy-tasks.test.sh
#
# TT-812: "Copy Tasks" beside "Add your first task" copies the task NAMES from the
# consultant's last submitted week on the same project, never the hours.
#
# WHY THIS EXISTS. The whole agreement behind the button (Warren, 2026-10-28) is
# that hours are never copied, so consultants cannot resubmit last week's numbers
# without thinking. A copy that brought the hours along would still look like it
# worked. This spec reads every copied day box back.
#
# WHAT IT ASSERTS, on an editable week whose 'E2E Line Items' row has no tasks
# (precondition, fatal: the first-task prompt is visible, AND btnCopyTasks is in
# it — which needs an earlier submitted week with named tasks on that project;
# verify-tt654-a3-lineitems-submit leaves one earlier in the run)
#   A. btnCopyTasks's tooltip is the agreed wording, word for word;
#   B. after the press the row has at least one task, and every task has a name;
#   C. every day box of every copied task reads 0 — no hours were copied;
#   D. the task panel is open and the prompt (and so Copy Tasks) is gone.
#
# CLEANUP. Every copied task is deleted, so the week goes back to the prompt.
# A cleanup that fails is reported as a failure, not a warning.
#
# Consumes nothing. Uses e2e_consultant / E2E Line Items (lib/_tt788.sh).
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt788.sh"

TOOLTIP="This will only copy your previously submitted timesheet tasks for this assignment/project. This will not copy the hours."
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# The row's copy-tasks facts as "key=value;...": copy (btnCopyTasks in the row),
# title (its tooltip), names ('|'-joined task names), hours (sum of every task day
# box), unnamed (tasks with an empty name).
tt812_probe() {
  playwright-cli eval "() => {
    const row = $(_tt_task_row_js "$TT788_PROJECT");
    if (!row) return 'row=0';
    const btn = row.querySelector('.mx-name-btnCopyTasks');
    const items = [...row.querySelectorAll('.mx-name-galLineItems .widget-gallery-item')];
    const names = items.map(i => { const n = i.querySelector('.mx-name-txtLineItemName input'); return n ? (n.value || '').trim() : ''; });
    const days = ['Sun','Mon','Tues','Wed','Thurs','Fri','Sat'];
    let hours = 0;
    for (const i of items) for (const d of days) { const e = i.querySelector('.mx-name-txtLine' + d + ' input'); hours += e ? (parseFloat(e.value) || 0) : 0; }
    const o = { row: 1, copy: btn ? 1 : 0, title: btn ? (btn.getAttribute('title') || '') : '', names: names.join('|'), hours, unnamed: names.filter(n => !n).length };
    return Object.entries(o).map(([k, v]) => k + '=' + String(v).replace(/[;=]/g, ' ')).join(';');
  }" 2>/dev/null | _tt_eval_str
}

tt_login "$TT788_CONSULTANT" "My Timesheets"

tt788_find_week empty-editable \
  || tt_fail "no editable week with a task-less '$TT788_PROJECT' row within $TT788_HORIZON weeks for $TT788_CONSULTANT
  $(tt788_census_help)"
note "week $TT788_WEEK"

P="$(tt788_probe)"
[ "$(tt788_get "$P" prompt)" = "1" ] \
  || tt_fail "precondition: the first-task prompt is not visible on week $TT788_WEEK (probe: $P). verify-tt788-prompt-shown says why."
# The button's gallery runs a server data source; give it a few looks.
for _ in 1 2 3 4 5; do C="$(tt812_probe)"; [ "$(tt788_get "$C" copy)" = "1" ] && break; sleep 1; done
[ "$(tt788_get "$C" copy)" = "1" ] \
  || tt_fail "precondition: no Copy Tasks button on week $TT788_WEEK. It only shows when an EARLIER week of '$TT788_PROJECT' was submitted with named tasks — verify-tt654-a3-lineitems-submit leaves one; if TT-812 is not deployed there is no button at all (probe: $C)"

# A. tooltip
[ "$(tt788_get "$C" title)" = "$TOOLTIP" ] \
  && note "A ok: the tooltip is the agreed wording" \
  || bad "A tooltip is \"$(tt788_get "$C" title)\", expected \"$TOOLTIP\""

playwright-cli click ".mx-name-galAssignmentRows .mx-name-btnCopyTasks" >/dev/null 2>&1 \
  || tt_fail "btnCopyTasks could not be clicked on week $TT788_WEEK"

for _ in $(seq 1 12); do
  sleep 1
  P="$(tt788_probe)"
  [ "$(tt788_get "$P" tasks)" != "0" ] && [ "$(tt788_get "$P" state)" = "open" ] && break
done
tt_clear_dialogs 4 >/dev/null 2>&1
sleep 1
P="$(tt788_probe)"; C="$(tt812_probe)"
note "probe after the press: $P"
note "copy probe after the press: $C"

# B. tasks with names
N="$(tt788_get "$P" tasks)"
if [ "${N:-0}" -ge 1 ] 2>/dev/null; then
  note "B ok: $N task(s) copied: $(tt788_get "$C" names)"
else
  bad "B no task was copied onto week $TT788_WEEK"
fi
[ "$(tt788_get "$C" unnamed)" = "0" ] \
  && note "B ok: every copied task has a name" \
  || bad "B $(tt788_get "$C" unnamed) copied task(s) have no name"

# C. no hours
[ "$(tt788_get "$C" hours)" = "0" ] \
  && note "C ok: every copied day box reads 0" \
  || bad "C the copied tasks carry $(tt788_get "$C" hours) hours — hours must never be copied"

# D. panel open, prompt and button gone
[ "$(tt788_get "$P" state)" = "open" ] \
  && note "D ok: the task panel is open" \
  || bad "D the task panel is not open after the copy (state: $(tt788_get "$P" state))"
[ "$(tt788_get "$P" prompt)" = "0" ] && [ "$(tt788_get "$C" copy)" = "0" ] \
  && note "D ok: the prompt and Copy Tasks are gone" \
  || bad "D the prompt or Copy Tasks is still showing although the row now has tasks"

# ------------------------------------------------------------------ cleanup
IFS='|' read -r -a COPIED <<< "$(tt788_get "$C" names)"
for name in "${COPIED[@]}"; do
  [ -n "$name" ] || continue
  tt788_delete_task "$name" || bad "cleanup: could not delete '$name' from week $TT788_WEEK"
done
tt788_delete_task "" || bad "cleanup: an unnamed task is left on week $TT788_WEEK — it makes the whole week unsaveable; delete it before re-running"
[ "$(tt_task_count "$TT788_PROJECT")" = "0" ] \
  || bad "cleanup: week $TT788_WEEK still has $(tt_task_count "$TT788_PROJECT") task(s) on '$TT788_PROJECT'"

if [ "$fails" -gt 0 ]; then
  echo "FAIL: verify-tt812-copy-tasks — $fails check(s) failed on week $TT788_WEEK"
  exit 1
fi
echo "PASS: verify-tt812-copy-tasks — names copied, no hours, panel open ($TT788_WEEK)"
