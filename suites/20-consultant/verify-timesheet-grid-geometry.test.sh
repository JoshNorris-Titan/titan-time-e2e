#!/usr/bin/env bash
# tt-timeout: 6m
# verify-timesheet-grid-geometry.test.sh
#
# The week table's COLUMN GEOMETRY: that each row fits on one line, and that the
# grids it is built from still line up with each other.
#
# WHY THIS EXISTS. The week table is not one grid but four -- the header in the
# gallery's filter slot, each assignment row, the expanded line-item row, and the
# Daily Totals row -- hand-matched on column weights (first column 3, the rest 1)
# so every day input sits under its own day label. Nothing in the model enforces
# that, and until this script nothing in any test layer observed it either:
#
#   * ped_check_errors sees a valid page either way -- weights are legal numbers.
#   * The unit suite cannot see layout at all; it never renders a page.
#   * check_mirrors.py compares compiled pages and explicitly "never stylesheets"
#     (docs/reference/MIRRORED-REGIONS.md), so a CSS-only break is invisible to it.
#   * This suite had ZERO geometry assertions before this file -- no boundingBox,
#     offsetWidth, clientWidth or getBoundingClientRect anywhere in suites/ or lib/.
#
# So the whole class of defect was unguarded, and two of them shipped in one day
# (2026-09-09), both in the model repo's
# themesource/titan_theme/web/core/widgets/_ConsultantDashboard.scss:
#
#   1. The Docs column, pinned to a fixed 84px, was paid for out of a constant
#      36px freed by lowering the row's real column-gap below the --column-gap
#      that Atlas computes each column's flex-basis from. The pin's cost grows as
#      the row narrows; the 36px does not. Below a row width of ~752px the row
#      overflowed, and Atlas's .row is flex-wrap: wrap, so the tenth column --
#      Docs -- dropped onto its own line under every assignment row. Live for
#      roughly 1150-1400px of viewport and invisible either side of it.
#
#   2. The fix for (1) gave the first column of the three TEN-column grids
#      flex: 1 1 0 so it would absorb the pin at any width. That made it the row's
#      leftover while the NINE-column line-item grid kept col-lg-3's 25%W - 12px,
#      so line-item day cells sat ~9.6px left of the headers they belong under, at
#      exactly the wide widths where (1) never bit. It reached origin/main green.
#
# Assertion B is the one that would have caught (2), and it is the reason this
# script compares TRACK POSITIONS across grids rather than only checking for
# wrapping.
#
# REBUILT ON CSS GRID (model, 2026-09-10..09-27). The four Atlas .row flex grids
# are gone. The week table is now four kinds of named container sharing ONE
# declared track list (.tt-week-row, `--tt-week-cols`: Project, Sun..Sat, Total,
# Docs): cntWeekHeader, cntRowCells (one per assignment row), cntLineItemRow (one
# per task, nine cells on the same ten tracks) and cntWeekTotals. This script used
# to find them as `.widget-gallery-filter > div > .row` / `.tt-totals-row > .row`
# and compare first-column widths; against the rebuilt page it found none of them
# and failed on "no assignment rows rendered". The invariants are unchanged, so it
# now measures them the way a CSS grid expresses them: by TRACK POSITION.
#
# WHAT IT ASSERTS, at each of six desktop widths
#   A. NO ROW WRAPS OR OVERFLOWS. Every grid is display:grid with ten tracks; in
#      each, every cell's left edge is strictly greater than the previous cell's
#      (a cell pushed onto a second grid line breaks that), and the grid's content
#      does not overflow its own box.
#   B. THE GRIDS AGREE. Every grid present resolves its ten tracks to the same
#      absolute left edges as the header, within 1px. This is the invariant that
#      keeps day inputs under day labels - a line-item or totals grid that derived
#      its tracks from a different width would drift here, which is the 2026-09-09
#      defect (2) below in its CSS-grid form.
#   C. NOTHING IS CLIPPED. btnEntryDocs does not overflow itself or the right edge
#      of its own track.
#
# Task rows are measured when the week on screen shows any (visible
# cntLineItemRow), and the count is reported. Zero is reported, not failed:
# whether the week has a task is up to the specs before it. On a full run
# verify-lineitem-rollup-invariant leaves one on e2e_consultant's first open
# 'E2E Line Items' week, which is normally the week this opens on.
#
# RED UNTIL MODEL FIX (2026-09-29). At a 1200px window the Docs track resolves
# to ~63px while btnEntryDocs is 90px wide, so every assignment row's grid
# overflows by 15px and the button runs past its track and under the week card's
# clipped edge (A and C, visible on screen: the "Docs" buttons are cut off at the
# card's right edge). 1024/1280px and above are clean. The fix is the model's
# (_ConsultantDashboard.scss: the Docs track floor, or the button's width).
#
# It deliberately does NOT assert the 84px figure, the gap width or any other
# stylesheet constant. Those are design choices that may legitimately change; a
# wrapped row and a misaligned grid are defects at any value.
#
# WIDTHS, AND WHY IT RESIZES. Both defects above were width-dependent and both
# were invisible at some widths, so a single-viewport check would have missed one
# or the other. 1024 is included because col-xl-7 stops applying there and the row
# gets WIDER, which is why the original bug appeared to come and go.
#
# THIS IS THE ONLY SCRIPT IN THE SUITE THAT RESIZES THE VIEWPORT, and the session
# is shared with every spec that runs after it. It therefore captures the incoming
# size and restores it through a trap, on success, failure and interrupt alike.
# If you add a resize anywhere else, do the same.
#
# Env: the standard TT_BASE_URL / role credentials. No seeding of its own -- it
# needs the assignment rows that 00-setup provisions, and FAILS rather than
# passing vacuously when there are none. Run through run-tests.sh, not directly.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

