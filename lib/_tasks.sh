#!/usr/bin/env bash
# _tasks.sh — the task panel on a task-based ("NeedsLineItems") timesheet row.
#
# Source AFTER lib/_login.sh:
#   source "$TT_ROOT/lib/_login.sh"
#   source "$TT_ROOT/lib/_tasks.sh"
#
# WHY THIS EXISTS (TT-788, 2026-10-20). Five specs, a seeder and lib/_tt654.sh each
# carried their own copy of "expand the tasks section", and every copy decided the
# panel was OPEN from Add Task being in the DOM or having an offsetParent. That was
# true while the panel (cntRowTasks) was conditionally visible on ShowLineItems:
# a closed panel rendered nothing. TT-788 changed the page so that:
#
#   * cntRowTasks is ALWAYS rendered on a task-based row. Open/closed is a dynamic
#     class: closed carries `tt-tasks-collapsed`, and its inner wrapper
#     cntRowTasksBody (`tt-row-tasks-body`) folds to 0 height and goes
#     visibility:hidden after a ~300ms transition (opening springs over ~540ms).
#     galLineItems and btnAddTask live inside that wrapper, so btnAddTask is in the
#     DOM on every EDITABLE task row whether the panel is open or not — and
#     visibility:hidden does not null offsetParent, so neither old test can tell.
#   * while an editable task row has NO tasks, the row shows a prompt instead of its
#     day totals: galFirstTask's empty placeholder cntFirstTaskPrompt, with
#     txtFirstTaskPrompt and btnAddFirstTask ("Add your first task"). The panel is
#     then forced shut by CSS even when ShowLineItems is true (no collapsed class),
#     so btnAddTask is hidden and the only way to add the first task is
#     btnAddFirstTask, which adds one task, opens the panel and focuses that task's
#     empty name input.
#
# THE OPEN TEST, in one place: the row's cntRowTasks exists, does NOT carry
# tt-tasks-collapsed, the row is not showing the first-task prompt, and the
# body's computed visibility is 'visible'. Against a build from BEFORE TT-788
# (no cntRowTasksBody, panel only rendered when open) the same test still answers
# correctly: a rendered cntRowTasks with no collapsed class is open, an absent one
# is closed.
#
# ROW SCOPE. Every helper takes an optional project substring and works on that
# row only (.mx-name-cntAssignmentRow whose cntRowCells mention it). With no
# project it takes the first task-based row on the week. Clicks are JS clicks on
# the row's own button: btnAddTask now exists on every editable task row, so an
# unscoped `playwright-cli click .mx-name-btnAddTask` can hit a strict-mode
# violation or a hidden button.
#
# Selectors: .mx-name-* only, plus the panel's own Appearance class
# `tt-tasks-collapsed`, which is the model's state flag and nothing else exposes it.

# _tt_task_row_js <project> — a JS expression evaluating to that row element or null.
_tt_task_row_js() {
  printf '%s' "(() => { const P='$1'; const rows=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-cntAssignmentRow')].filter(r => r.querySelector('.mx-name-cntRowTasks, .mx-name-btnLineItemsExpand, .mx-name-btnLineItemsCollapse, .mx-name-galFirstTask')); if (!P) return rows[0] || null; return rows.find(r => (((r.querySelector('.mx-name-cntRowCells') || r).innerText) || '').indexOf(P) >= 0) || null; })()"
}

# _tt_task_state_js — JS statements, given `row`, that return the panel state.
_tt_task_state_js() {
  printf '%s' "if (!row) return 'none'; const prm=row.querySelector('.mx-name-cntFirstTaskPrompt'); if (prm && prm.offsetParent !== null) return 'prompt'; const p=row.querySelector('.mx-name-cntRowTasks'); if (!p) return 'closed'; if (p.classList.contains('tt-tasks-collapsed')) return 'closed'; const b=p.querySelector('.mx-name-cntRowTasksBody'); if (b && getComputedStyle(b).visibility !== 'visible') return 'closed'; return 'open';"
}

# tt_task_panel_state [project] — echoes one of:
#   none    no task-based row for that project on the week shown
#   prompt  the "Add your first task" prompt is showing (no tasks, editable week)
#   open    the panel is open and its contents are visible
#   closed  the panel is collapsed (or, before TT-788, not rendered)
tt_task_panel_state() {
  playwright-cli eval "() => { const row=$(_tt_task_row_js "${1:-}"); $(_tt_task_state_js) }" 2>/dev/null | _tt_eval_str
}

