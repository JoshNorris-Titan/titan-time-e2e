#!/usr/bin/env bash
# Every row of the consultant's Timesheet History must lay out the same way,
# whether or not it offers the delete icon: the week label on ONE line, and the
# status pill (plus the icon, when present) flush against the row's right edge.
#
# Why this test exists (2026-09-10). The row is a flex line -- .tt-history-row-top
# in themesource/titan_theme/web/core/widgets/_ConsultantDashboard.scss -- holding
# txtHistoryWeek, the tipHistoryStatus tooltip (pushed right with margin-left:auto)
# and imgHistoryDelete. The Image widget ships its own
# `.mx-image-viewer { width: 100% }` in com.mendix.widget.web.Image.mpk, and that
# class lands on the widget's ROOT node, which is the flex item. So the 20px trash
# icon claimed the ENTIRE row: no free space was left, margin-left:auto resolved to
# 0, the pill stopped being right-aligned, and the week label shrank to its
# narrowest width and wrapped mid-phrase ("Sep 13 -" / "Sep 19"). Measured on cloud
# dev before the fix: icon container 329px of a 468px row, week label 40px tall at a
# 20px line-height. After: 20px and 20px.
#
# ONLY DELETABLE ROWS BROKE, which is what made it hard to see and worth a test.
# imgHistoryDelete is visible only when
#   (Status = Draft or empty) and (TotalHours = 0 or empty)
# so every other row in the same list stayed correct and the list just looked
# uneven. verify-history-status-badge.test.sh already covers which rows offer the
# icon and what the pill says; it reads innerText and class names only, so it passes
# with the row laid out either way. This file is the geometry half, and the two
# together are what keep the row honest.
#
# WHY MEASURE THE DOM INSTEAD OF READING THE STYLESHEET. A theme rule can lose to a
# widget's own CSS regardless of what the SCSS says -- the fix here works because
# `.tt-history-row-top > .mx-image-viewer` is (0,2,0) against the widget's (0,1,0),
# and that is a claim about the rendered page, not about the file. getBoundingClientRect
# is the only thing that settles it.
#
# THE THREE ASSERTIONS, and what each one would have caught:
#   1. the week label occupies one line          -- was 2 lines on a deletable row
#   2. the icon container is icon-sized          -- was ~70% of the row
#   3. the pill/icon group is flush right        -- was sitting next to the label
#
# Assertion 2 runs only on rows that HAVE the icon, and assertion 3 only on rows
# that render as a single visual line. Both conditions are properties of the data
# and the viewport, not of the layout: on a freshly seeded database every week is a
# zero-hour draft and therefore deletable, while a list of submitted weeks offers no
# icon at all. If no row qualifies, the spec says so in a NOTE rather than passing
# quietly -- a silent zero here reads exactly like coverage.
#
# WHY ASSERTION 3 IS CONDITIONAL. .tt-history-row-top is `flex-wrap: wrap`, so on a
# viewport too narrow for label + pill + icon the pill drops to a second line by
# design, and "flush right" is then the wrong question. The row is treated as one
# line when its height is within 1.8 line-heights, which no wrapped row satisfies
# (a wrapped row is two full lines plus the row gap).
#
# TOLERANCES. 2px on the right edge, because a fractional layout width rounds
# (measured: icon right 1341.0 vs row content right 1340.67). 40px on the icon
# container, which is 20px of icon plus room for a border or padding somebody adds
# later, and nowhere near the ~329px of the bug. 1.5 line-heights for "one line",
# which is unambiguous against the 2.0 a wrap produces.
#
# ROW SCOPING is `.widget-gallery-item`, the same as the rest of this gallery's
# specs. Do NOT use `.gallery-item` from the itemClass expression -- it is not in
# the rendered DOM. An unscoped querySelector reads row 0 only.
#
# NON-DESTRUCTIVE and idempotent: it pages the list in and measures it. It never
# types, saves, submits, deletes or touches the filters, so it neither consumes a
# week from the fresh-week pool nor leaves state for whatever runs next.

set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_consultant" "My Timesheets"

tt_wait_for ".mx-name-galTimesheetHistory" "consultant timesheet history gallery"

# Page the whole list in first, exactly as the sibling spec does: the gallery is
# "Load more" at pageSize 25, so without this "every row lays out correctly" would
# quietly mean "every row on page one".
LOADED="$(tt_gallery_load_all ".mx-name-galTimesheetHistory" "timesheet history")"