WIDTHS="1600 1440 1366 1280 1200 1024"
fails=0
bad()  { echo "  BAD  $*"; fails=$((fails + 1)); }
note() { echo "  ok   $*"; }

pwr() { playwright-cli eval "$1" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//'; }

# ------------------------------------------------- restore the shared viewport
ORIG="$(pwr "() => window.innerWidth + 'x' + window.innerHeight")"
case "$ORIG" in
  [0-9]*x[0-9]*) ;;
  *) echo "FAIL: verify-timesheet-grid-geometry - could not read the current viewport (got '$ORIG')."
     exit 1 ;;
esac
restore_viewport() {
  playwright-cli resize "${ORIG%x*}" "${ORIG#*x}" >/dev/null 2>&1 || true
}
trap restore_viewport EXIT INT TERM
echo "  incoming viewport ${ORIG} - will be restored on exit"

tt_login "e2e_consultant" "My Timesheets"

# One probe per width. Returns "OK| [facts]" or "BAD|msg; msg [facts]".
probe() {
  pwr "() => {
    const out = [], facts = [];
    const gal = document.querySelector('.mx-name-galAssignmentRows');
    if (!gal) return 'BAD|no .mx-name-galAssignmentRows on the page';

    const px = v => parseFloat(v) || 0;
    // Absolute left edge of each track of a CSS grid, from its RESOLVED template.
    const tracks = el => {
      const cs = getComputedStyle(el);
      if (cs.display !== 'grid') return null;
      const w = cs.gridTemplateColumns.split(' ').map(px);
      const gap = px(cs.columnGap);
      let x = el.getBoundingClientRect().left + px(cs.borderLeftWidth) + px(cs.paddingLeft);
      return w.map(t => { const l = x; x += t + gap; return [l, t]; });
    };
    const inc = r => {
      const l = [...r.children].map(k => k.getBoundingClientRect().left);
      for (let i = 1; i < l.length; i++) if (l[i] <= l[i - 1]) return false;
      return true;
    };

    const grids = [];
    const hdr = gal.querySelector('.mx-name-cntWeekHeader');
    const tot = document.querySelector('.mx-name-cntWeekTotals');
    const rows = [...gal.querySelectorAll('.mx-name-cntRowCells')];
    const li = [...gal.querySelectorAll('.mx-name-cntLineItemRow')].filter(r => r.offsetParent !== null && r.getBoundingClientRect().width > 0);
    if (!hdr) out.push('header grid not found (.mx-name-cntWeekHeader)');
    if (!tot) out.push('Daily Totals grid not found (.mx-name-cntWeekTotals)');
    if (hdr) grids.push(['header', hdr]);
    rows.forEach((r, i) => grids.push(['row' + (i + 1), r]));
    li.forEach((r, i) => grids.push(['task' + (i + 1), r]));
    if (tot) grids.push(['totals', tot]);
    facts.push('datarows=' + rows.length, 'lineitemrows=' + li.length);

    let ref = null;
    for (const [name, g] of grids) {
      const t = tracks(g);
      if (!t) { out.push(name + ' is not a CSS grid (display ' + getComputedStyle(g).display + ')'); continue; }
      if (t.length !== 10) out.push(name + ' resolves ' + t.length + ' tracks, expected 10');
      if (!inc(g)) out.push(name.toUpperCase() + ' WRAPPED');
      if (g.scrollWidth > g.clientWidth + 1) out.push(name.toUpperCase() + ' OVERFLOWS (' + g.scrollWidth + 'px in ' + g.clientWidth + 'px)');
      if (!ref) { ref = [name, t]; continue; }
      let worst = 0, at = -1;
      t.forEach((tr, i) => { if (ref[1][i]) { const d = Math.abs(tr[0] - ref[1][i][0]); if (d > worst) { worst = d; at = i; } } });
      if (worst > 1) out.push('TRACKS DISAGREE: ' + name + ' track ' + (at + 1) + ' starts ' + Math.round(worst * 10) / 10 + 'px away from the same track on ' + ref[0]);
    }

    rows.forEach((r, i) => {
      const btn = r.querySelector('.mx-name-btnEntryDocs');
      const t = tracks(r);
      if (!btn || !t || t.length < 10) return;
      const b = btn.getBoundingClientRect(), last = t[9];
      if (btn.scrollWidth > btn.clientWidth + 1 || b.right > last[0] + last[1] + 1) {
        out.push('DOCS BUTTON CLIPPED on data row ' + (i + 1) + ' (button ' + btn.scrollWidth + 'px, right edge ' +
                 Math.round(b.right) + ' vs its track ' + Math.round(last[0] + last[1]) + ')');
      }
    });

    if (ref) facts.push('track1=' + Math.round(ref[1][0][1] * 10) / 10);
    return (out.length ? 'BAD|' + out.join('; ') : 'OK|') + ' [' + facts.join(' ') + ']';
  }"
}

