#!/usr/bin/env bash
# HR's Weekly to process tab groups its queue by week correctly, opens on the newest
# week, lets a week be folded and unfolded, and its consultant filter actually
# narrows the queue - and clearing it restores what was there.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. This is the screen HR works a week's timesheets from, and every
# control on it decides WHICH rows the next Process or Reject lands on. A week group
# that shows another week's rows, a count that disagrees with the rows under it, or a
# filter that silently does nothing all end the same way: the wrong person's week is
# processed or sent back, and the right one is still waiting.
#
# REDESIGNED 2026-09-28, BECAUSE THE WEEK FILTER IT RELIED ON WAS REMOVED. Model
# b2202878 / 771be886 rebuilt To Process: the week picker (galProcessAvailableWeeks)
# and the one-week card gallery (galProcessEntries) are gone. The queue is now a list
# of week GROUPS (lstProcessWeeks), each a band - "Week of Sep 07 – Sep 13, 2026",
# "3 timesheets", "24 h" - over that week's rows, and only the newest week starts
# expanded. So "pick a week, then filter it" is no longer a thing HR can do; the
# week grouping and its expand/collapse are what replaced the picker, and they are
# what this now asserts (E-G), alongside the consultant filter, which survived the
# rebuild unchanged (A-D) but now narrows EVERY week at once.
#
# WHAT IT ASSERTS
#   E. the tab opens with exactly ONE week expanded, and it is the newest week;
#   F. every week's band count ("N timesheets") equals the rows under it once
#      expanded - the grouping neither drops rows nor double-lists them;
#   G. folding the open week hides its rows, and unfolding it brings the same rows
#      back;
#   A. the tab lists at least two DIFFERENT e2e consultants - fatal otherwise,
#      because filtering a single-consultant queue cannot distinguish a working
#      filter from one that does nothing at all, and would pass either way;
#   B. selecting one consultant leaves strictly fewer rows, across all weeks;
#   C. every surviving row is that consultant's - a filter that merely shortened the
#      list is not the same as one that filtered it;
#   D. clearing the filter restores the original row count.
#
# A is the assertion that keeps the filter half honest, and the reason it is fatal
# rather than skipped: this suite's central finding was tests that could not fail.
#
# Consumes: reads only. Folds and unfolds weeks and changes a filter, and puts both
# back.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

CB='.mx-name-cbProcessConsultant'

# groups_state — one line per week group:
#   <label>~~<open 1/0>~~<band count>~~<rows rendered>~~<start date, epoch ms>
# The band count is parsed from txtProcessGroupCount ("3 timesheets"); the start date
# from the label's first date and its year, so "newest" is decided on dates rather
# than on list position.
groups_state() {
  playwright-cli eval "() => { $(_tt_hr_grp_js) if (HG.kind !== 'Process') return 'NOTPROCESS'; return HG.groups().map(x => { const cnt = ((x.g.querySelector('.mx-name-txtProcessGroupCount') || {}).innerText || '').match(/(\d+)/); const L = x.label.replace(/[–—]/g, '-'); const M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']; let y = +((L.match(/(\d{4})/) || [])[1] || 0); const m = L.match(/([A-Z][a-z]{2})\s+(\d{1,2})\s*-\s*([A-Z][a-z]{2})?/); if (m && m[3] && M.indexOf(m[1]) > M.indexOf(m[3])) y--; const t = m && y ? Date.parse(m[1] + ' ' + m[2] + ', ' + y) : NaN; return [x.label, x.open ? 1 : 0, cnt ? cnt[1] : '?', HG.rows(x.g).length, isNaN(t) ? '?' : t].join('~~'); }).join('\n'); }" 2>/dev/null | _tt_eval_str | grep -v '^null$'
}

# all_rows_consultants — expand every week, then print each row's consultant cell,
# one per line. The whole queue, not one week's worth.
all_rows_consultants() {
  tt_hr_expand_all >/dev/null 2>&1
  playwright-cli eval "() => { $(_tt_hr_grp_js) return HG.groups().flatMap(x => HG.rows(x.g)).map(r => ((r.querySelector('.mx-name-txtProcessConsultant') || {}).innerText || '').trim()).join('\n'); }" 2>/dev/null | _tt_eval_str | grep -v '^null$' | grep .
}