# One eval for the whole list. Two would cost ~2.6s of node startup each and could
# straddle a repaint, which would have the row and its children measured in
# different layouts.
#
# Record per row, joined with '~~' because _tt_eval_str reads a single line:
#   <date>|<lineH>|<weekH>|<rowH>|<rowContentRight>|<pillRight>|<icon?>|<iconW>|<iconRight>
# Every number is rounded to a whole pixel by the shell's comparisons, so they are
# emitted at 2dp and compared as integers after scaling by 100.
REPORT="$(playwright-cli eval "() => {
  const gal = document.querySelector('.mx-name-galTimesheetHistory');
  if (!gal) return 'NO-GALLERY';

  const px = v => Math.round(parseFloat(v) * 100) / 100;
  const lines = [];

  for (const row of gal.querySelectorAll('.widget-gallery-item')) {
    const top  = row.querySelector('.mx-name-cntHistoryRowTop');
    const week = row.querySelector('.mx-name-txtHistoryWeek');
    const pill = row.querySelector('.mx-name-tipHistoryStatus');
    const icon = row.querySelector('.mx-name-imgHistoryDelete');
    const date = week ? (week.innerText || '').trim() : '';

    if (!top || !week || !pill) {
      lines.push([date, 'MISSING', top ? 'top' : 'no-top', week ? 'week' : 'no-week',
                  pill ? 'pill' : 'no-pill', '', '', '', ''].join('|'));
      continue;
    }

    // The container is selected by widget name, per this suite's rule, but every
    // rule in this file keys on the THEME class. If that came off the container,
    // the layout is unstyled and the measurements below would pass or fail for
    // reasons that have nothing to do with the flex row.
    if (!top.classList.contains('tt-history-row-top')) {
      lines.push([date, 'NOCLASS', top.className || '', '', '', '', '', '', ''].join('|'));
      continue;
    }

    // Content-box right edge: the pill can only ever reach padding, not the border.
    const cs   = getComputedStyle(top);
    const tRect = top.getBoundingClientRect();
    const contentRight = tRect.right
      - parseFloat(cs.paddingRight || 0) - parseFloat(cs.borderRightWidth || 0);

    // line-height resolves to 'normal' on some stacks; fall back to the font size.
    const wcs = getComputedStyle(week);
    let lineH = parseFloat(wcs.lineHeight);
    if (!isFinite(lineH)) lineH = parseFloat(wcs.fontSize) * 1.2;

    lines.push([
      date,
      px(lineH),
      px(week.getBoundingClientRect().height),
      px(tRect.height),
      px(contentRight),
      px(pill.getBoundingClientRect().right),
      icon ? 'yes' : 'no',
      icon ? px(icon.getBoundingClientRect().width) : '',
      icon ? px(icon.getBoundingClientRect().right) : ''
    ].join('|'));
  }
  return lines.join('~~');
}" 2>/dev/null | _tt_eval_str)"

if [ "$REPORT" = "NO-GALLERY" ]; then
  tt_fail "timesheet history missing: no .mx-name-galTimesheetHistory on the consultant dashboard"
fi

OLD_IFS="$IFS"; IFS='~'
# shellcheck disable=SC2206
PARTS=($REPORT)
IFS="$OLD_IFS"

ROWS=0
DELETABLE=0
ALIGNED=0

# Integer comparison on hundredths, so no test depends on bash having floats.
scaled() { printf '%.0f' "$(echo "$1" | awk '{printf "%.2f", $1 * 100}')"; }

