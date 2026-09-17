#!/usr/bin/env bash
# The consultant filter on HR's Weekly To Process tab actually narrows the queue,
# and clearing it restores what was there.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. cbProcessConsultant is the control HR uses to find one person's
# week among everyone's before acting on it. Only the SORT of a similar list is
# tested (verify-hr-sent-consultant-sorted); no test has ever selected a value in
# any of these filters and looked at what survived.
#
# A filter that silently does nothing is not a cosmetic bug on this screen. The
# next thing HR does after filtering is press Process or Reject on "the row", and
# a filter that did not apply means that row belongs to a different consultant.
# The wrong person's week gets rejected and the right person's is still waiting.
#
# WHAT IT ASSERTS
#   A. the tab lists at least two DIFFERENT consultants - fatal otherwise, because
#      filtering a single-consultant queue cannot distinguish a working filter from
#      one that does nothing at all, and would pass either way;
#   B. selecting one consultant leaves a strictly smaller set of cards;
#   C. every surviving card names that consultant - a filter that merely shortened
#      the list is not the same as one that filtered it;
#   D. clearing the filter restores the original count.
#
# A is the assertion that keeps this honest, and the reason it is fatal rather than
# skipped: this suite's central finding was tests that could not fail.
#
# Consumes: reads only. Changes a filter and puts it back.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

GAL='.mx-name-galProcessEntries'
CB='.mx-name-cbProcessConsultant'

card_count() { playwright-cli eval "() => { const g=document.querySelector('$GAL'); if(!g) return '-1'; return String(g.querySelectorAll('.mx-name-cardConsultantRow, [class*=card]').length || g.children.length); }" 2>/dev/null | _tt_eval_str; }
gal_text()   { playwright-cli eval "() => { const g=document.querySelector('$GAL'); return g ? (g.innerText||'').replace(/\\s+/g,' ') : ''; }" 2>/dev/null | _tt_eval_str; }

tt_login "e2e_hr" "WEEKLY TO PROCESS"
sleep 3

[ "$(playwright-cli eval "() => String(!!document.querySelector('$GAL'))" 2>/dev/null | _tt_eval_str)" = "true" ] \
  || tt_fail "the Weekly To Process gallery ($GAL) is not on the page, so the filter cannot be exercised"

BEFORE_N="$(card_count)"
BEFORE_T="$(gal_text)"
note "queue shows $BEFORE_N card(s)"

# ------------------------------------------------- A. more than one consultant present
PRESENT=""
for name in "E2E Consultant" "E2E Consultant Two" "E2E Consultant Three"; do
  case "$BEFORE_T" in *"$name"*) PRESENT="$PRESENT|$name" ;; esac
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

AFTER_N="$(card_count)"
AFTER_T="$(gal_text)"
note "filtered to '$TARGET': $AFTER_N card(s)"

if [ "${AFTER_N:-0}" -lt "${BEFORE_N:-0}" ] && [ "${AFTER_N:-0}" -gt 0 ]; then
  note "B ok: $BEFORE_N -> $AFTER_N card(s)"
elif [ "${AFTER_N:-0}" -eq "${BEFORE_N:-0}" ]; then
  bad "B: the count did not change ($BEFORE_N), although the queue holds more than one consultant - the filter did nothing"
else
  bad "B: the filtered queue shows $AFTER_N card(s), which is not a narrowing of $BEFORE_N"
fi

case "$AFTER_T" in
  *"$OTHER"*) bad "C: '$OTHER' still appears after filtering to '$TARGET' - the list got shorter but was not filtered" ;;
  *)          note "C ok: '$OTHER' is gone from the filtered list" ;;
esac
case "$AFTER_T" in
  *"$TARGET"*) note "C ok: '$TARGET' is still present" ;;
  *)           bad "C: '$TARGET' is not in the list after filtering to them" ;;
esac

# ------------------------------------------------------------------------ D. clear it
tt_combobox_select_text "$CB" "" >/dev/null 2>&1 || playwright-cli press "Escape" >/dev/null 2>&1
sleep 3
RESTORED_N="$(card_count)"
if [ "${RESTORED_N:-0}" -eq "${BEFORE_N:-0}" ]; then
  note "D ok: clearing the filter restored $RESTORED_N card(s)"
else
  bad "D: after clearing the filter the queue shows $RESTORED_N card(s), not the $BEFORE_N it started with - the filter is sticky, and HR's next action would run against a queue they think is complete"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-hr-tab-filters — $fails problem(s) with the consultant filter."
  exit 1
fi
echo "PASS: verify-hr-tab-filters — filtering to '$TARGET' narrowed $BEFORE_N to $AFTER_N and clearing restored $RESTORED_N."