tt_login "e2e_hr" "$TT_HR_READY"
tt_hr_click_tab "Weekly to process"
tt_hr_wait_pane "the Weekly to process week groups (lstProcessWeeks)"
[ "$(tt_hr_pane_kind)" = "Process" ] \
  || tt_fail "the Weekly to process tab did not render its week groups (.mx-name-lstProcessWeeks) - kind '$(tt_hr_pane_kind)'. If it shows a week picker again, the rebuild was reverted and this spec's grouping half no longer applies."

# ------------------------------------------------------ E. newest week, alone, open
STATE="$(groups_state)"
NGROUPS="$(printf '%s\n' "$STATE" | grep -c .)"
[ "$NGROUPS" -ge 1 ] \
  || tt_fail "the tab lists no week at all, so neither the grouping nor the filter can be exercised. suites/20-consultant and 30-approval put entries here; run the suite in order."
note "the tab lists $NGROUPS week group(s):"
printf '%s\n' "$STATE" | awk -F'~~' '{printf "    %-44s open=%s band=%s rows=%s\n", $1, $2, $3, $4}'

OPEN_N="$(printf '%s\n' "$STATE" | awk -F'~~' '$2==1' | grep -c .)"
NEWEST="$(printf '%s\n' "$STATE" | awk -F'~~' '$5!="?" {print $5 "~~" $1}' | sort -t'~' -k1,1nr | head -1 | sed 's/^[0-9]*~~//')"
OPEN_L="$(printf '%s\n' "$STATE" | awk -F'~~' '$2==1 {print $1}' | head -1)"
[ -n "$NEWEST" ] || bad "E: could not read a start date from any week label, so 'newest' cannot be decided"
if [ "$OPEN_N" -eq 1 ] && [ "$OPEN_L" = "$NEWEST" ]; then
  note "E ok: exactly one week starts expanded, and it is the newest ('$OPEN_L')"
else
  bad "E: expected exactly the newest week ('$NEWEST') expanded on arrival; $OPEN_N week(s) are expanded (first: '${OPEN_L:-none}')"
fi

# ------------------------------------------- F. band counts agree with their rows
tt_hr_expand_all >/dev/null 2>&1
STATE_ALL="$(groups_state)"
MISMATCH="$(printf '%s\n' "$STATE_ALL" | awk -F'~~' '$2!=1 || $3!=$4 {print "    " $1 ": open=" $2 " band=" $3 " rows=" $4}')"
if [ -z "$MISMATCH" ]; then
  note "F ok: with every week expanded, each band's count equals the rows under it ($(printf '%s\n' "$STATE_ALL" | awk -F'~~' '{s+=$4} END {print s}') row(s) in all)"
else
  bad "F: a week's band count disagrees with the rows it holds, or it would not expand:"
  printf '%s\n' "$MISMATCH"
fi

# ------------------------------------------------------ G. fold and unfold a week
TARGET_WEEK="$(printf '%s\n' "$STATE_ALL" | awk -F'~~' '$4>0 {print $1; exit}')"
if [ -z "$TARGET_WEEK" ]; then
  bad "G: no week holds a row, so folding cannot be observed"
else
  ROWS_OPEN="$(printf '%s\n' "$STATE_ALL" | awk -F'~~' -v w="$TARGET_WEEK" '$1==w {print $4}')"
  r="$(playwright-cli eval "async () => { $(_tt_hr_grp_js) const x = HG.find('$TARGET_WEEK'); if (!x) return 'NF'; x.t.click(); for (let i = 0; i < 30; i++) { await HG.sleep(300); const y = HG.find('$TARGET_WEEK'); if (y && !y.open) return 'folded:' + HG.rows(y.g).length; } return 'stuck'; }" 2>/dev/null | _tt_eval_str)"
  case "$r" in
    folded:0) note "G ok: folding '$TARGET_WEEK' hid its rows" ;;
    *)        bad "G: folding '$TARGET_WEEK' did not hide its rows ($r)" ;;
  esac
  r="$(tt_hr_group_expand "$TARGET_WEEK" keep)"
  if [ "$r" = "OK:$ROWS_OPEN" ]; then
    note "G ok: unfolding it brought the same $ROWS_OPEN row(s) back"
  else
    bad "G: unfolding '$TARGET_WEEK' gave '$r', expected OK:$ROWS_OPEN"
  fi
