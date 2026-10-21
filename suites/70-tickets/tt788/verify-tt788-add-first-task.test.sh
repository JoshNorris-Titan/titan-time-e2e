#!/usr/bin/env bash
# tt-timeout: 10m
# verify-tt788-add-first-task.test.sh
#
# TT-788 #2: pressing "Add your first task" creates ONE task, opens the task panel
# and puts the cursor in that task's empty name.
#
# WHY THIS EXISTS. The prompt is only worth having if its button lands the
# consultant where they type next. Three things can each go wrong on their own:
# the task is created but the panel stays shut (the new task is invisible), the
# panel opens but nothing has focus (they have to find the box), or the nanoflow
# runs twice and leaves two tasks — one of them unnamed, which makes the whole
# week unsaveable (lib/_login_waits.sh, "Line-item name guards").
#
# WHAT IT ASSERTS, on an editable week whose 'E2E Line Items' row has no tasks
# (precondition, fatal: the prompt and its button are visible there)
#   A. exactly ONE task exists after the press — not zero, not two;
#   B. the panel is open: cntRowTasks no longer carries tt-tasks-collapsed, its
#      contents are visible and btnAddTask is visible, and the prompt is gone;
#   C. the focused element is that task's name input (.mx-name-txtLineItemName
#      input), and it is empty.
# B and C are polled for a few seconds: the panel opens with a ~300-600ms
# transition, and the focus is set by a JavaScript action after the nanoflow.
#
# CLEANUP. The task is named and then deleted, so the week goes back to how it
# was found (the prompt) and no unnamed task is left behind. A cleanup that
# fails is reported as a failure, not a warning.
#
# Consumes nothing. Uses e2e_consultant / E2E Line Items.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt788.sh"

TASKNAME="TT788 First Task"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

tt_login "$TT788_CONSULTANT" "My Timesheets"

tt788_find_week empty-editable \
  || tt_fail "no editable week with a task-less '$TT788_PROJECT' row within $TT788_HORIZON weeks for $TT788_CONSULTANT
  $(tt788_census_help)"
note "week $TT788_WEEK"

P="$(tt788_probe)"
[ "$(tt788_get "$P" prompt)" = "1" ] && [ "$(tt788_get "$P" addfirst)" = "1" ] \
  || tt_fail "precondition: the first-task prompt and its button are not visible on week $TT788_WEEK, so there is nothing to press (probe: $P). verify-tt788-prompt-shown says why."

# A real click, not a JS one: the focus assertion is about what a person's click
# leaves focused. Scoped to the grid; one task row per week, so one prompt.
playwright-cli click ".mx-name-galAssignmentRows .mx-name-btnAddFirstTask" >/dev/null 2>&1 \
  || tt_fail "btnAddFirstTask could not be clicked on week $TT788_WEEK (more than one on the grid, or not actionable)"

# Poll until the panel is open and something has settled, up to ~12s.
for _ in $(seq 1 12); do
  sleep 1
  P="$(tt788_probe)"
  [ "$(tt788_get "$P" state)" = "open" ] && [ "$(tt788_get "$P" focus)" != "0" ] && break
done
tt_clear_dialogs 4 >/dev/null 2>&1
sleep 1   # let the open spring finish before reading visibility
P="$(tt788_probe)"
note "probe after the press: $P"
g() { tt788_get "$P" "$1"; }

# A. exactly one task
case "$(g tasks)" in
  1) note "A ok: one task was created" ;;
  0) bad "A no task was created by btnAddFirstTask" ;;
  *) bad "A btnAddFirstTask created $(g tasks) tasks, expected exactly one" ;;
esac

# B. panel open, prompt gone
[ "$(g collapsed)" = "0" ] \
  && note "B ok: cntRowTasks is not collapsed" \
  || bad "B cntRowTasks still carries tt-tasks-collapsed after the press"
[ "$(g state)" = "open" ] \
  && note "B ok: the panel's contents are visible" \
  || bad "B the task panel is not open after the press (state: $(g state))"
[ "$(g addtask)" = "1" ] \
  && note "B ok: btnAddTask is visible in the open panel" \
  || bad "B btnAddTask is not visible after the press — the panel did not really open"
[ "$(g prompt)" = "0" ] \
  && note "B ok: the prompt is gone" \
  || bad "B the prompt is still showing although a task now exists"

# C. focus on the new task's empty name
if [ "$(g focus)" = "0" ]; then
  FOC="$(playwright-cli eval "() => { const a=document.activeElement; if(!a) return 'none'; const n=a.closest('[class*=mx-name-]'); return a.tagName + ' in ' + (n ? ([...n.classList].find(c=>c.startsWith('mx-name-'))||'?') : '(no named widget)'); }" 2>/dev/null | _tt_eval_str)"
  bad "C the new task's name is not focused (focus is on: $FOC)"
else
  [ "$(g focus)" = "$(g tasks)" ] \
    && note "C ok: the focus is on task #$(g focus)'s name" \
    || bad "C the focus is on task #$(g focus)'s name, but the new task is #$(g tasks)"
  [ -z "$(g focus_val)" ] \
    && note "C ok: the focused name is empty" \
    || bad "C the focused name is not empty: \"$(g focus_val)\""
fi

# ------------------------------------------------------------------ cleanup
# Name before deleting: if the delete misses, a NAMED task is skew, an unnamed one
# is poison for every save on the week.
N="$(g tasks)"
if [ "${N:-0}" -ge 1 ] 2>/dev/null; then
  tt788_name_task "$N" "$TASKNAME" || note "note: naming the task for cleanup did not stick; deleting it unnamed"
  tt788_delete_task "$TASKNAME" || bad "cleanup: could not delete '$TASKNAME' from week $TT788_WEEK"
  tt788_delete_task "" || bad "cleanup: an unnamed task is left on week $TT788_WEEK — it makes the whole week unsaveable; delete it before re-running"
  [ "$(tt_task_count "$TT788_PROJECT")" = "0" ] \
    || bad "cleanup: week $TT788_WEEK still has $(tt_task_count "$TT788_PROJECT") task(s) on '$TT788_PROJECT'"
fi

if [ "$fails" -gt 0 ]; then
  echo "FAIL: verify-tt788-add-first-task — $fails check(s) failed on week $TT788_WEEK"
  exit 1
fi
echo "PASS: verify-tt788-add-first-task — one task, panel open, its empty name focused ($TT788_WEEK)"
