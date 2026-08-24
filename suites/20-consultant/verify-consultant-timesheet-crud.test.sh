#!/usr/bin/env bash
# Consultant timesheet draft persistence (Tier-1 CRUD).
#
# Verifies that editing a day cell and clicking "Save Draft" persists to the
# server (survives a re-fetch of the week), and that a second edit OVERWRITES the
# saved value. Uses draft-save only — it never submits — so the week stays
# editable and the test is repeatable.
#
# Re-fetch strategy: navigating one week back and forward re-queries the entry
# from the DB (each week is a distinct object), so a value still present after
# that round-trip was genuinely saved, not just held in the input.
#
# NOTE: the "Clear" button is intentionally NOT covered — it empties the input
# display but does not commit the cleared value, so Save Draft re-persists the
# old number (see tests/FINDINGS.md). Create + update are the reliable paths.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

DAY="Thurs"
# CELL is a plain CSS selector, used inside document.querySelector(...) in the
# evals below — querySelector already means "the first match", so it is safe there.
CELL=".mx-name-txtDay${DAY} input"
# CELL_PW is the same cell for playwright-cli fill/click, which is STRICT: a
# consultant assigned to several projects has one row per assignment, the bare
# selector matches all of them, and Playwright refuses the write. That silent
# refusal is what produced "draft did not persist (wrote 7, re-fetched '0.00')"
# — nothing was ever typed. See tt_fill in lib/_login.sh.
CELL_PW=":nth-match(${CELL}, 1)"

# Read the day cell's current value (empty string if none / element missing).
read_cell() {
  local v
  v=$(playwright-cli eval "() => String((document.querySelector('$CELL')||{}).value || '')" 2>/dev/null | sed -n '2p')
  v="${v%\"}"; v="${v#\"}"
  echo "$v"
}

# Navigate away and back to force a server re-fetch of the current week.
refetch_week() {
  playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; sleep 2
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 3
}

tt_login "e2e_consultant" "My Timesheets"

# Step to the first editable week (editable day cell + a Save Draft button).
found=""
for _ in $(seq 1 10); do
  if playwright-cli eval "() => { const d=document.querySelector('$CELL'); const ed=d && !d.disabled && !d.readOnly; return String(!!ed && !!document.querySelector('.mx-name-btnSaveDraft')); }" 2>/dev/null | grep -qiw true; then
    found=1; break
  fi
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  sleep 2
done
[ -n "$found" ] || tt_fail "no editable week with a Save Draft button found"
WEEK=$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'')" 2>/dev/null | sed -n '2p')
echo "editing week: $WEEK"

# Pick two distinct target values, the first differing from whatever is there now,
# so each pass proves a real write (not a value that happened to already be there).
INIT="$(read_cell)"
T1="7"; T2="5"
case "$INIT" in *7*) T1="4" ;; esac
[ "$T1" = "$T2" ] && T2="3"

# 1) create/write + save, re-fetch, assert persisted
tt_fill "$CELL_PW" "$T1"
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 2
refetch_week
AFTER1="$(read_cell)"
case "$AFTER1" in
  *"$T1"*) echo "persisted after 1st Save Draft: '$AFTER1'" ;;
  *) tt_fail "draft did not persist (wrote $T1, re-fetched '$AFTER1')" ;;
esac

# 2) update to a different value + save, re-fetch, assert it overwrote
tt_fill "$CELL_PW" "$T2"
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 2
refetch_week
AFTER2="$(read_cell)"
case "$AFTER2" in
  *"$T2"*) echo "update persisted after 2nd Save Draft: '$AFTER2'" ;;
  *) tt_fail "update did not persist (wrote $T2 over $T1, re-fetched '$AFTER2')" ;;
esac

echo "PASS: consultant timesheet Save Draft create+update persist across re-fetch ($WEEK, $DAY)"
