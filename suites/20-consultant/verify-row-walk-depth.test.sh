#!/usr/bin/env bash
# The week grid's assignment row must stay FURTHER than ten DOM levels from any
# ancestor that spans more than one row -- and its project name must stay CLOSER
# than ten.
#
# WHY THIS TEST EXISTS (2026-09-11). Four specs in this folder resolve "which row
# is project X on" with a fixed-depth climb and NO containment guard:
#
#   verify-current-week-warning.test.sh:138
#   verify-hours-validation.test.sh:88
#   verify-timesheet-clear.test.sh:64          (hc_row_any)
#   verify-timesheet-status-rollup.test.sh:88
#
#     for (let n=0; n<rows.length; n++) {          // rows = the Mon day cells
#       let el = rows[n];
#       for (let k=0; k<10; k++) {
#         el = el.parentElement;
#         if (!el) break;
#         if ((el.innerText||'').indexOf(PROJECT) >= 0) return String(n+1);
#       }
#     }
#
# Read what that returns when the climb escapes the row. For n=0 it walks up from
# row 1's Mon cell; if it reaches an ancestor holding SEVERAL rows before it runs
# out of budget, that ancestor's innerText contains every project on screen --
# including PROJECT -- so it returns 1. Row 1. Whatever row PROJECT is actually
# on. The caller then fills, saves, clears or submits the WRONG ROW and every
# assertion downstream is measuring something nobody asked about. There is no
# error, no empty result, nothing to grep for: the specs go green on the wrong
# data. docs/reference/MIRRORED-REGIONS.md in the model repo has named these four
# as "a fixed ten parentElement levels with no containment guard" since the
# 2026-09-09 CSS-grid refactor of the timesheetGrid region.
#
# THE MARGIN IS A SIDE EFFECT OF ATLAS, WHICH IS BEING REMOVED. An Atlas layout
# grid compiled to three stacked divs -- `mx-layoutgrid container-fluid` > `row`
# > `col-*` -- none of which anybody declared. The migration to the tt-* CSS
# primitives (themesource/titan_theme/web/core/layout/_layout.scss) replaces each
# of those with ONE container. Every grid that comes off Main.ConsultantDashboard
# or Main.CreateTimesheet therefore moves the multi-row ancestor two levels
# CLOSER to the day cell, and the ten-level budget is spent that much sooner.
# Those two pages were excluded from the migration through phases 0-6 precisely
# because these walks live on them; the 2026-09-11 wave converted both. It landed
# safely -- the containers it added are above the gallery, not inside the row --
# but nothing in this suite could have told anyone that, which is the gap this
# file closes.
#
# WHAT IT MEASURES, per row, climbing from that row's own `.mx-name-txtDayMon`:
#
#   escape = the first k whose ancestor holds MORE THAN ONE .mx-name-txtDayMon,
#            i.e. the first level at which the climb is no longer looking at one
#            assignment row. The four walks are correct only while escape > 10:
#            every ancestor they inspect must span exactly one row, so a project
#            name found there can only be THAT row's.
#
#   reach  = the first k whose ancestor's innerText contains this row's own
#            project name. The four walks find their row only while reach <= 10.
#            Too deep and they return '0' and report "no editable row for
#            <project>" -- loud, and already covered by their own messages, but
#            measured here so the two bounds are read together.
#
# So the invariant is a CORRIDOR: reach <= 10 < escape. Both ends matter and they
# fail in opposite directions -- one silently wrong, one loudly absent.
#
# TWO ROWS ARE REQUIRED for the escape bound to mean anything. With a single
# assignment row on screen there is no wrong row to return, so `escape` never
# triggers and a pass here would be worth nothing. The spec says so in a NOTE
# rather than passing quietly -- a silent zero here reads exactly like coverage.
# lib/_fixtures.sh builds e2e_consultant more than one assignment, so the normal
# suite ordering supplies them.
#
# WHY THE PROJECT NAME COMES OFF A THEME CLASS. The row's project text is the
# DynamicText auto-named `text11` -- a name this suite forbids selecting on,
# because Studio Pro renumbers it whenever the page is edited. It carries the
# theme class `tt-project-name`, and that is what is used here, exactly as
# verify-history-row-layout.test.sh selects `.tt-history-row-top` for the same
# reason. If the class is gone, `reach` cannot be measured at all, so its absence
# is a failure and not a skip.
#
# THE ROW BOUNDARY IS REPORTED, NOT ASSERTED. The deepest ancestor still spanning
# one row is expected to be the `.widget-gallery-item` every other spec for this
# gallery scopes on. A conversion that inserts a container above the gallery item
# moves that boundary while leaving the corridor intact -- worth seeing, not worth
# a red run, so it prints as a NOTE. The corridor is the claim; the boundary is
# the diagnostic that explains a corridor that moved.
#
# ONE COPY IS MEASURED, AND THAT COVERS BOTH. The week grid is the `timesheetGrid`
# mirrored region: byte-identical copies on Main.ConsultantDashboard and
# Main.CreateTimesheet, kept that way by tools/check_mirrors.py in the model repo
# (and by suites/10-smoke/verify-mirrored-regions.test.sh, which runs that checker
# against the deployed pages). Measuring the dashboard's copy is measuring both.
#
# NON-DESTRUCTIVE and idempotent. It logs in, waits for the grid and reads the
# DOM. It never types, saves, submits, clears or deletes, never steps the week,
# and never touches a filter -- so it consumes no week from the fresh-week pool
# and leaves no state for whatever runs next.

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

