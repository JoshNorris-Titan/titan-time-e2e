#!/usr/bin/env bash
# verify-timesheet-clear-keeps-tasks.test.sh
#
# Clear keeps a row's tasks and zeroes their hours — it does not delete them.
#
# WHY THIS EXISTS. Until 2026-09-10 ACT_Timesheet_Clear DELETED every line item on
# each editable entry, so a consultant who cleared a week to start over lost their
# whole task list and had to retype it. Josh asked for the opposite: zero the hours,
# keep the names. This step is the assertion that separates the two behaviours —
# against the old flow the task count drops back to its starting value and this
# test goes red, which is the only reason it is worth having.
#
# The zero-versus-blank half of Clear lives in verify-timesheet-clear.test.sh. This
# one is separate because it needs a project with NeedsLineItems set (E2E Line
# Items, as verify-consultant-line-items.test.sh uses), while that step runs on
# E2E Sandbox.
#
# WHAT IT ASSERTS
#   A. After Clear, the task added by this test is STILL THERE, with its name
#      intact and the count unchanged.
#   B. Its hours are zeroed — the task's own day cells and its line total read 0,
#      not the 6s that were entered.
#
# THE TASK MUST BE SAVED BEFORE CLEAR IS PRESSED. ACT_Timesheet_Clear retrieves
# line items from the DATABASE ([Main.LineItem_AssignmentEntry = $IteratorAssignmentEntry]),
# so a task that only exists in the client is invisible to it. Clearing before a
# save would leave the task on screen untouched and the assertion would pass while
# proving nothing about the flow. Hence the Save Draft below, and the re-read after.
#
# CLEANUP. The task is deleted at the end, like verify-consultant-line-items does,
# so hours do not accumulate on the project for the suites that run after this one.
# The week is left cleared, which is a legitimate state for a Draft week.
#
# Uses e2e_consultant / E2E Line Items. Consumes one week.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CUSER="${TT_CLEARTASK_USER:-e2e_consultant}"
PROJECT="${TT_CLEARTASK_PROJECT:-E2E Line Items}"
TASKNAME="E2E Clear Keeps Task"
ROW=".mx-name-galAssignmentRows"
fails=0

note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# ------------------------------------------------------------------- helpers

task_count() {
  playwright-cli eval "() => String(document.querySelectorAll('$ROW .mx-name-txtLineItemName input').length)" 2>/dev/null | _tt_eval_str
}

task_name() {  # task_name <ordinal>
  playwright-cli eval "() => { const els=document.querySelectorAll('$ROW .mx-name-txtLineItemName input'); const el=els[$1-1]; return el ? String(el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str
}

# ordinal_of_task <name> — 1-based position of the task with that exact name, or 0.
# Read by NAME rather than remembering an index: Clear commits and refreshes the
# list, and nothing promises the rows come back in the order they went in.
ordinal_of_task() {
  playwright-cli eval "() => { const els=[...document.querySelectorAll('$ROW .mx-name-txtLineItemName input')]; const i=els.findIndex(e => (e.value||'').trim() === '$1'); return String(i+1); }" 2>/dev/null | _tt_eval_str
}

task_day() {  # task_day <ordinal> <Day>
  playwright-cli eval "() => { const els=document.querySelectorAll('$ROW .mx-name-txtLine$2 input'); const el=els[$1-1]; return el ? String(el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str
}

line_total() {  # line_total <ordinal>
  playwright-cli eval "() => { const els=document.querySelectorAll('$ROW .mx-name-txtLineTotal input'); const el=els[$1-1]; return el ? String(el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str
}

# is_zero — non-empty and numerically 0. A blank is NOT a zero: Clear is supposed
# to write an explicit 0, and on a task row a blank would also read as "no hours".
is_zero() {
  case "$1" in
    ""|__MISSING__) return 1 ;;
    *) awk -v v="$1" 'BEGIN{ gsub(/,/,".",v); exit (v+0==0 && v ~ /[0-9]/) ? 0 : 1 }' ;;
  esac
}