saw_rows=0
for w in $WIDTHS; do
  playwright-cli resize "$w" 950 >/dev/null 2>&1
  sleep 1
  r="$(probe)"
  case "$r" in
    OK\|*)  note "${w}px - ${r#OK|}" ;;
    BAD\|*) bad  "${w}px - ${r#BAD|}" ;;
    *)      bad  "${w}px - unreadable probe result: '$r'" ;;
  esac
  case "$r" in
    *datarows=0*) ;;
    *datarows=*)  saw_rows=1 ;;
  esac
done

# A run with no assignment rows exercises only the header and totals grids, so it
# can neither see a wrapped data row nor compare the line-item grid. Reporting
# that as a pass is the blind green this suite has been bitten by before.
if [ "$saw_rows" -eq 0 ]; then
  echo "FAIL: verify-timesheet-grid-geometry - no assignment rows rendered at any width, so"
  echo "      the data-row and line-item assertions never ran. This is a PRECONDITION failure,"
  echo "      not a pass: 00-setup provisions the e2e consultants' projects and assignments."
  echo "      Run the suite through run-tests.sh rather than invoking this script directly."
  exit 1
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-timesheet-grid-geometry - $fails width(s) with a wrapped or misaligned week table."
  exit 1
fi

echo "PASS: verify-timesheet-grid-geometry - no row wraps or overflows and every grid resolves the header's ten tracks at 1600/1440/1366/1280/1200/1024px"
