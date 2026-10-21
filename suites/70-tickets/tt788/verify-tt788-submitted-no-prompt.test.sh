#!/usr/bin/env bash
# tt-timeout: 15m
# verify-tt788-submitted-no-prompt.test.sh
#
# TT-788 #4: a submitted week never shows the "Add your first task" prompt, even on
# a task-based row that has no tasks.
#
# WHY THIS EXISTS. The prompt's button adds a task. On a week that has been
# submitted (or approved, or exported) nothing may be added, so the prompt must
# not be there at all — the row shows its read-only day cells, as before TT-788.
# The prompt is keyed on an empty task list AND on the row being editable; this
# is the half that the other three tt788 specs never reach, because they all run
# on editable weeks. A task-less row is the only case where it can fail: with a
# task the prompt is gone anyway.
#
# WHERE THE WEEK COMES FROM, in order
#   1. An ALREADY submitted week of E2E Consultant whose 'E2E Line Items' row has no
#      tasks. The approval specs earlier in the run submit several of this
#      consultant's weeks on other projects, and a weekly Submit submits every row
#      of the week, so such a week is normally there (ACT_Timesheet_Submit does not
#      refuse a task-based row with no tasks). Read-only.
#   2. Otherwise this spec makes one: an editable week with a task-less row and no
#      hours on ANY row (so nothing seeded by another spec is submitted with it),
#      where the prompt is checked to be showing first, then the week is submitted
#      empty - the path verify-submit-empty-week drives - and the same week is read
#      again. That consumes the week: every entry on it goes to ToProcess at 0 h.
#
# WHAT IT ASSERTS, on that week's 'E2E Line Items' row (no tasks, not editable)
#   A. the prompt is not visible and btnAddFirstTask is not visible;
#   B. the seven day cells and the row total ARE visible — the row is the
#      pre-TT-788 read-only row, not an empty strip.
#   (path 2 also asserts, fatally, that the same row showed the prompt before the
#   submit, so A is a change watched happening.)
#
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt788.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

nonzero_cells() {
  ev "() => { const els=[...document.querySelectorAll('.mx-name-galAssignmentRows input')].filter(e => !e.closest('.mx-name-txtLineItemName')); return String(els.filter(e => { const v=String(e.value||'').trim().replace(',','.'); return v !== '' && parseFloat(v) > 0; }).length); }"
}

tt_login "$TT788_CONSULTANT" "My Timesheets"

# ------------------------------------------------------------- 1. find one
HOW=""
if tt788_find_week submitted-empty; then
  HOW="found"
  note "path 1: week $TT788_WEEK is already submitted and its '$TT788_PROJECT' row has no tasks"
else
  note "path 1: no submitted week with a task-less '$TT788_PROJECT' row ($(tt788_census_help | head -1))"
fi

# ------------------------------------------------------------- 2. make one
if [ -z "$HOW" ]; then
  tt_login "$TT788_CONSULTANT" "My Timesheets"   # back to this week
  picked=""
  for _ in 1 2 3 4 5 6; do
    tt788_find_week empty-editable \
      || tt_fail "path 2: no editable week with a task-less '$TT788_PROJECT' row to submit within $TT788_HORIZON weeks
  $(tt788_census_help)"
    NZ="$(nonzero_cells)"
    if [ "$NZ" = "0" ]; then picked=1; break; fi
    note "path 2: week $TT788_WEEK carries $NZ filled cell(s) on other rows; not submitting someone else's draft"
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  [ -n "$picked" ] || tt_fail "path 2: no empty, editable week with a task-less '$TT788_PROJECT' row found to submit"
  [ "$(tt_week_actionable)" = "true" ] || tt_fail "path 2: week $TT788_WEEK has no Submit (status: $(tt_week_status "$TT788_CONSULTANT" "$TT788_WEEK"))"

  P="$(tt788_probe)"
  [ "$(tt788_get "$P" prompt)" = "1" ] \
    || tt_fail "path 2 precondition: the prompt is not showing on the task-less editable row on week $TT788_WEEK, so its absence after the submit would prove nothing (probe: $P; verify-tt788-prompt-shown says why)"
  note "path 2: week $TT788_WEEK shows the prompt; submitting it empty"

  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  tt_wait_for ".mx-name-btnConfirmSubmit" "the Submit timesheet? confirmation (btnConfirmSubmit)"
  playwright-cli click ".mx-name-btnConfirmSubmit" >/dev/null 2>&1
  up=""
  for _ in $(seq 1 20); do
    up="$(ev "() => String(!!document.querySelector('.mx-name-containerReceipt'))")"
    [ "$up" = "true" ] && break
    sleep 1
  done
  if [ "$up" = "true" ]; then
    playwright-cli click ".mx-name-btnReceiptOk" >/dev/null 2>&1
    sleep 3
  else
    tt_clear_dialogs 6 >/dev/null 2>&1
  fi
  [ "$(tt_current_week)" = "$TT788_WEEK" ] || tt_fail "path 2: after the submit the grid shows '$(tt_current_week)', not $TT788_WEEK"
  tt_refetch_week
  [ "$(tt_week_actionable)" = "false" ] \
    || tt_fail "path 2: week $TT788_WEEK still offers Submit after submitting it (status: $(tt_week_status "$TT788_CONSULTANT" "$TT788_WEEK")) — the submit did not happen, so there is no submitted week to look at"
  HOW="made"
fi

# ------------------------------------------------------------- assertions
P=""
for _ in 1 2 3; do
  P="$(tt788_probe)"
  [ "$(tt788_get "$P" gal)" = "1" ] && break
  sleep 1
done
note "probe ($HOW, week $TT788_WEEK): $P"
g() { tt788_get "$P" "$1"; }

[ "$(g row)" = "1" ] || tt_fail "the '$TT788_PROJECT' row is not on week $TT788_WEEK"
[ "$(g tasks)" = "0" ] || tt_fail "the '$TT788_PROJECT' row on week $TT788_WEEK has $(g tasks) task(s); the check needs a task-less row"
[ "$(g editable)" = "0" ] || bad "the '$TT788_PROJECT' row on submitted week $TT788_WEEK is still editable (btnAddTask present)"

# A. no prompt
[ "$(g prompt)" = "0" ] \
  && note "A ok: no prompt on the submitted week" \
  || bad "A the first-task prompt is showing on submitted week $TT788_WEEK — its button would add a task to a submitted entry"
[ "$(g addfirst)" = "0" ] \
  && note "A ok: btnAddFirstTask is not visible" \
  || bad "A btnAddFirstTask is visible on submitted week $TT788_WEEK"

# B. the read-only row is there
[ "$(g days)" = "7" ] \
  && note "B ok: all seven day cells are visible" \
  || bad "B $(g days) of 7 day cells are visible on the submitted row"
[ "$(g total)" = "1" ] \
  && note "B ok: the row total is visible" \
  || bad "B the row total is not visible on the submitted row"

if [ "$fails" -gt 0 ]; then
  echo "FAIL: verify-tt788-submitted-no-prompt — $fails check(s) failed on week $TT788_WEEK ($HOW)"
  exit 1
fi
echo "PASS: verify-tt788-submitted-no-prompt — a submitted week shows no first-task prompt on a task-less row ($TT788_WEEK, $HOW)"
