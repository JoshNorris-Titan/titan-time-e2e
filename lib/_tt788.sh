#!/usr/bin/env bash
# TT-788 helpers — the "Add your first task" prompt on a task-based timesheet row.
# Source AFTER lib/_login.sh:
#   source "$TT_ROOT/lib/_login.sh"
#   source "$TT_ROOT/lib/_tt788.sh"
#
# WHAT TT-788 CHANGED (Main.ConsultantDashboard and its mirrored copy
# Main.CreateTimesheet, same widget names on both). On a task-based row
# (NeedsLineItems) of an EDITABLE week that has NO tasks, the row shows a prompt
# instead of its day totals: galFirstTask's empty placeholder cntFirstTaskPrompt,
# holding txtFirstTaskPrompt ("Hours for this project are logged by task.") and
# btnAddFirstTask ("Add your first task" — shortened visually at narrow widths by
# CSS, but the text stays in the DOM). The task panel is forced shut while the
# prompt shows, so btnAddTask is hidden. btnAddFirstTask adds one task, opens the
# panel and focuses that task's empty name. Once a task exists the row is what it
# was before TT-788: day totals, row total and the show/hide chevron. A submitted,
# approved or exported week never shows the prompt. The panel/lib mechanics are
# in lib/_tasks.sh, which this sources.
#
# FINDING THE STATE WITHOUT ASSUMING IT. The specs pick their week from DATA the
# prompt does not control — the row is editable (btnAddTask, whose own rule is
# _IsEditable, is in the DOM), the week still has Save Draft, and the row's own
# galLineItems holds no task — and only then look at the prompt. Picking the
# week by "the prompt is showing" would make the prompt assertion circular.
#
# DATA. 'E2E Line Items' is the only NeedsLineItems fixture (lib/_fixtures.sh)
# and only E2E Consultant is assigned to it, from verify-001-fixtures. Every week
# of that assignment starts with no tasks; the specs that add tasks earlier in the
# run delete theirs (verify-consultant-line-items, -clear-keeps-tasks, tt692693-b1)
# or leave one on the first open week (verify-lineitem-rollup-invariant, tt654
# a0/a3), so a task-less editable week is normally a few clicks ahead.
#
# Env:
#   TT788_CONSULTANT  default e2e_consultant
#   TT788_PROJECT     default "E2E Line Items"
#   TT788_HORIZON     default 30 weeks walked forward (see TT654_WEEK_HORIZON: the
#                     suite submits ~20 of this consultant's weeks before 70-tickets)

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_tasks.sh"

TT788_CONSULTANT="${TT788_CONSULTANT:-e2e_consultant}"
TT788_PROJECT="${TT788_PROJECT:-E2E Line Items}"
TT788_HORIZON="${TT788_HORIZON:-30}"
TT788_PROMPT_TEXT="Hours for this project are logged by task."
TT788_BUTTON_TEXT="Add your first task"

# Set by tt788_find_week.
TT788_WEEK=""

