#!/usr/bin/env bash
# tt-timeout: 6m
# verify-timesheet-no-horizontal-scroll.test.sh
#
# TT-782: the consultant's hours table never scrolls sideways on a laptop or a
# tablet, and the history panel gives way to it instead.
#
# WHY THIS EXISTS. Between ~1200px and ~1260px of window, and again on a tablet,
# the Docs button (92px, it does not shrink) overran the last track of the week
# table, and the gallery's scroll box grew a horizontal scrollbar under the rows
# (Josh's screenshot, main/screenshots/scrollbar.png). The fix (model, 2026-10-05,
# themesource/titan_theme/web/core/widgets/_ConsultantDashboard.scss, "The
# dashboard's two-column split") gave the table a floor and made the history
# panel shrink from 544px to 424px and then WRAP UNDER the table, flush with both
# of its edges, instead of squeezing it.
#
# verify-timesheet-grid-geometry.test.sh already measures the week table's own
# tracks (no wrap, grids agree, Docs not clipped). It does not look at what TT-782
# is about: whether anything SCROLLS, where the history panel goes, and the 834px
# tablet width. This is that half.
#
# WHAT IT ASSERTS, at 1440 / 1366 / 1280 / 1200 / 1024 / 834 (iPad portrait):
#   A. NOTHING SCROLLS SIDEWAYS. No element inside the timesheet column
#      (.mx-name-cntDashMain) that is a scroll box (overflow-x auto/scroll) has
#      more content than room, the column itself does not overflow, and the page
#      does not pan (document scrollWidth <= its clientWidth).
#   B. THE DOCS BUTTON STAYS INSIDE ITS ROW. On every assignment row
#      (.mx-name-cntRowCells), btnEntryDocs' right edge is inside the row's box.
#      That overrun IS the scrollbar, so A and B fail together on the regression;
#      B names the cause.
#   C. THE HISTORY IS EITHER BESIDE OR UNDER, NEVER OVERLAPPING. Either
#      side-by-side (same top, history to the right of the table) or stacked
#      (history entirely below the table, left AND right edges within 1px of the
#      table's, its card flush with the table's card -- the iteration-2 fix for
#      the 16px indent). 1440 and 1366 must be side-by-side; 1200, 1024 and 834
#      must be stacked; 1280 may be either (the drop point is ~1250-1270px and
#      depends on the page scrollbar, so pinning it would test the rasteriser).
#
# WHAT MAKES IT RED. Any reintroduced floor below the Docs button's width, or a
# history panel that squeezes the table instead of wrapping (A/B); the history
# not wrapping at 1200 or below, or wrapping indented (C).
#
# It deliberately does NOT assert 424 / 544 / 748 or any other stylesheet value.
# Those are design choices; a sideways scrollbar and an overlapped panel are
# defects at any value.
#
# VIEWPORT. Like verify-timesheet-grid-geometry, this resizes the shared session's
# viewport, so it captures the incoming size and restores it through a trap on
# success, failure and interrupt alike.
#
# NON-DESTRUCTIVE: it reads the dashboard as it stands and never types or saves.
# It needs the assignment rows 00-setup provisions and FAILS rather than passing
# vacuously when there are none.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

WIDTHS="1440 1366 1280 1200 1024 834"
fails=0
bad()  { echo "  BAD  $*"; fails=$((fails + 1)); }
note() { echo "  ok   $*"; }

pwr() { playwright-cli eval "$1" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//'; }

# ------------------------------------------------- restore the shared viewport
ORIG="$(pwr "() => window.innerWidth + 'x' + window.innerHeight")"
case "$ORIG" in
  [0-9]*x[0-9]*) ;;
  *) echo "FAIL: verify-timesheet-no-horizontal-scroll - could not read the current viewport (got '$ORIG')."
     exit 1 ;;
esac
restore_viewport() {
  # No `|| true`: this spec runs without `set -e`, so a failed restore cannot abort
  # anything, and the verdict is already decided by the time the trap fires.
  playwright-cli resize "${ORIG%x*}" "${ORIG#*x}" >/dev/null 2>&1
}
trap restore_viewport EXIT INT TERM
echo "  incoming viewport ${ORIG} - will be restored on exit"

tt_login "e2e_consultant" "My Timesheets"
tt_wait_for ".mx-name-cntDashMain" "timesheet column (cntDashMain)"
tt_wait_for ".mx-name-cntDashSide" "history column (cntDashSide)"