for PART in "${PARTS[@]}"; do
  [ -z "$PART" ] && continue

  DATE="${PART%%|*}";     REST="${PART#*|}"
  LINEH="${REST%%|*}";    REST="${REST#*|}"
  WEEKH="${REST%%|*}";    REST="${REST#*|}"
  ROWH="${REST%%|*}";     REST="${REST#*|}"
  RRIGHT="${REST%%|*}";   REST="${REST#*|}"
  PRIGHT="${REST%%|*}";   REST="${REST#*|}"
  HASICON="${REST%%|*}";  REST="${REST#*|}"
  ICONW="${REST%%|*}"
  IRIGHT="${REST##*|}"

  ROWS=$((ROWS+1))

  if [ "$LINEH" = "MISSING" ]; then
    tt_fail "timesheet history row '$DATE' is not the expected shape ($WEEKH / $ROWH / $RRIGHT). The row template is cntHistoryRowTop holding txtHistoryWeek and tipHistoryStatus — one of them is absent, so a widget was renamed or removed and every layout rule keyed on it is now dead."
  fi

  if [ "$LINEH" = "NOCLASS" ]; then
    tt_fail "timesheet history row '$DATE' has cntHistoryRowTop WITHOUT its theme class: classes are '$WEEKH', expected to include 'tt-history-row-top'. The row is then an unstyled block — no flex, no right-aligned pill, no icon sizing — and every rule for it in _ConsultantDashboard.scss matches nothing."
  fi

  L=$(scaled "$LINEH")
  # --- Assertion 1: the week label is on ONE line ----------------------------
  # Two lines here is the shape of the bug: the label had been squeezed to its
  # min-content width by a sibling that claimed the whole row.
  LIMIT=$(( L * 15 / 10 ))
  if [ "$(scaled "$WEEKH")" -gt "$LIMIT" ]; then
    tt_fail "timesheet history row '$DATE' wrapped its week label onto more than one line: the label is ${WEEKH}px tall at a ${LINEH}px line-height. Something in .tt-history-row-top is taking the row's width away from it — the delete icon's own widget CSS (.mx-image-viewer { width: 100% }) did exactly this before 2026-09-10."
  fi

  # --- Assertion 2: the icon container is icon-sized -------------------------
  if [ "$HASICON" = "yes" ]; then
    DELETABLE=$((DELETABLE+1))
    if [ "$(scaled "$ICONW")" -gt 4000 ]; then
      tt_fail "timesheet history row '$DATE' has a delete icon whose container is ${ICONW}px wide — it should be about 20px. The Image widget ships .mx-image-viewer { width: 100% } on its root node, so as a flex item it takes the whole row unless the theme sizes it: check that .tt-history-row-top > .mx-image-viewer { flex: 0 0 auto; width: auto } is still in _ConsultantDashboard.scss and still wins over the widget's own rule."
    fi
  fi

  # --- Assertion 3: the pill/icon group is flush right ----------------------
  # Skipped on a wrapped row: .tt-history-row-top is flex-wrap: wrap, so a narrow
  # viewport is MEANT to drop the pill below the label, and "flush right" is then
  # the wrong question rather than a failure.
  ONELINE=$(( L * 18 / 10 ))
  if [ "$(scaled "$ROWH")" -le "$ONELINE" ]; then
    ALIGNED=$((ALIGNED+1))
    if [ "$HASICON" = "yes" ]; then
      EDGE="$IRIGHT"; WHAT="delete icon"
    else
      EDGE="$PRIGHT"; WHAT="status pill"
    fi
    DELTA=$(( $(scaled "$RRIGHT") - $(scaled "$EDGE") ))
    [ "$DELTA" -lt 0 ] && DELTA=$(( -DELTA ))
    if [ "$DELTA" -gt 200 ]; then
      DELTA_PX="$(awk -v d="$DELTA" 'BEGIN{printf "%.2f", d/100}')"
      tt_fail "timesheet history row '$DATE' does not right-align: its $WHAT ends at ${EDGE}px but the row's content box ends at ${RRIGHT}px — a gap of ${DELTA_PX}px. .tt-history-status carries margin-left:auto, which silently resolves to 0 when a sibling has already claimed the row's full width — that is the failure this row had before 2026-09-10, and it is invisible on rows that offer no delete icon."
    fi
  fi
done

# --- Assertion 0: there was something to measure ---------------------------
if [ "$ROWS" -eq 0 ]; then
  tt_fail "timesheet history is empty for e2e_consultant — nothing to measure (tt_gallery_load_all reported ${LOADED:-0} card(s)). Run the suite through run-tests.sh so the seeders run first; if it is still empty, the seed for this account did nothing."
fi

if [ "$DELETABLE" -eq 0 ]; then
  echo "  NOTE: no row offered the delete icon, so the icon-width assertion measured nothing."
  echo "        Expected when every seeded week has hours on it; the bug this file guards"
  echo "        appears ONLY on a zero-hour Draft week, so a run without one is weaker"
  echo "        coverage than it looks. lib/_seed.sh's fresh-week pool is what supplies one."
fi

if [ "$ALIGNED" -eq 0 ]; then
  echo "  NOTE: every row measured as more than one line tall, so the right-alignment"
  echo "        assertion was skipped throughout. At a normal desktop viewport that is"
  echo "        itself suspicious — check the runner's window size before trusting this pass."
fi

echo "PASS: all $ROWS timesheet-history row(s) keep the week label on one line; $DELETABLE row(s) had an icon-sized delete affordance; $ALIGNED single-line row(s) right-aligned their status group"