# The budget the four specs above spend. Change this ONLY together with them:
# it is not a tolerance to be tuned, it is a quotation of their `k<10`.
WALK_BUDGET=10

# How far to climb before giving up. Well past the budget, so a row that never
# escapes is reported as "never within PROBE_DEPTH" rather than as a pass.
PROBE_DEPTH=24

tt_login "e2e_consultant" "My Timesheets"

tt_wait_for ".mx-name-galAssignmentRows" "consultant week grid (galAssignmentRows)"

# One eval for the whole grid: two would cost ~2.6s of node startup each and could
# straddle a repaint, which would have the rows measured in different layouts.
#
# Record per row, joined with '~~' because _tt_eval_str reads a single line:
#   <row-number>|<escape>|<reach>|<project-text>|<boundary-classes>
# escape or reach of 0 means "not found within PROBE_DEPTH".
REPORT="$(playwright-cli eval "() => {
  const gal = document.querySelector('.mx-name-galAssignmentRows');
  if (!gal) return 'NO-GRID';

  const cells = [...gal.querySelectorAll('.mx-name-txtDayMon')];
  if (!cells.length) return 'NO-ROWS';

  const clean = s => (s || '').replace(/[|~]/g, '/').trim();
  const lines = [];

  for (let n = 0; n < cells.length; n++) {
    // --- escape: first level that stops being one row --------------------
    // 'boundary' trails one level behind, so it ends on the DEEPEST ancestor
    // that still spans exactly this row.
    let el = cells[n], boundary = null, escape = 0;
    for (let k = 1; k <= $PROBE_DEPTH; k++) {
      el = el.parentElement;
      if (!el) break;
      if (el.querySelectorAll('.mx-name-txtDayMon').length > 1) { escape = k; break; }
      boundary = el;
    }

    // --- reach: first level that can see this row's project name ---------
    // Scoped to the row boundary, so a multi-row ancestor cannot lend its
    // neighbour's project name to this measurement.
    const proj = boundary ? boundary.querySelector('.tt-project-name') : null;
    const name = proj ? ((proj.innerText || '').split('\n').find(s => s.trim()) || '').trim() : '';

    let reach = 0;
    if (name) {
      let e2 = cells[n];
      for (let k = 1; k <= $PROBE_DEPTH; k++) {
        e2 = e2.parentElement;
        if (!e2) break;
        if ((e2.innerText || '').indexOf(name) >= 0) { reach = k; break; }
      }
    }

    lines.push([ n + 1, escape, reach, clean(name),
                 boundary ? clean(boundary.className) : '' ].join('|'));
  }
  return lines.join('~~');
}" 2>/dev/null | _tt_eval_str)"

case "$REPORT" in
  NO-GRID)
    tt_fail "consultant week grid missing: no .mx-name-galAssignmentRows on the dashboard" ;;
  NO-ROWS)
    tt_fail "the week grid rendered no assignment rows: .mx-name-galAssignmentRows holds zero .mx-name-txtDayMon, so the walk the four specs perform has nothing to climb from. Run the suite through run-tests.sh so lib/_fixtures.sh builds e2e_consultant's assignments first." ;;
esac

OLD_IFS="$IFS"; IFS='~'
# shellcheck disable=SC2206
PARTS=($REPORT)
IFS="$OLD_IFS"

ROWS=0
WORST_ESCAPE=""
BEST_REACH=""
BOUNDARIES=""
OFF_BOUNDARY=0