# tt788_probe — the row's TT-788 facts as "key=value;key=value". Keys:
#   row        1 when the project's task row is on the week
#   week_edit  1 when the week still offers Save Draft
#   editable   1 when the row's btnAddTask is in the DOM (its rule is _IsEditable)
#   gal        1 when the row's galLineItems is rendered (always, since TT-788)
#   tasks      task count in the row's galLineItems
#   prompt     1 when cntFirstTaskPrompt is VISIBLE (see vis below)
#   prompt_dom 1 when cntFirstTaskPrompt is in the DOM at all
#   ptext      txtFirstTaskPrompt's text
#   addfirst   1 when btnAddFirstTask is visible;  addfirst_txt its textContent
#   addtask    1 when btnAddTask is visible
#   days       how many of the row's seven day cells are visible (0..7)
#   total      1 when the row total is visible
#   chevron    1 when a show/hide chevron is visible
#   collapsed  1 when cntRowTasks carries tt-tasks-collapsed
#   state      tt_task_panel_state's answer (none/prompt/open/closed)
#   focus      1-based ordinal of the focused task-name input in the row, 0 if none
#   focus_val  that input's value
#   ctl_days   visible day cells on the FIRST OTHER row of the week — the control
#              that proves `vis` can say "visible" at all, so a 0 above is not vacuous
# vis = offsetParent set, computed visibility 'visible', and a non-zero box: a
# hidden chevron is visibility:hidden AND 0 high, a collapsed panel's contents are
# visibility:hidden with an offsetParent, the prompt-hidden day cells are display:none.
tt788_probe() {
  playwright-cli eval "() => {
    const row = $(_tt_task_row_js "$TT788_PROJECT");
    const vis = el => { if (!el || el.offsetParent === null) return false; if (getComputedStyle(el).visibility !== 'visible') return false; const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const o = { row: row ? 1 : 0, week_edit: document.querySelector('.mx-name-btnSaveDraft') ? 1 : 0 };
    const rows = [...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-cntAssignmentRow')];
    const other = rows.find(r => r !== row);
    o.ctl_days = other ? [...other.querySelectorAll('.mx-name-cntRowCells [class*=mx-name-txtDay]')].filter(vis).length : -1;
    if (row) {
      const q = s => row.querySelector('.mx-name-' + s);
      const names = [...row.querySelectorAll('.mx-name-galLineItems .mx-name-txtLineItemName input')];
      const pr = q('cntFirstTaskPrompt'), af = q('btnAddFirstTask'), pt = q('txtFirstTaskPrompt'), pnl = q('cntRowTasks');
      o.editable = q('btnAddTask') ? 1 : 0;
      o.gal = q('galLineItems') ? 1 : 0;
      o.tasks = names.length;
      o.prompt = vis(pr) ? 1 : 0;
      o.prompt_dom = pr ? 1 : 0;
      o.ptext = pt ? (pt.textContent || '').replace(/\\s+/g, ' ').trim() : '';
      o.addfirst = vis(af) ? 1 : 0;
      o.addfirst_txt = af ? (af.textContent || '').replace(/\\s+/g, ' ').trim() : '';
      o.addtask = vis(q('btnAddTask')) ? 1 : 0;
      o.days = [...row.querySelectorAll('.mx-name-cntRowCells [class*=mx-name-txtDay]')].filter(vis).length;
      o.total = vis(row.querySelector('.mx-name-cntRowCells [class*=mx-name-txtRowTotal]')) ? 1 : 0;
      o.chevron = (vis(q('btnLineItemsExpand')) || vis(q('btnLineItemsCollapse'))) ? 1 : 0;
      o.collapsed = pnl && pnl.classList.contains('tt-tasks-collapsed') ? 1 : 0;
      const fi = names.indexOf(document.activeElement);
      o.focus = fi + 1;
      o.focus_val = fi >= 0 ? (names[fi].value || '') : '';
      o.state = (() => { $(_tt_task_state_js) })();
    }
    return Object.entries(o).map(([k, v]) => k + '=' + String(v).replace(/[;=]/g, ' ')).join(';');
  }" 2>/dev/null | _tt_eval_str
}

# tt788_get <probe> <key> — one value out of a tt788_probe result.
tt788_get() {
  printf '%s\n' "$1" | tr ';' '\n' | awk -F'=' -v k="$2" '$1==k { sub(/^[^=]*=/, ""); print; exit }'
}

# tt788_find_week <mode> — step FORWARD from the week on screen until the
# project's row matches <mode>; sets TT788_WEEK. Returns 1 (and prints a census,
# one character per week) when none is found within TT788_HORIZON weeks.
#   empty-editable    the week has Save Draft, the row is editable, no tasks
#   submitted-empty   the week has neither Save Draft nor Submit, the row is not
#                     editable, no tasks
# Census: '-' no row  'g' row but its task gallery is not rendered (a build from
# before TT-788, or still loading)  't' row has tasks  'e' editable when we want a
# submitted week  's' not editable / week closed when we want an editable one.
TT788_CENSUS=""
tt788_find_week() {
  local mode="$1" i p row gal tasks wk ed sub tries
  TT788_CENSUS=""; TT788_WEEK=""
  for i in $(seq 1 "$TT788_HORIZON"); do
    # The row's galleries load after the grid; give a week a few looks.
    for tries in 1 2 3; do
      p="$(tt788_probe)"
      row="$(tt788_get "$p" row)"; gal="$(tt788_get "$p" gal)"
      [ "$row" = "1" ] && [ "$gal" = "1" ] && break
      [ "$row" = "1" ] || break
      sleep 1
    done
    tasks="$(tt788_get "$p" tasks)"; wk="$(tt788_get "$p" week_edit)"; ed="$(tt788_get "$p" editable)"
    if [ "$row" != "1" ]; then TT788_CENSUS="${TT788_CENSUS}-"
    elif [ "$gal" != "1" ]; then TT788_CENSUS="${TT788_CENSUS}g"
    elif [ "$tasks" != "0" ]; then TT788_CENSUS="${TT788_CENSUS}t"
    else
      case "$mode" in
        empty-editable)
          if [ "$wk" = "1" ] && [ "$ed" = "1" ]; then TT788_WEEK="$(tt_current_week)"; return 0; fi
          TT788_CENSUS="${TT788_CENSUS}s" ;;
        submitted-empty)
          sub="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | _tt_eval_str)"
          if [ "$wk" = "0" ] && [ "$sub" = "false" ] && [ "$ed" = "0" ]; then TT788_WEEK="$(tt_current_week)"; return 0; fi
          TT788_CENSUS="${TT788_CENSUS}e" ;;
      esac
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  return 1
}