# One probe per width. Returns "<layout>|OK [facts]" or "<layout>|BAD msg; msg [facts]",
# layout being side, stacked or overlap.
probe() {
  pwr "() => {
    const out = [], facts = [];
    const main = document.querySelector('.mx-name-cntDashMain');
    const side = document.querySelector('.mx-name-cntDashSide');
    if (!main || !side) return 'none|BAD cntDashMain / cntDashSide not on the page';
    const m = main.getBoundingClientRect(), s = side.getBoundingClientRect();

    // A. scroll boxes inside the timesheet column, the column, the page.
    const boxes = [main, ...main.querySelectorAll('*')].filter(el => {
      const ox = getComputedStyle(el).overflowX;
      return ox === 'auto' || ox === 'scroll';
    });
    let scrollers = 0;
    boxes.forEach(el => {
      if (el.scrollWidth > el.clientWidth + 1) {
        scrollers++;
        const n = ([...el.classList].find(c => c.startsWith('mx-name-')) || el.className || el.tagName);
        out.push('SIDEWAYS SCROLL in ' + String(n).slice(0, 60) + ' (' + el.scrollWidth + 'px in ' + el.clientWidth + 'px)');
      }
    });
    if (main.scrollWidth > main.clientWidth + 1) out.push('TIMESHEET COLUMN OVERFLOWS (' + main.scrollWidth + 'px in ' + main.clientWidth + 'px)');
    const doc = document.scrollingElement || document.documentElement;
    if (doc.scrollWidth > doc.clientWidth + 1) out.push('PAGE PANS (' + doc.scrollWidth + 'px in ' + doc.clientWidth + 'px)');
    facts.push('scrollboxes=' + boxes.length);

    // B. Docs button inside its row.
    const rows = [...main.querySelectorAll('.mx-name-cntRowCells')];
    facts.push('datarows=' + rows.length);
    rows.forEach((r, i) => {
      const btn = r.querySelector('.mx-name-btnEntryDocs');
      if (!btn) return;
      const b = btn.getBoundingClientRect(), rr = r.getBoundingClientRect();
      if (b.right > rr.right + 1) out.push('DOCS OVERRUNS row ' + (i + 1) + ' by ' + Math.round(b.right - rr.right) + 'px');
      if (r.scrollWidth > r.clientWidth + 1) out.push('ROW ' + (i + 1) + ' OVERFLOWS (' + r.scrollWidth + 'px in ' + r.clientWidth + 'px)');
    });

    // C. beside or under.
    let layout = 'overlap';
    if (Math.abs(s.top - m.top) <= 2 && s.left >= m.right - 1) layout = 'side';
    else if (s.top >= m.bottom - 1) {
      layout = 'stacked';
      if (Math.abs(s.left - m.left) > 1 || Math.abs(s.right - m.right) > 1)
        out.push('STACKED HISTORY NOT FLUSH: history ' + Math.round(s.left) + '..' + Math.round(s.right) + ' vs table ' + Math.round(m.left) + '..' + Math.round(m.right));
      const mc = main.querySelector('.card'), sc = side.querySelector('.card');
      if (mc && sc) {
        const a = mc.getBoundingClientRect(), c = sc.getBoundingClientRect();
        if (Math.abs(a.left - c.left) > 1) out.push('HISTORY CARD INDENTED ' + Math.round(c.left - a.left) + 'px from the timesheet card');
      }
    } else out.push('HISTORY OVERLAPS THE TABLE (table ' + Math.round(m.left) + ',' + Math.round(m.top) + ' ' + Math.round(m.width) + 'x' + Math.round(m.height) +
                    '; history ' + Math.round(s.left) + ',' + Math.round(s.top) + ' ' + Math.round(s.width) + 'x' + Math.round(s.height) + ')');
    facts.push('table=' + Math.round(m.width) + 'px', 'history=' + Math.round(s.width) + 'px');
    return layout + '|' + (out.length ? 'BAD ' + out.join('; ') : 'OK') + ' [' + facts.join(' ') + ']';
  }"
}

saw_rows=0
for w in $WIDTHS; do
  playwright-cli resize "$w" 950 >/dev/null 2>&1
  sleep 1
  r="$(probe)"
  layout="${r%%|*}"; rest="${r#*|}"
  case "$rest" in
    OK*)  note "${w}px ${layout} - ${rest#OK}" ;;
    BAD*) bad  "${w}px ${layout} - ${rest#BAD }" ;;
    *)    bad  "${w}px - unreadable probe result: '$r'" ;;
  esac
  case "$w:$layout" in
    1440:side|1366:side|1280:side|1280:stacked|1200:stacked|1024:stacked|834:stacked) ;;
    *:overlap|*:none) ;;   # already reported above
    *) bad "${w}px - history is '${layout}', expected $( [ "$w" -ge 1366 ] && echo side-by-side || echo stacked under the table)" ;;
  esac
  case "$r" in
    *datarows=0*) ;;
    *datarows=*)  saw_rows=1 ;;
  esac
done

if [ "$saw_rows" -eq 0 ]; then
  echo "FAIL: verify-timesheet-no-horizontal-scroll - no assignment rows rendered at any width, so"
  echo "      the Docs-overrun assertion never ran. A PRECONDITION failure, not a pass: 00-setup"
  echo "      provisions the e2e consultants' assignments. Run it through run-tests.sh."
  exit 1
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-timesheet-no-horizontal-scroll - $fails problem(s): the hours table scrolls sideways or the history panel does not give way (TT-782)."
  exit 1
fi

echo "PASS: verify-timesheet-no-horizontal-scroll - nothing scrolls sideways and the history sits beside or flush under the table at $WIDTHS px"
