#!/usr/bin/env bash
# tt-timeout: 10m
# verify-tt788-prompt-gone-with-task.test.sh
#
# TT-788 #3: once a task-based row has a task, the prompt is gone and the row is
# what it was before TT-788 — day totals, row total and the show/hide chevron.
#
# WHY THIS EXISTS. The prompt is keyed on an EMPTY task list (galFirstTask's empty
# placeholder), and the CSS that hides the day cells is keyed on the prompt being
# present. If either key is wrong the prompt outlives the first task, and the row
# then hides the very totals the consultant is building — or the chevron stays
# hidden and the panel can never be shut again.
#
# WHAT IT ASSERTS, on an editable week whose 'E2E Line Items' row starts with no
# tasks (precondition, fatal: the prompt is showing — so the "gone" below is a
# change this spec watched happen, not a row that never had it)
#   A. with one named task, in the same page session: the prompt is not visible,
#      all seven day cells and the row total are visible, a chevron is visible;
#   B. the same after the week is re-fetched from the server (step back and
#      forward), so it is the saved task and not client state that drives it;
#   C. with the panel CLOSED by its chevron the prompt still stays away and the
#      totals stay — a collapsed panel with tasks is not an empty one;
#   D. deleting the task brings the prompt back (the reverse edge).
#
# Consumes nothing: the task is deleted in D, which is also the cleanup.
# Uses e2e_consultant / E2E Line Items.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt788.sh"

TASKNAME="TT788 Has Task"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# expect_restored <label> — the row looks like a pre-TT-788 row with tasks.
expect_restored() {
  local label="$1" P
  P="$(tt788_probe)"
  note "[$label] probe: $P"
  [ "$(tt788_get "$P" prompt)" = "0" ] \
    && note "$label ok: no prompt" \
    || bad "$label the first-task prompt is visible although the row has $(tt788_get "$P" tasks) task(s)"
  [ "$(tt788_get "$P" days)" = "7" ] \
    && note "$label ok: all seven day cells are visible" \
    || bad "$label $(tt788_get "$P" days) of 7 day cells are visible on a row with a task"
  [ "$(tt788_get "$P" total)" = "1" ] \
    && note "$label ok: the row total is visible" \
    || bad "$label the row total is not visible on a row with a task"
  [ "$(tt788_get "$P" chevron)" = "1" ] \
    && note "$label ok: a show/hide chevron is visible" \
    || bad "$label no show/hide chevron is visible on a row with a task — the panel could not be toggled"
}

tt_login "$TT788_CONSULTANT" "My Timesheets"

tt788_find_week empty-editable \
  || tt_fail "no editable week with a task-less '$TT788_PROJECT' row within $TT788_HORIZON weeks for $TT788_CONSULTANT
  $(tt788_census_help)"
note "week $TT788_WEEK"
[ "$(tt788_get "$(tt788_probe)" prompt)" = "1" ] \
  || tt_fail "precondition: the first-task prompt is not showing on the task-less row on week $TT788_WEEK, so its disappearing would prove nothing (verify-tt788-prompt-shown says why)"

# ------------------------------------------------------- add and name one task
tt_task_add "$TT788_PROJECT" >/dev/null || tt_fail "could not add a task to '$TT788_PROJECT' on week $TT788_WEEK"
tt_clear_dialogs 4 >/dev/null 2>&1
tt788_name_task 1 "$TASKNAME" || {
  tt788_delete_task "" >/dev/null 2>&1
  tt_fail "the new task's name did not stick on week $TT788_WEEK (an unnamed task makes the week unsaveable; the spec tried to delete it)"
}

# ---------------------------------------------------------------------- A
expect_restored "A"

# ---------------------------------------------------------------------- B
# Add Task commits the task, and the name commits on change, but Save Draft makes
# "it is on the server" not depend on that: the re-fetch must read a saved task.
tt_assert_no_unnamed_tasks ".mx-name-galAssignmentRows"
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 || bad "B no Save Draft on week $TT788_WEEK"
sleep 3
tt_clear_dialogs 8 || bad "B a dialog blocked the save on week $TT788_WEEK: \"$TT_DIALOG_BLOCKED\""
tt_refetch_week
[ "$(tt_current_week)" = "$TT788_WEEK" ] || tt_fail "the re-fetch left the grid on '$(tt_current_week)', not $TT788_WEEK"
[ "$(tt_task_count "$TT788_PROJECT")" = "1" ] \
  || bad "B after a re-fetch the row has $(tt_task_count "$TT788_PROJECT") task(s), expected the one this spec added — it did not persist"
expect_restored "B"

# ---------------------------------------------------------------------- C
tt_task_panel_open "$TT788_PROJECT" >/dev/null 2>&1
playwright-cli eval "() => { const row=$(_tt_task_row_js "$TT788_PROJECT"); const t=row && row.querySelector('.mx-name-btnLineItemsExpand'); if(!t) return 'none'; t.click(); return 'clicked'; }" >/dev/null 2>&1
for _ in 1 2 3 4 5 6; do
  sleep 1
  [ "$(tt_task_panel_state "$TT788_PROJECT")" = "closed" ] && break
done
if [ "$(tt_task_panel_state "$TT788_PROJECT")" = "closed" ]; then
  note "C the panel is closed (tt-tasks-collapsed)"
  expect_restored "C"
else
  bad "C the panel would not close from its chevron (state: $(tt_task_panel_state "$TT788_PROJECT")) — C not checked"
fi

# ------------------------------------------------------------- D (and cleanup)
tt788_delete_task "$TASKNAME" || bad "D could not delete '$TASKNAME' from week $TT788_WEEK — delete it before re-running"
for _ in 1 2 3 4 5 6; do
  sleep 1
  [ "$(tt788_get "$(tt788_probe)" prompt)" = "1" ] && break
done
P="$(tt788_probe)"
note "[D] probe: $P"
if [ "$(tt788_get "$P" tasks)" = "0" ]; then
  [ "$(tt788_get "$P" prompt)" = "1" ] \
    && note "D ok: with the task deleted, the prompt is back" \
    || bad "D the row has no tasks again but the prompt did not come back"
fi

if [ "$fails" -gt 0 ]; then
  echo "FAIL: verify-tt788-prompt-gone-with-task — $fails check(s) failed on week $TT788_WEEK"
  exit 1
fi
echo "PASS: verify-tt788-prompt-gone-with-task — a task removes the prompt and restores totals and chevron; deleting it brings the prompt back ($TT788_WEEK)"
