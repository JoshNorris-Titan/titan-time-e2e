#!/usr/bin/env bash
# A1 — focus survives Tab on a FRESH timesheet week.  *** THE HEADLINE FIX ***
#
# Before the change, a fresh week's Timesheet + assignment rows were created
# UNCOMMITTED; the first keystroke-commit forced a full grid re-render that threw
# focus off the page entirely. They are now committed at week creation.
#
# This MUST run on a week that has never been opened — an already-saved week does
# not exercise the bug. tt_goto_fresh_week enforces that (all day cells blank).
#
# Pass:  after each Tab, focus is still inside the assignment grid.
# Fail:  focus lands on <body> / is lost (the original bug).

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt692693.sh"

# IMPORTANT: A1 must run on a REGULAR (non-line-item) assignment row. On a
# NeedsLineItems project the aggregate day boxes are not directly editable, so
# clicking them never takes focus and Tab walks the nav links instead — which looks
# exactly like the focus-loss bug but is a test artifact. Default to a
# single-row, non-line-item project.
USER_="${TT_A1_USER:-e2e_consultant2}"
PROJECT="${TT_A1_PROJECT:-E2E Sandbox}"
DAYS="txtDaySun txtDayMon txtDayTues txtDayWed txtDayThurs txtDayFri txtDaySat"
# 5h x 7 = 35h — deliberately UNDER 40 so the over-40 confirmation modal never fires
# mid-run and steals focus (that modal is expected behaviour, not the bug under test).
HOURS="${TT_A1_HOURS:-5}"

# Where is focus right now? Returns "<tag>|<mx-name class>|<inGrid true/false>"
focus_info() {
  playwright-cli eval "() => { const a=document.activeElement; if(!a) return 'none||false'; const cls=(a.className||'').toString(); const own=cls.split(' ').find(c=>c.startsWith('mx-name-'))||''; let p=a, inGrid=false; for(let i=0;i<12;i++){ if(!p) break; const c=(p.className||'').toString(); if(c.indexOf('mx-name-galAssignmentRows')>=0){ inGrid=true; break; } p=p.parentElement; } const near=(a.closest&&a.closest('[class*=mx-name-txtDay]')); const nm=near?(near.className||'').toString().split(' ').find(c=>c.startsWith('mx-name-')):own; return a.tagName+'|'+(nm||own)+'|'+inGrid; }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

tt_login "$USER_" "My Timesheets"

WEEK="$(tt_goto_fresh_week "$PROJECT")" || tt_fail "A1: could not find a FRESH (never-entered) week containing '$PROJECT' — the test is invalid on a saved week"
echo "fresh week: $WEEK  (project: $PROJECT)"

# Sanity: the grid has at least one assignment row.
ROWS=$(playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDaySun').length)" 2>/dev/null | sed -n '2p' | tr -d '"')
[ "${ROWS:-0}" -ge 1 ] || tt_fail "A1: no assignment rows on the fresh week (consultant has no active assignment?)"
echo "assignment rows: $ROWS"

LOST=""
i=0
for d in $DAYS; do
  i=$((i + 1))
  # Focus the day cell of row 1 and type a real keystroke (not fill — the bug is
  # keystroke-commit driven).
  # A stray modal (validation / 40-hour prompt) captures focus and invalidates the
  # next assertion — clear it before measuring.
  if [ "$(tt_popup_open)" = "true" ]; then
    echo "  (dismissing a modal before $d)"
    tt_dismiss_dialogs
    sleep 1
  fi

  playwright-cli click ":nth-match(.mx-name-galAssignmentRows .mx-name-$d input, 1)" >/dev/null 2>&1
  sleep 1
  BEFORE="$(focus_info)"

  # HARNESS GUARD: the click must actually put focus in a day INPUT inside the grid.
  # If it didn't (e.g. a read-only line-item row), typing goes nowhere and every Tab
  # looks like "focus loss" — a false positive. Try a direct JS focus, then bail.
  case "$BEFORE" in
    INPUT*true) ;;
    *)
      playwright-cli eval "() => { const e=document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-$d input')[0]; if(e){ e.focus(); return 'focused'; } return 'missing'; }" >/dev/null 2>&1
      sleep 1
      BEFORE="$(focus_info)"
      case "$BEFORE" in
        INPUT*true) ;;
        *) tt_fail "A1 HARNESS ERROR (not an app bug): could not put focus in '$d' on row 1 (got [$BEFORE]).
   The row is probably read-only (a NeedsLineItems project). Re-run against a regular
   project via TT_A1_USER / TT_A1_PROJECT." ;;
      esac
      ;;
  esac

  # Clear the cell first — day cells pre-render as "0.00", so typing straight in
  # yields "0.008" and makes the total assertions meaningless. Select-all, then type
  # a REAL keystroke (not fill: the bug is keystroke-commit driven).
  playwright-cli press "ControlOrMeta+a" >/dev/null 2>&1
  playwright-cli type "$HOURS" >/dev/null 2>&1
  sleep 1
  playwright-cli press "Tab" >/dev/null 2>&1
  sleep 2
  AFTER="$(focus_info)"
  IN_GRID="${AFTER##*|}"
  echo "  $d: before=[$BEFORE] after-Tab=[$AFTER]"
  if [ "$IN_GRID" != "true" ]; then
    LOST="${LOST}${d} "
  fi
done

# Totals should have updated as we went (7 x 8 = 56 on this row).
TOTALS=$(playwright-cli eval "() => { const t=[...document.querySelectorAll('.mx-name-galAssignmentRows [class*=mx-name-txtRowTotal] input, .mx-name-galAssignmentRows [class*=mx-name-txtTotal] input')].map(i=>i.value); const body=document.body.innerText||''; const dt=(body.match(/Daily Totals[\s\S]{0,120}/)||[''])[0].replace(/\n+/g,' '); return JSON.stringify({rowTotals:t.slice(0,3), dailyTotals:dt}); }" 2>/dev/null | sed -n '2p')
echo "totals after entry: $TOTALS"

if [ -n "$LOST" ]; then
  tt_fail "A1 FAIL (focus-loss bug present): focus left the assignment grid after Tab on: $LOST(week $WEEK)"
fi

echo "PASS: A1 — focus stayed inside the assignment grid across all 7 Tab presses on fresh week $WEEK"