# Expand the tasks section — click whichever toggle is visible until Add Task shows.
expand_tasks() {
  local i tgl
  for i in 1 2 3; do
    playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnAddTask'); return String(!!b && b.offsetParent!==null); }" 2>/dev/null | grep -qiw true && return 0
    tgl="$(playwright-cli eval "() => { for (const s of ['btnLineItemsCollapse','btnLineItemsExpand']){ const t=document.querySelector('.mx-name-'+s); if (t && t.offsetParent!==null) return s; } return ''; }" 2>/dev/null | _tt_eval_str)"
    [ -n "$tgl" ] && playwright-cli click ".mx-name-$tgl" >/dev/null 2>&1
    sleep 2
  done
  playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnAddTask'); return String(!!b && b.offsetParent!==null); }" 2>/dev/null | grep -qiw true
}

# ------------------------------------------------------------------- setup

tt_login "$CUSER" "My Timesheets"

# Find a week that has the project row AND still has its action buttons. Clear,
# Save and Submit are hidden together once a week leaves Draft/Rejected/empty, so
# a week without them cannot exercise Clear at all.
found=""
for _ in $(seq 1 12); do
  if playwright-cli eval "() => String(((document.querySelector('$ROW')||{}).innerText||'').indexOf('$PROJECT') >= 0)" 2>/dev/null | grep -qiw true; then
    [ "$(tt_week_actionable)" = "true" ] && { found=1; break; }
  fi
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ -n "$found" ] || tt_fail "no editable week with a '$PROJECT' row for $CUSER — cannot exercise Clear on a week that has tasks"
WEEK="$(tt_current_week)"
echo "clear-keeps-tasks on week '$WEEK'"

expand_tasks || tt_fail "the tasks section would not expand on week '$WEEK' (no Add Task button) — Clear could not be exercised against a task"

# Debris from an interrupted run makes the whole week unsaveable, and this test
# has to save. Refuse rather than fail later at the save with a confusing message.
tt_assert_no_unnamed_tasks "$ROW"
N0="$(task_count)"
case "$N0" in ''|*[!0-9]*) tt_fail "could not count the existing tasks on week '$WEEK' (got '$N0')" ;; esac
echo "existing tasks: $N0"

# ------------------------------------------------- add a task, fill it, save it

playwright-cli click ".mx-name-btnAddTask" >/dev/null 2>&1
sleep 2; tt_clear_dialogs 6 >/dev/null 2>&1 || true
[ "$(task_count)" = "$((N0 + 1))" ] || tt_fail "Add Task did not add a row on week '$WEEK' (before=$N0, after=$(task_count))"
IDX=$((N0 + 1))

playwright-cli fill ":nth-match($ROW .mx-name-txtLineItemName input, $IDX)" "$TASKNAME" >/dev/null 2>&1
for d in Mon Tues Wed; do
  playwright-cli fill ":nth-match($ROW .mx-name-txtLine${d} input, $IDX)" "6" >/dev/null 2>&1
done
# Blur onto another field: a Mendix input commits on blur, never on fill alone.
playwright-cli click ":nth-match($ROW .mx-name-txtLineItemName input, $IDX)" >/dev/null 2>&1
sleep 2; tt_clear_dialogs 6 >/dev/null 2>&1 || true
tt_assert_task_named "$ROW" "$IDX" "$TASKNAME"

# 18 hours across three days. Asserted before the Clear so that a zero afterwards
# is provably Clear's work and not a task that never had hours in the first place.
LT="$(line_total "$IDX")"
is_zero "$LT" && tt_fail "the task's line total read [$LT] BEFORE Clear, so a zero after it would prove nothing. The 6s did not land — a fill or the rollup nanoflow failed, which is a fixture fault, not a Clear one."

if ! playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1; then
  tt_fail "no Save Draft button on week '$WEEK' (week status: $(tt_week_status "$CUSER" "$WEEK")) — the task could not be persisted, and Clear only sees line items that are in the database"
fi
sleep 3
if ! tt_clear_dialogs 8; then
  tt_fail "a dialog blocked the save on week '$WEEK': \"$TT_DIALOG_BLOCKED\" — the task was not persisted, so Clear would not see it"
fi
tt_refetch_week
expand_tasks || tt_fail "the tasks section would not re-expand after saving week '$WEEK'"

SAVED_ORD="$(ordinal_of_task "$TASKNAME")"
[ "$SAVED_ORD" != "0" ] || tt_fail "the task '$TASKNAME' is not on week '$WEEK' after saving (tasks now: $(task_count)) — it was never persisted, so this test cannot say anything about Clear"
N_BEFORE="$(task_count)"

# ------------------------------------------------------------------- the Clear

