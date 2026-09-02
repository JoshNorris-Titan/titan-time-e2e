#!/usr/bin/env bash
# B1 — line-item rollup is correct and does not error (TT-692).
#
# Change: new line items are committed on add, and per-keystroke commits switched
# to "without events". This removes the reproducible FRESH-ENTRY failure.
#
# Fail signals (the original bug):
#   * row total stays 0.00 while the line total shows a value
#   * "An error occurred" dialog / HTTP 560 on the FIRST edit of a brand-new entry
#
# NOTE (per the brief): this work MITIGATES TT-692, it does not make the rollup
# fully deterministic. A rare stale total on an ALREADY-SETTLED entry is the known
# residual, not a new break — this script reports that separately as RESIDUAL.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt692693.sh"

USER_="${TT_B1_USER:-e2e_consultant}"
PROJECT="${TT_B1_PROJECT:-E2E Line Items}"
ROW=".mx-name-galAssignmentRows"

line_total() { playwright-cli eval "() => String((document.querySelectorAll('$ROW .mx-name-txtLineTotal input')[$1 - 1]||{}).value||'')" 2>/dev/null | sed -n '2p' | tr -d '"'; }

# Row total OF THE ROW UNDER TEST.
#
# This used to be document.querySelector('...txtRowTotal input') - i.e. the FIRST
# row total in the whole gallery. The consultant's week carries one row per
# assignment, and lib/_fixtures.sh seeds four of them; on dev the order is
#   0 E2E Customer Approval | 1 E2E Manager Approval | 2 E2E Line Items | 3 E2E Dual Approval
# so the unscoped read returned the E2E Customer Approval row, which this test never
# touches and which therefore reads 0.00 forever. The assertion could not pass, and
# it failed as "ROW TOTAL STALE (0.00)" - a product bug that was not there. Measured
# on dev 2026-09-01 after entering 7h: the four row totals were 0.00 / 0.00 / 7.00 /
# 0.00, so the rollup was correct and instant while the test read index 0.
#
# Scope it by ANCHOR, not by index or project text. Only the line-items row carries
# btnAddTask / btnLineItemsCollapse, so walk up from that control to the first
# ancestor holding EXACTLY ONE row total - that ancestor is the row. Requiring
# exactly one is what makes this self-checking: the gallery-wide container holds
# four, so overshooting is detected rather than silently returning row 0. Matching
# on the project NAME instead does not work - every row total has an ancestor
# containing 'E2E Line Items' once you walk far enough up (depth 5 on dev).
#
# Returns '' when the row cannot be identified; probe_fresh_entry reports that as
# its own failure rather than comparing against a number it did not read.
row_total() {
  playwright-cli eval "() => { const g=document.querySelector('$ROW'); if(!g) return ''; const a=g.querySelector('.mx-name-btnAddTask')||g.querySelector('.mx-name-btnLineItemsCollapse')||g.querySelector('.mx-name-btnLineItemsExpand'); if(!a) return ''; let el=a; for(let k=0;k<14;k++){ el=el.parentElement; if(!el||el===g) break; const n=el.querySelectorAll('[class*=mx-name-txtRowTotal] input'); if(n.length===1) return String(n[0].value||''); if(n.length>1) return ''; } return ''; }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

task_count() { playwright-cli eval "() => String(document.querySelectorAll('$ROW .mx-name-txtLineItemName input').length)" 2>/dev/null | sed -n '2p' | tr -d '"'; }

had_error_dialog() {
  playwright-cli eval "() => { const d=document.querySelector('[role=dialog],.modal-dialog,.mx-window'); return String(!!d && /error occurred|internal server error/i.test(d.innerText||'')); }" 2>/dev/null | sed -n '2p' | tr -d '"'
}

expand_tasks() {
  local i tgl
  for i in 1 2 3; do
    playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnAddTask'); return String(!!b && b.offsetParent!==null); }" 2>/dev/null | grep -qiw true && return 0
    tgl=$(playwright-cli eval "() => { for (const s of ['btnLineItemsCollapse','btnLineItemsExpand']){ const t=document.querySelector('.mx-name-'+s); if (t && t.offsetParent!==null) return s; } return ''; }" 2>/dev/null | sed -n '2p' | tr -d '"')
    [ -n "$tgl" ] && playwright-cli click ".mx-name-$tgl" >/dev/null 2>&1
    sleep 2
  done
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnAddTask'))" 2>/dev/null | grep -qiw true
}

# One full fresh-entry probe. $1 = label. Echoes RESULT lines; sets FAILED on hard fail.
FAILED=""
RESIDUAL=""
probe_fresh_entry() {
  local label="$1"
  local wk; wk="$(tt_goto_fresh_week "$PROJECT")" || { echo "  [$label] no further FRESH week with '$PROJECT' — skipping"; return 2; }
  echo "  [$label] fresh week: $wk"
  expand_tasks || { echo "  [$label] could not reveal Add Task"; FAILED="$FAILED $label(no-add-task)"; return 1; }

  local n0; n0="$(task_count)"
  playwright-cli click ".mx-name-btnAddTask" >/dev/null 2>&1
  sleep 2
  if [ "$(had_error_dialog)" = "true" ]; then
    echo "  [$label] ERROR DIALOG on Add Task"; FAILED="$FAILED $label(add-task-error)"; tt_dismiss_dialogs; return 1
  fi
  local idx=$(( n0 + 1 ))
  [ "$(task_count)" = "$idx" ] || { echo "  [$label] Add Task did not add a row"; FAILED="$FAILED $label(no-row)"; return 1; }

  playwright-cli fill ":nth-match($ROW .mx-name-txtLineItemName input, $idx)" "B1 $label" >/dev/null 2>&1
  # Prove the name landed before going further. Add Task COMMITS the LineItem with
  # an empty Name and the fill above is silenced, so a refused write (strict-mode
  # violation) leaves an unnamed row behind. Main.LineItem.Name is required and the
  # week saves as one unit, so that row makes the ENTIRE week unsaveable for every
  # project on it — surfacing much later, in another test, as a bogus submit bug.
  # Reported the way this test reports everything else, rather than aborting.
  local got
  got="$(playwright-cli eval "() => { const els=document.querySelectorAll('$ROW .mx-name-txtLineItemName input'); const el=els[$idx-1]; return el ? (el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str)"
  if [ "$got" != "B1 $label" ]; then
    echo "  [$label] task name did not stick (wanted 'B1 $label', got '$got') — this leaves an UNNAMED line item that will block every submit on this week"
    FAILED="$FAILED $label(name-not-set)"; return 1
  fi

  # THE critical step: first edit of a brand-new entry (Tuesday, 7h).
  #
  # SELECT ALL BEFORE TYPING. Add Task commits the LineItem with its day attributes
  # at 0, so the cell already renders "0.00" - it is not empty. Clicking it puts the
  # caret where the click landed (measured on dev: index 2, right after the "0."),
  # and `type "7"` then INSERTS: "0.00" -> "0.700" -> committed as 0.7 -> "0.70".
  # That is where the 2026-09-01 failure's lineTotal=0.70 came from, and the old
  # `case "$lt" in *7*)` check waved it through because "0.70" contains a 7.
  # Ctrl/Cmd+A keeps this a real keystroke path - which is the point of B1, the
  # original bug fired on typing - while making the 7 replace the default.
  playwright-cli click ":nth-match($ROW .mx-name-txtLineTues input, $idx)" >/dev/null 2>&1
  sleep 1
  playwright-cli press "ControlOrMeta+a" >/dev/null 2>&1
  playwright-cli type "7" >/dev/null 2>&1
  playwright-cli press "Tab" >/dev/null 2>&1
  sleep 3

  if [ "$(had_error_dialog)" = "true" ]; then
    echo "  [$label] ERROR DIALOG on first edit (the TT-692 560 signature)"
    FAILED="$FAILED $label(first-edit-error)"; tt_dismiss_dialogs; return 1
  fi
  if playwright-cli console 2>/dev/null | grep -qiE "/xas/.*560|\"result\":560|internal server error"; then
    echo "  [$label] HTTP 560 in console on first edit"
    FAILED="$FAILED $label(560)"; return 1
  fi

  local lt rt; lt="$(line_total "$idx")"; rt="$(row_total)"
  echo "  [$label] lineTotal=$lt rowTotal=$rt"
  # Match 7 / 7.0 / 7.00 EXACTLY. The old pattern was *7*, which also accepts 0.70,
  # 17, 7.75 - i.e. it passed on the very mis-entry the select-all above now
  # prevents, and left the row-total branch to report the resulting mismatch as a
  # product bug. If the number is wrong, say so here, where the cause is visible.
  case "$lt" in 7|7.0|7.00) ;; *) echo "  [$label] line total wrong (expected 7, got '$lt')"; FAILED="$FAILED $label(line-total)"; return 1 ;; esac
  case "$rt" in
    7|7.0|7.00) echo "  [$label] rollup OK" ;;
    "") echo "  [$label] could not identify the '$PROJECT' row's total - not reporting a rollup result"; FAILED="$FAILED $label(no-row-total)"; return 1 ;;
    *0.00*) echo "  [$label] ROW TOTAL STALE ($rt) while line total is $lt"; FAILED="$FAILED $label(row-0.00)"; return 1 ;;
    *) echo "  [$label] row total unexpected: $rt"; RESIDUAL="$RESIDUAL $label($rt)" ;;
  esac

  # delete the task we added -> totals recompute, no error dialog
  playwright-cli click ":nth-match($ROW .mx-name-btnLineItemDelete, $idx)" >/dev/null 2>&1
  sleep 3
  if [ "$(had_error_dialog)" = "true" ]; then
    echo "  [$label] ERROR DIALOG on task delete"; FAILED="$FAILED $label(delete-error)"; tt_dismiss_dialogs; return 1
  fi
  echo "  [$label] delete OK (tasks now $(task_count))"
  return 0
}

tt_login "$USER_" "My Timesheets"
echo "B1: probing FRESH entries on '$PROJECT' (the original bug hit the FIRST edit of a new entry)"

probe_fresh_entry "entry-1"
# advance a week so the next probe is a genuinely different brand-new entry
playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 2
probe_fresh_entry "entry-2"

[ -n "$RESIDUAL" ] && echo "NOTE (known residual, NOT a regression): $RESIDUAL"
[ -z "$FAILED" ] || tt_fail "B1 FAIL:$FAILED"
echo "PASS: B1 — line-item rollup correct on fresh entries, no error dialog / 560, delete recomputes"