# tt_task_count [project] — how many tasks that row holds, open or closed.
# Counts the name inputs inside the row's own galLineItems. Since TT-788 the
# gallery is rendered while the panel is collapsed, so this no longer depends on
# the panel being open (before TT-788 a closed panel reads 0).
tt_task_count() {
  playwright-cli eval "() => { const row=$(_tt_task_row_js "${1:-}"); if (!row) return ''; return String(row.querySelectorAll('.mx-name-galLineItems .mx-name-txtLineItemName input').length); }" 2>/dev/null | _tt_eval_str
}

# tt_task_prompt_shown [project] — 'true' when the first-task prompt is visible.
tt_task_prompt_shown() {
  [ "$(tt_task_panel_state "${1:-}")" = "prompt" ] && echo true || echo false
}

# _tt_task_wait_state <project> <want> [tries] — poll until the state is <want>.
_tt_task_wait_state() {
  local proj="$1" want="$2" tries="${3:-10}" i s=""
  for i in $(seq 1 "$tries"); do
    s="$(tt_task_panel_state "$proj")"
    [ "$s" = "$want" ] && return 0
    sleep 1
  done
  return 1
}

# tt_task_panel_open [project] — open the row's task panel and wait for it.
# Returns 0 when open (after the open transition has had time to settle),
#         2 when the row is showing the first-task prompt — there are no tasks and
#           btnAddTask is hidden; use tt_task_add, which presses btnAddFirstTask,
#         1 when there is no such row or it would not open.
tt_task_panel_open() {
  local proj="${1:-}" i s
  for i in 1 2 3; do
    s="$(tt_task_panel_state "$proj")"
    case "$s" in
      open)   sleep 1; return 0 ;;
      prompt) return 2 ;;
      none|'') return 1 ;;
    esac
    # Closed: press whichever chevron the row renders. Only one is ever rendered
    # (btnLineItemsCollapse = "Show tasks" while ShowLineItems is false).
    playwright-cli eval "() => { const row=$(_tt_task_row_js "$proj"); if (!row) return 'nf'; const t=row.querySelector('.mx-name-btnLineItemsCollapse') || row.querySelector('.mx-name-btnLineItemsExpand'); if (!t) return 'notoggle'; t.click(); return 'toggled'; }" >/dev/null 2>&1
    _tt_task_wait_state "$proj" open 6 && { sleep 1; return 0; }
  done
  return 1
}

# tt_task_add [project] — add ONE task to the row, whatever state it is in.
#   prompt  -> presses btnAddFirstTask (which opens the panel itself)
#   closed  -> opens the panel, then presses btnAddTask
#   open    -> presses btnAddTask
# Waits for the row's task count to grow and the panel to be open. Returns 0 on
# success and echoes the row's new task count; returns 1 with a reason on stderr.
# The new task is committed with an EMPTY name — name it straight away and read
# it back (tt_assert_task_named), or the whole week becomes unsaveable.
tt_task_add() {
  local proj="${1:-}" s n0 n i btn
  s="$(tt_task_panel_state "$proj")"
  case "$s" in
    none|'') echo "tt_task_add: no task-based row${proj:+ for '$proj'} on this week" >&2; return 1 ;;
    prompt)  btn="btnAddFirstTask" ;;
    *)
      tt_task_panel_open "$proj" || { echo "tt_task_add: the task panel${proj:+ for '$proj'} would not open (state: $(tt_task_panel_state "$proj"))" >&2; return 1; }
      btn="btnAddTask" ;;
  esac
  n0="$(tt_task_count "$proj")"
  case "$n0" in ''|*[!0-9]*) n0=0 ;; esac
  playwright-cli eval "() => { const row=$(_tt_task_row_js "$proj"); if (!row) return 'nf'; const b=row.querySelector('.mx-name-$btn'); if (!b) return 'nobtn'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str | grep -qx clicked \
    || { echo "tt_task_add: no $btn on the${proj:+ '$proj'} row (state was '$s') — is the week still editable?" >&2; return 1; }
  for i in $(seq 1 12); do
    sleep 1
    n="$(tt_task_count "$proj")"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$n0" ] && break
  done
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt "$n0" ] || { echo "tt_task_add: $btn did not add a task (before=$n0, after=$n)" >&2; return 1; }
  _tt_task_wait_state "$proj" open 8 || { echo "tt_task_add: a task was added but the panel is not open (state: $(tt_task_panel_state "$proj"))" >&2; return 1; }
  sleep 1   # let the open spring (~540ms) and the new line's entrance finish
  echo "$n"
}
