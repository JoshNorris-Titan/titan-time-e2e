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
# script measures FIRST-COLUMN WIDTHS rather than only checking for wrapping.
#
# WHAT IT ASSERTS, at each of six desktop widths
#   A. NO ROW WRAPS. For the header grid, every assignment row and the Daily
#      Totals grid, each column's left edge is strictly greater than the previous
#      column's. Strictly-increasing left is the correct test; comparing top
#      offsets gives a FALSE POSITIVE on the totals row, whose align-items: center
#      legitimately puts its columns at different tops.
#   B. THE GRIDS AGREE. Every grid present reports the same first-column width,
#      within 1px. This is the invariant that keeps day inputs under day labels.
#   C. NOTHING IS CLIPPED. btnEntryDocs does not overflow its own column, which is
#      the regression the 84px pin was added to fix in the first place.
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

    const inc = r => {
      const l = [...r.children].map(k => k.getBoundingClientRect().left);
      for (let i = 1; i < l.length; i++) if (l[i] <= l[i - 1]) return false;
      return true;
    };
    const w1 = r => r.children[0].getBoundingClientRect().width;
    const firsts = [];

    const hdr = gal.querySelector(':scope > .widget-gallery-filter > div > .row');
    const tot = document.querySelector('.tt-totals-row > .row');
    if (!hdr) out.push('header grid not found (.widget-gallery-filter > div > .row)');
    if (!tot) out.push('Daily Totals grid not found (.tt-totals-row > .row)');

    if (hdr) {
      if (hdr.children.length !== 10) out.push('header grid has ' + hdr.children.length + ' columns, expected 10');
      if (!inc(hdr)) out.push('HEADER ROW WRAPPED');
      firsts.push(['header', w1(hdr)]);
    }
    if (tot) {
      if (!inc(tot)) out.push('TOTALS ROW WRAPPED');
      firsts.push(['totals', w1(tot)]);
    }

    const all = [...gal.querySelectorAll('.widget-gallery-item > div > .row')];
    const rows = all.filter(r => r.children.length === 10);
    const li = all.filter(r => r.children.length === 9);
    facts.push('datarows=' + rows.length, 'lineitemrows=' + li.length);

    rows.forEach((r, i) => {
      if (!inc(r)) out.push('DATA ROW ' + (i + 1) + ' WRAPPED');
      if (i === 0) firsts.push(['datarow', w1(r)]);
      const col = r.children[9];
      const btn = col && col.querySelector('.mx-name-btnEntryDocs');
      if (btn && btn.scrollWidth > col.clientWidth + 1) {
        out.push('DOCS BUTTON CLIPPED on data row ' + (i + 1) +
                 ' (button ' + btn.scrollWidth + 'px in a ' + col.clientWidth + 'px column)');
      }
    });
    if (li.length) firsts.push(['lineitem', w1(li[0])]);

    if (firsts.length > 1) {
      const ws = firsts.map(f => f[1]);
      if (Math.max(...ws) - Math.min(...ws) > 1) {
        out.push('FIRST COLUMN WIDTHS DISAGREE: ' +
                 firsts.map(f => f[0] + '=' + Math.round(f[1] * 10) / 10 + 'px').join(' '));
      }
    }
    facts.push('first=' + firsts.map(f => f[0] + ':' + Math.round(f[1] * 10) / 10).join(','));
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

echo "PASS: verify-timesheet-grid-geometry - no row wraps and all grids share a first-column width at 1600/1440/1366/1280/1200/1024px"