# tt788_census_help — the legend for a failure message.
tt788_census_help() {
  echo "one character per week walked: $TT788_CENSUS
  ('-' no '$TT788_PROJECT' row; 'g' row but no galLineItems rendered - on every week that means TT-788 is not deployed;
   't' the row already has tasks; 's' week closed or row not editable; 'e' week still editable)"
}

# tt788_delete_task <name> — delete the row's task(s) whose name is exactly <name>
# ('' targets UNNAMED tasks, the debris an interrupted add leaves behind, which
# makes the whole week unsaveable). Opens the panel first; walks any confirm
# dialog. Returns 0 when none is left.
tt788_delete_task() {
  local name="$1" i r
  for i in 1 2 3 4 5 6; do
    tt_task_panel_open "$TT788_PROJECT" >/dev/null 2>&1
    r="$(playwright-cli eval "() => { const row=$(_tt_task_row_js "$TT788_PROJECT"); if(!row) return 'norow'; const hit=[...row.querySelectorAll('.mx-name-galLineItems .mx-name-txtLineItemName input')].find(e => (e.value||'').trim() === '$name'); if(!hit) return 'gone'; const item=hit.closest('.widget-gallery-item'); const del=item ? item.querySelector('.mx-name-btnLineItemDelete') : null; if(!del) return 'nodel'; del.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str)"
    case "$r" in
      gone) return 0 ;;
      norow|nodel) return 1 ;;
    esac
    sleep 2
    tt_clear_dialogs 6 >/dev/null 2>&1 || true
  done
  [ "$(playwright-cli eval "() => { const row=$(_tt_task_row_js "$TT788_PROJECT"); if(!row) return 'x'; return String([...row.querySelectorAll('.mx-name-galLineItems .mx-name-txtLineItemName input')].some(e => (e.value||'').trim() === '$name')); }" 2>/dev/null | _tt_eval_str)" = "false" ]
}

# tt788_name_task <ordinal> <name> — type <name> into the row's Nth task name and
# blur it (a Mendix input commits on blur), then read it back. Returns 1 if it did
# not stick.
tt788_name_task() {
  local ord="$1" name="$2" got
  playwright-cli fill ":nth-match(.mx-name-galAssignmentRows .mx-name-txtLineItemName input, $ord)" "$name" >/dev/null 2>&1
  playwright-cli press "Tab" >/dev/null 2>&1
  sleep 2
  tt_clear_dialogs 4 >/dev/null 2>&1 || true
  got="$(playwright-cli eval "() => { const row=$(_tt_task_row_js "$TT788_PROJECT"); const els=row ? row.querySelectorAll('.mx-name-galLineItems .mx-name-txtLineItemName input') : []; const el=els[$ord-1]; return el ? (el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str)"
  [ "$got" = "$name" ]
}