for PART in "${PARTS[@]}"; do
  [ -z "$PART" ] && continue

  NUM="${PART%%|*}";    REST="${PART#*|}"
  ESCAPE="${REST%%|*}"; REST="${REST#*|}"
  REACH="${REST%%|*}";  REST="${REST#*|}"
  NAME="${REST%%|*}"
  BCLASS="${REST##*|}"

  ROWS=$((ROWS+1))

  # --- The project name has to be readable, or `reach` measured nothing ----
  if [ -z "$NAME" ]; then
    tt_fail "assignment row $NUM exposes no project name: nothing inside its row boundary carries the theme class 'tt-project-name' (boundary classes: '$BCLASS'). The four fixed-depth walks match on the project name, so with that text unreachable this guard cannot measure how far away it is -- and those walks cannot find their row either. Either the class came off the row's project DynamicText in themesource/titan_theme/web/core/widgets/_ConsultantDashboard.scss, or the widget moved out of the row."
  fi

  # --- Assertion 1: the climb cannot escape the row within budget ---------
  # The silent one. Failing this does not make the four specs red; it makes
  # them green about row 1.
  if [ "$ESCAPE" = "0" ]; then
    : # never escaped within PROBE_DEPTH -- safe, and reported below
  elif [ "$ESCAPE" -le "$WALK_BUDGET" ]; then
    tt_fail "assignment row $NUM ('$NAME') is only $ESCAPE DOM level(s) below an ancestor that spans MORE THAN ONE row, and the four fixed-depth walks in this folder inspect $WALK_BUDGET levels (verify-current-week-warning:138, verify-hours-validation:88, verify-timesheet-clear:64, verify-timesheet-status-rollup:88). Those walks will now match the project name on that shared ancestor and return row 1 for every project on screen, then fill, clear or submit it -- silently, and still reporting PASS. A layout grid was almost certainly taken off Main.ConsultantDashboard / Main.CreateTimesheet inside the assignment row: each Atlas grid removed takes three DOM levels with it. Fix the four walks to climb with a containment guard (the idiom in lib/_tt654.sh:71 stops while the ancestor holds exactly one .mx-name-txtDayMon) rather than widening this budget."
  fi

  # --- Assertion 2: the project name is still within budget ---------------
  # The loud one: the four specs return '0' and say so themselves. Measured
  # here so both ends of the corridor are read in one place.
  if [ "$REACH" = "0" ]; then
    tt_fail "assignment row $NUM ('$NAME') has no ancestor within $PROBE_DEPTH levels whose text contains its own project name, so the four fixed-depth walks cannot resolve it at all and will report '0' / 'no editable row'. The project text is inside the row, so this means the climb from .mx-name-txtDayMon does not pass through whatever now holds it -- the row was restructured sideways rather than flattened."
  elif [ "$REACH" -gt "$WALK_BUDGET" ]; then
    tt_fail "assignment row $NUM ('$NAME') carries its project name $REACH DOM level(s) above the day cell, past the $WALK_BUDGET levels the four fixed-depth walks inspect. They will return '0' and report no row for this project. Something was inserted between the day cells and the row's project text."
  fi

  # Widen the two extremes for the summary line.
  if [ "$ESCAPE" != "0" ]; then
    if [ -z "$WORST_ESCAPE" ] || [ "$ESCAPE" -lt "$WORST_ESCAPE" ]; then WORST_ESCAPE="$ESCAPE"; fi
  fi
  if [ -z "$BEST_REACH" ] || [ "$REACH" -gt "$BEST_REACH" ]; then BEST_REACH="$REACH"; fi

  case "$BCLASS" in
    *widget-gallery-item*) : ;;
    *) OFF_BOUNDARY=$((OFF_BOUNDARY+1))
       case "$BOUNDARIES" in
         *"[$BCLASS]"*) : ;;
         *) BOUNDARIES="$BOUNDARIES[$BCLASS]" ;;
       esac ;;
  esac
done

# --- Assertion 0: there was something to measure ---------------------------
if [ "$ROWS" -eq 0 ]; then
  tt_fail "no assignment rows were parsed out of the week grid -- the report came back as '$REPORT'"
fi

# --- The escape bound needs a second row to mean anything ------------------
if [ "$ROWS" -lt 2 ]; then
  echo "  NOTE: only $ROWS assignment row(s) on screen, so the escape bound proved nothing:"
  echo "        with one row there is no other row for the walk to return by mistake. This"
  echo "        pass is weaker than it looks. lib/_fixtures.sh gives e2e_consultant more than"
  echo "        one assignment, so a run through run-tests.sh should show several."
fi

if [ -z "$WORST_ESCAPE" ]; then
  echo "  NOTE: no row reached a multi-row ancestor within $PROBE_DEPTH levels. That is safe"
  echo "        for the four walks, but it is far deeper than this grid has ever been --"
  echo "        check the gallery really is rendering one item per assignment."
fi

if [ "$OFF_BOUNDARY" -gt 0 ]; then
  echo "  NOTE: $OFF_BOUNDARY row(s) have a one-row boundary that is NOT the .widget-gallery-item"
  echo "        every other spec for this gallery scopes on: ${BOUNDARIES:-none}. The corridor"
  echo "        below still holds, so this is not a failure -- but a container was added or"
  echo "        removed around the row, and the next one may not be free."
fi

echo "PASS: all $ROWS assignment row(s) keep the fixed-depth walk inside the row -- project name reachable within ${BEST_REACH} level(s), multi-row ancestor no closer than ${WORST_ESCAPE:->$PROBE_DEPTH}, against a budget of $WALK_BUDGET"