if [ "$(tt_week_actionable)" != "true" ]; then
  tt_fail "week '$WEEK' lost its Clear button after the save (week status: $(tt_week_status "$CUSER" "$WEEK")) — Clear was never exercised"
fi
playwright-cli click ".mx-name-btnClear" >/dev/null 2>&1 || tt_fail "the Clear button could not be clicked on week '$WEEK'"
sleep 3
CLEAR_DIALOG="$(playwright-cli eval "() => { const all=[...document.querySelectorAll('.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]')].filter(d=>d.offsetParent!==null); const d=all.filter(x=>!all.some(o=>o!==x && o.contains(x))).pop(); return d ? (d.innerText||'').replace(/\s+/g,' ').trim().slice(0,240) : ''; }" 2>/dev/null | _tt_eval_str)"
if ! tt_clear_dialogs 8 "Clear"; then
  tt_fail "a dialog blocked the Clear on week '$WEEK', so it never ran: \"$TT_DIALOG_BLOCKED\""
fi
sleep 2
expand_tasks || bad "the tasks section would not expand after Clear on week '$WEEK' (dialog at the click: \"${CLEAR_DIALOG:-none}\") — the task list could not be read back"

# ------------------------------------------------- A. the task is still there

ORD="$(ordinal_of_task "$TASKNAME")"
N_AFTER="$(task_count)"

if [ "$ORD" = "0" ]; then
  if [ "$N_AFTER" = "$N0" ]; then
    bad "A Clear DELETED the tasks. '$TASKNAME' is gone and the count fell from $N_BEFORE back to $N0, which is what ACT_Timesheet_Clear did before 2026-09-10 — so either the keep-the-tasks change is not deployed to this environment, or it was reverted. Clear must keep each task and zero its hours."
  else
    bad "A the task '$TASKNAME' is not in the list after Clear, and the count is $N_AFTER (was $N_BEFORE, started $N0) — so this is not a clean delete-everything either. Read the list on screen before assuming which half is wrong."
  fi
else
  [ "$N_AFTER" = "$N_BEFORE" ] \
    && note "A Clear kept all $N_AFTER task(s); '$TASKNAME' is still named correctly" \
    || bad "A '$TASKNAME' survived Clear but the task count changed from $N_BEFORE to $N_AFTER — Clear should not add or remove tasks at all"

  # --------------------------------------------- B. its hours are zeroed
  notzero=""
  for d in Mon Tues Wed Thurs Fri Sat Sun; do
    v="$(task_day "$ORD" "$d")"
    case "$v" in
      __MISSING__) : ;;   # not every day cell need exist for a task row
      *) is_zero "$v" || notzero="$notzero $d=[${v:-blank}]" ;;
    esac
  done
  LT_AFTER="$(line_total "$ORD")"
  is_zero "$LT_AFTER" || notzero="$notzero total=[${LT_AFTER:-blank}]"

  [ -z "$notzero" ] \
    && note "B the kept task's hours and line total all read 0 (were 18 across three days)" \
    || bad "B Clear kept the task but did not zero its hours —$notzero. The whole point of keeping the row is that the NAME survives and the HOURS do not."
fi

# ------------------------------------------------------------------- cleanup
# Delete the task this test added, so its hours cannot accumulate on the project
# for the suites that run after this one. A cleanup that silently does not clean
# up is reported, not warned about.
tries=0
while [ "$(ordinal_of_task "$TASKNAME")" != "0" ] && [ "$tries" -lt 6 ]; do
  playwright-cli click ":nth-match($ROW .mx-name-btnLineItemDelete, $(ordinal_of_task "$TASKNAME"))" >/dev/null 2>&1
  sleep 2; tt_clear_dialogs 6 >/dev/null 2>&1 || true
  tries=$((tries + 1))
done
if [ "$(ordinal_of_task "$TASKNAME")" != "0" ]; then
  bad "cleanup left '$TASKNAME' on week '$WEEK' after $tries attempt(s). It carries no hours after the Clear, but it does skew task counts for every later test on this week — delete it before re-running."
else
  playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 || true
  sleep 2; tt_clear_dialogs 6 >/dev/null 2>&1 || true
fi

if [ "$fails" -gt 0 ]; then
  echo "FAIL: clear-keeps-tasks — $fails case(s) failed on week '$WEEK'"
  exit 1
fi
echo "PASS: Clear keeps the tasks and zeroes their hours ($WEEK)"