fi

# ------------------------------------------------- A. more than one consultant present
BEFORE_ROWS="$(all_rows_consultants)"
BEFORE_N="$(printf '%s\n' "$BEFORE_ROWS" | grep -c .)"
note "the whole queue holds $BEFORE_N row(s)"
PRESENT=""
for name in "E2E Consultant" "E2E Consultant Two" "E2E Consultant Three"; do
  printf '%s\n' "$BEFORE_ROWS" | grep -qxF "$name" && PRESENT="$PRESENT|$name"
done
COUNT_PRESENT="$(printf '%s' "$PRESENT" | tr '|' '\n' | grep -c .)"
[ "${COUNT_PRESENT:-0}" -ge 2 ] \
  || tt_fail "the queue names ${COUNT_PRESENT:-0} e2e consultant(s) (${PRESENT#|}). Filtering a queue that holds one consultant cannot tell a working filter from one that does nothing, so this step would pass either way. suites/20-consultant and 30-approval put several there; run the suite in order."
TARGET="$(printf '%s' "${PRESENT#|}" | cut -d'|' -f1)"
OTHER="$(printf '%s' "${PRESENT#|}" | cut -d'|' -f2)"
note "A ok: queue names $COUNT_PRESENT e2e consultant(s); filtering to '$TARGET'"

# ------------------------------------------------------------------- B/C. apply it
tt_combobox_select_text "$CB" "$TARGET" || tt_fail "'$TARGET' was not selectable in the consultant filter"
sleep 3
tt_hr_wait_pane "the week groups after filtering" >/dev/null

AFTER_ROWS="$(all_rows_consultants)"
AFTER_N="$(printf '%s\n' "$AFTER_ROWS" | grep -c .)"
note "filtered to '$TARGET': $AFTER_N row(s) across all weeks"

if [ "${AFTER_N:-0}" -lt "${BEFORE_N:-0}" ] && [ "${AFTER_N:-0}" -gt 0 ]; then
  note "B ok: $BEFORE_N -> $AFTER_N row(s)"
elif [ "${AFTER_N:-0}" -eq "${BEFORE_N:-0}" ]; then
  bad "B: the count did not change ($BEFORE_N), although the queue holds more than one consultant - the filter did nothing"
else
  bad "B: the filtered queue shows $AFTER_N row(s), which is not a narrowing of $BEFORE_N"
fi

STRAYS="$(printf '%s\n' "$AFTER_ROWS" | grep -vxF "$TARGET" | sort -u | tr '\n' ',' | sed 's/,$//')"
if [ -z "$STRAYS" ]; then
  note "C ok: every remaining row is '$TARGET''s ('$OTHER' is gone)"
else
  bad "C: rows for other consultants survived filtering to '$TARGET': $STRAYS - the list got shorter but was not filtered"
fi

# ------------------------------------------------------------------------ D. clear it
# The combobox's own clear control first: "select the option starting with ''" picks
# the FIRST option, which is a consultant, not "no filter".
if [ "$(playwright-cli eval "() => { const b=document.querySelector('$CB .widget-combobox-clear-button'); if(!b) return 'none'; b.click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)" != "ok" ]; then
  tt_combobox_select_text "$CB" "" >/dev/null 2>&1 || playwright-cli press "Escape" >/dev/null 2>&1
fi
sleep 3
tt_hr_wait_pane "the week groups after clearing the filter" >/dev/null
RESTORED_N="$(all_rows_consultants | grep -c .)"
if [ "${RESTORED_N:-0}" -eq "${BEFORE_N:-0}" ]; then
  note "D ok: clearing the filter restored $RESTORED_N row(s)"
else
  bad "D: after clearing the filter the queue shows $RESTORED_N row(s), not the $BEFORE_N it started with - the filter is sticky, and HR's next action would run against a queue they think is complete"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-tab-filters — $fails problem(s) with the Weekly to process grouping or its consultant filter."
  exit 1
fi
echo "PASS: verify-hr-tab-filters — $NGROUPS week group(s), newest open on arrival, band counts match their rows, a week folds and unfolds; filtering to '$TARGET' narrowed $BEFORE_N to $AFTER_N rows and clearing restored $RESTORED_N."
