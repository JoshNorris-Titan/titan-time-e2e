#!/usr/bin/env bash
# "Which row is project X on?" must answer X's row -- on a week grid with several
# rows, for every row.
#
# WHY THIS TEST EXISTS (2026-09-12). Several specs find their assignment row in the
# consultant week grid by climbing from each row's Mon day cell until an ancestor's
# text holds the project name. Four of them did it WITHOUT stopping at the row:
#
#   verify-current-week-warning, verify-hours-validation,
#   verify-timesheet-clear (hc_row_any), verify-timesheet-status-rollup
#
#     for (let k=0; k<10; k++) {
#       el = el.parentElement;
#       if ((el.innerText||'').indexOf(PROJECT) >= 0) return String(n+1);
#     }
#
# Measured on dev on 2026-09-12, a Mon cell sits only FOUR levels below the list
# that holds every row:
#
#   .mx-name-txtDayMon > cntRowCells > cntAssignmentRow > .widget-gallery-item
#                                                       > .widget-gallery-items
#
# -- the shape the 2026-09-09 CSS-grid refactor of the timesheetGrid region left.
# So from row 1 the climb reaches the whole list by k=4, finds PROJECT there on
# whichever row it really is, and returns 1. Always 1. The caller then fills,
# clears or submits row 1. Those four specs stayed right only because they log in
# as e2e_consultant2, whose ONE assignment is E2E Sandbox: with a single row, row 1
# is the only possible answer. Give that consultant a second assignment and all
# four would have gone on passing about the wrong row.
#
# They now call tt_week_row_of (lib/_login.sh), which stops climbing the moment an
# ancestor holds more than one .mx-name-txtDayMon -- the containment the lib's own
# row helpers (tt_consultant_submit_project_row, lib/_seed.sh, lib/_tt654.sh)
# already had. THIS SPEC IS WHAT HOLDS THAT HELPER TO THE RIGHT ANSWER.
#
# HISTORY. This file began as verify-row-walk-depth (e2e #91), which asserted that
# the multi-row ancestor stayed MORE than ten levels away, on the theory that the
# Atlas-grid migration was eating into a margin. Its first live run (34656051868)
# measured four -- there had been no margin since 2026-09-09, and nothing on the
# day it was written had changed that. Guarding a budget was the wrong fix for an
# unguarded walk; containing the walk is the right one, and what matters then is
# not how deep anything is but whether each project resolves to its own row.
#
# WHAT IT ASSERTS, on e2e_consultant (four assignments, so four rows):
#   1. every row exposes its project name (theme class tt-project-name -- the
#      DynamicText itself is auto-named text11, which this suite may not select on)
#   2. tt_week_row_of "<that name>" returns THAT row, for every row
# and it prints, per row, what the old unguarded walk would have answered, so a
# reader can see the hazard the helper exists for rather than take it on trust.
#
# TWO ROWS ARE REQUIRED for assertion 2 to mean anything: with one row, every walk
# answers 1 and is right. Fewer than two is reported in a NOTE, not passed quietly.
#
# NON-DESTRUCTIVE and idempotent. It logs in and reads the grid. It never types,
# saves, submits, clears or deletes, never steps the week and never touches a
# filter.

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CUSER="${TT_ROWRES_USER:-e2e_consultant}"

tt_login "$CUSER" "My Timesheets"
tt_wait_for ".mx-name-galAssignmentRows" "consultant week grid (galAssignmentRows)"

# One eval reads every row's own project name and what the OLD unguarded walk
# answers for it. Record per row, '~~'-joined because _tt_eval_str reads one line:
#   <row-number>|<project-name>|<old-walk-answer>
REPORT="$(playwright-cli eval "() => {
  const gal = document.querySelector('.mx-name-galAssignmentRows');
  if (!gal) return 'NO-GRID';
  const cells = [...gal.querySelectorAll('.mx-name-txtDayMon')];
  if (!cells.length) return 'NO-ROWS';
  const clean = s => (s || '').replace(/[|~]/g, '/').trim();
  const oldWalk = proj => {
    for (let n = 0; n < cells.length; n++) {
      let el = cells[n];
      for (let k = 0; k < 10; k++) {
        el = el.parentElement;
        if (!el) break;
        if ((el.innerText || '').indexOf(proj) >= 0) return n + 1;
      }
    }
    return 0;
  };
  const lines = [];
  for (let n = 0; n < cells.length; n++) {
    // The row: the deepest ancestor that still holds exactly this one Mon cell.
    let el = cells[n], row = null;
    for (let k = 0; k < 24; k++) {
      el = el.parentElement;
      if (!el || el.querySelectorAll('.mx-name-txtDayMon').length !== 1) break;
      row = el;
    }
    const p = row ? row.querySelector('.tt-project-name') : null;
    const name = p ? ((p.innerText || '').split('\n').find(s => s.trim()) || '').trim() : '';
    lines.push([n + 1, clean(name), name ? oldWalk(name) : 0].join('|'));
  }
  return lines.join('~~');
}" 2>/dev/null | _tt_eval_str)"

case "$REPORT" in
  NO-GRID) tt_fail "consultant week grid missing: no .mx-name-galAssignmentRows on the dashboard for '$CUSER'" ;;
  NO-ROWS) tt_fail "the week grid for '$CUSER' rendered no assignment rows (no .mx-name-txtDayMon). Run through run-tests.sh so suites/00-setup builds the fixtures first." ;;
  '')      tt_fail "could not read the week grid at all (empty eval result)" ;;
esac

OLD_IFS="$IFS"; IFS='~'
# shellcheck disable=SC2206
PARTS=($REPORT)
IFS="$OLD_IFS"

ROWS=0
OLD_WRONG=0
SEEN=""

for PART in "${PARTS[@]}"; do
  [ -z "$PART" ] && continue
  NUM="${PART%%|*}"; REST="${PART#*|}"
  NAME="${REST%%|*}"
  OLD="${REST##*|}"
  ROWS=$((ROWS+1))

  # --- Assertion 1: the row names its project --------------------------------
  [ -n "$NAME" ] || tt_fail "week-grid row $NUM exposes no project name: nothing inside the row carries the theme class 'tt-project-name'. Every row walk matches on the project name, so without it no spec can find this row. Check the row's project DynamicText in Main.ConsultantDashboard / Main.CreateTimesheet (the timesheetGrid mirrored region)."

  # A project listed twice would make "its row" ambiguous; resolve each name once.
  case "$SEEN" in *"[$NAME]"*) echo "  NOTE: '$NAME' appears on more than one row; checked on its first only."; continue ;; esac
  SEEN="$SEEN[$NAME]"

  # --- Assertion 2: the shared helper returns THIS row ------------------------
  GOT="$(tt_week_row_of "$NAME")"
  if [ "$GOT" != "$NUM" ]; then
    tt_fail "tt_week_row_of '$NAME' answered row '${GOT:-?}', but '$NAME' is on row $NUM of $CUSER's week grid. Every spec that calls it (verify-current-week-warning, verify-hours-validation, verify-timesheet-clear, verify-timesheet-status-rollup) would then act on the wrong row. The helper's climb must stop at the first ancestor holding more than one .mx-name-txtDayMon."
  fi

  if [ "$OLD" != "$NUM" ]; then OLD_WRONG=$((OLD_WRONG+1)); fi
  echo "  row $NUM '$NAME': tt_week_row_of -> $GOT; the old unguarded walk would have said $OLD"
done

if [ "$ROWS" -lt 2 ]; then
  echo "  NOTE: only $ROWS row(s) on '$CUSER's grid, so a wrong-row answer was impossible and this"
  echo "        pass proves little. lib/_fixtures.sh gives e2e_consultant four assignments; a run"
  echo "        through run-tests.sh should show four rows."
fi

echo "PASS: all $ROWS week-grid row(s) resolve to their own project through tt_week_row_of (the old unguarded walk got $OLD_WRONG of them wrong)"
