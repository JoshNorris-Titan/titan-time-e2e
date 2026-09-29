#!/usr/bin/env bash
# _mixedweek.sh — build a MIXED week: one consultant week holding one line the
# project manager APPROVED and one line the project manager REJECTED.
# Source AFTER lib/_login.sh and lib/_entries.sh.
#
# WHY THIS EXISTS. Bug #1 (2026-09-28) is about exactly this week. A week turns
# Rejected as soon as ANY of its lines is rejected, and every tool that "resets" a
# Rejected week - the consultant's Save and Submit, HR's replace-draft on Create
# Timesheet - used to reset EVERY line on it, the approved ones included. The fix
# (Main.ACT_Timesheet_Draft, Main.ACT_Timesheet_Submit, Main.SUB_Timesheet_BlankForHR)
# resets only lines that are still editable (_IsEditable: sent back, or never
# submitted). The specs that prove it all start from this week, so it is built once,
# here. The first version of this scenario was the bug-#1 repro spec on PR #132.
#
# THE WEEK. e2e_consultant2 is assigned to two manager-approval projects
# (lib/_fixtures.sh: E2E Sandbox and E2E Manager Approval, both Yes/No), so one of
# its weeks can hold two lines that the SAME project manager (e2e_pm) decides on:
#   mw_submit_fresh_week  a fresh week, MW_KEEP_H hours/day Mon-Fri on the Manager
#                         Approval row and MW_REJ_H on the Sandbox row, Save, Submit.
#                         Both lines -> AwaitingManagerApproval, week Awaiting_Approval.
#   mw_pm_decide          PM approves the Manager Approval line (-> ToProcess) and
#                         rejects the Sandbox line with a comment. Week -> Rejected.
# Different hours per row, so "kept its hours", "was blanked" and "summed both" are
# three different numbers.
#
# THE PM ROW. The PM gallery item reads like "E2E Consultant Two E2E Sandbox Approve
# Sep 27 - Oct 03 20.00 hrs"; mw_pm_row_js matches consultant, project and the week's
# start date in any of the shapes the gallery uses.
#
# Everything is read back from the data layer (lib/_entries.sh): the timesheet page
# never renders a line's own status.

MW_CUSER="${MW_CUSER:-e2e_consultant2}"
MW_CNAME="${MW_CNAME:-E2E Consultant Two}"
MW_PM="${MW_PM:-e2e_pm}"
MW_KEEP="E2E Manager Approval"    # the PM approves it
MW_REJ="E2E Sandbox"              # the PM rejects it
MW_KEEP_H="${MW_KEEP_H:-4}"       # hours per day, Mon-Fri
MW_REJ_H="${MW_REJ_H:-3}"
MW_COMMENT="${MW_COMMENT:-E2E bug #1 mixed week - rejected so the week turns Rejected}"
MW_WEEK=""
MW_WEEKMATCH="false"

# mw_hours_fmt <n> — "N.00", the shape tt_week_ledger prints.
mw_hours_fmt() { awk -v n="$1" 'BEGIN { printf "%.2f", n }'; }

# mw_week_is_fresh — 'true' when the grid shows an actionable week whose day cells
# all read empty or zero.
mw_week_is_fresh() {
  playwright-cli eval "() => { if(!document.querySelector('.mx-name-btnSubmit')) return 'false'; const ins=[...document.querySelectorAll('.mx-name-galAssignmentRows [class*=mx-name-txtDay] input')]; if(!ins.length) return 'false'; const hours=ins.some(i=>{ const v=parseFloat((i.value||'').replace(',','.')); return !isNaN(v) && v!==0; }); return String(!hours); }" 2>/dev/null | _tt_eval_str
}

# mw_fill_row <ordinal> <hours> [days] — fill <days> (default Mon..Fri) on one grid
# row, then commit.
mw_fill_row() {
  local d days="${3:-Mon Tues Wed Thurs Fri}"
  for d in $days; do
    tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, $1)" "$2"
  done
  tt_commit_focused
  sleep 1
}

# mw_cell <ordinal> <day> — the value in one day cell of one row.
mw_cell() {
  playwright-cli eval "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDay$2 input')[$1 - 1]||{}).value||'')" 2>/dev/null | _tt_eval_str
}

# mw_badge — the week-status badge's caption (txtWeekStatus: Draft / Submitted /
# Approved / Rejected / Awaiting export).
mw_badge() {
  playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekStatus')||{}).innerText||'').trim()" 2>/dev/null | _tt_eval_str
}

# mw_set_weekmatch — the JS condition, over a row text `t`, that says the row is for
# MW_WEEK. The PM gallery writes the start date its own way: "Mmm DD", "Mmm D", or
# MM/DD/.
mw_set_weekmatch() {
  local m1 d1 mnum
  m1="${MW_WEEK%% *}"; d1="${MW_WEEK#* }"; d1="${d1%% *}"
  mnum="$(( $(echo "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec" | tr ' ' '\n' | grep -n "^$m1\$" | cut -d: -f1) ))"
  MW_WEEKMATCH="t.indexOf('$m1 $d1')>=0 || t.indexOf('$m1 $((10#$d1))')>=0 || t.indexOf('$(printf '%02d/%02d/' "$mnum" "$((10#$d1))")')>=0 || t.indexOf('$mnum/$((10#$d1))/')>=0"
}

# mw_pm_row_js <project> find|open — JS that finds the pending rows for MW_CNAME /
# <project> / MW_WEEK in the PM gallery, and either counts them ('find') or opens the
# ONE such row's review page ('open'). The on-click sits on the gallery item's
# [role=button] child. Never climb from btnPMApprove "while the parent still holds
# one button": with a single pending row that climb reaches <html>.
mw_pm_row_js() {
  printf "%s" "() => { const out=[]; for (const it of document.querySelectorAll('.mx-name-galPMPendingEntries .widget-gallery-item')) { if (!it.querySelector('.mx-name-btnPMApprove')) continue; const t=(it.innerText||'').replace(/\s+/g,' '); if (t.indexOf('$MW_CNAME')>=0 && t.indexOf('$1')>=0 && ($MW_WEEKMATCH)) out.push(it); } if ('$2'==='find') return String(out.length); if (out.length!==1) return 'ambiguous:'+out.length; const c=out[0].querySelector(':scope > [role=button]') || out[0]; c.click(); return 'opened'; }"
}

# mw_pm_dump — every PM pending row, for failure messages.
mw_pm_dump() {
  playwright-cli eval "() => [...document.querySelectorAll('.mx-name-galPMPendingEntries .widget-gallery-item')].map(e=>(e.innerText||'').replace(/\\s+/g,' ').trim().slice(0,160)).join('  ||  ')" 2>/dev/null | _tt_eval_str
}

# mw_pm_load — as the PM, open the dashboard and page the pending gallery in fully.
# A gallery that fails to page is reported, not fatal: the count read after it says
# what is on screen, and the caller decides.
mw_pm_load() {
  tt_login "$MW_PM" "Project Manager Dashboard"
  tt_gallery_load_all ".mx-name-galPMPendingEntries" "PM pending queue" >/dev/null 2>&1 \
    || echo "  (PM pending queue did not page in fully; counting what rendered)"
}

# mw_pm_count <project> — how many PM pending rows are for MW_CNAME / <project> /
# MW_WEEK. Call after mw_pm_load.
mw_pm_count() {
  playwright-cli eval "$(mw_pm_row_js "$1" find)" 2>/dev/null | _tt_eval_str
}

# mw_pm_act <project> approve|reject — open that row's review page
# (Main.ReviewTimesheetEntry) and press Approve, or Reject with MW_COMMENT.
mw_pm_act() {
  local proj="$1" act="$2" n="" r k
  for _ in 1 2 3 4 5 6 7 8; do
    mw_pm_load
    n="$(mw_pm_count "$proj")"
    [ "$n" = "1" ] && break
    sleep 6
  done
  [ "$n" = "1" ] || tt_fail "PM queue: expected exactly one '$MW_CNAME' / '$proj' row for week $MW_WEEK, found [$n]. Rows: $(mw_pm_dump)"
  r="$(playwright-cli eval "$(mw_pm_row_js "$proj" open)" 2>/dev/null | _tt_eval_str)"
  [ "$r" = "opened" ] || tt_fail "could not open the review page for '$proj' ($r)"
  sleep 4
  tt_wait_for ".mx-name-btnReject" "PM review page for '$proj'"
  if [ "$act" = "reject" ]; then
    k="$(playwright-cli eval "() => { const all=[...document.querySelectorAll('.mx-name-txtRejectionComment textarea')]; let k=0; all.forEach((t,i)=>{ if(t.offsetParent!==null) k=i+1; }); return String(k); }" 2>/dev/null | _tt_eval_str)"
    case "$k" in ''|*[!0-9]*|0) tt_fail "the review page shows no rejection comment box" ;; esac
    playwright-cli fill ":nth-match(.mx-name-txtRejectionComment textarea, $k)" "$MW_COMMENT" >/dev/null 2>&1
    tt_commit_focused
    sleep 1
    r="$(playwright-cli eval "() => { const bs=[...document.querySelectorAll('.mx-name-btnReject')].filter(e=>e.offsetParent!==null); if(!bs.length) return 'none'; bs[bs.length-1].click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
    [ "$r" = "ok" ] || tt_fail "no visible Reject button on the review page for '$proj'"
    sleep 4
    tt_clear_dialogs 6 "Reject" >/dev/null 2>&1
  else
    r="$(playwright-cli eval "() => { const bs=[...document.querySelectorAll('.mx-name-btnApprove')].filter(e=>e.offsetParent!==null); if(!bs.length) return 'none'; bs[bs.length-1].click(); return 'ok'; }" 2>/dev/null | _tt_eval_str)"
    [ "$r" = "ok" ] || tt_fail "no visible Approve button on the review page for '$proj'"
    sleep 4
    tt_clear_dialogs 6 "Approve" >/dev/null 2>&1
  fi
}

# mw_goto_week — as the consultant, step the grid forward to MW_WEEK. Returns 1 when
# 16 steps do not reach it.
mw_goto_week() {
  local i
  for i in $(seq 1 16); do
    [ "$(tt_current_week)" = "$MW_WEEK" ] && return 0
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  return 1
}

# mw_ledger — MW_CUSER's ledger for MW_WEEK, retried past a transient read failure.
# Prints whatever the last read gave; the caller rejects ERR:/NOWEEK.
mw_ledger() {
  local out=""
  for _ in 1 2 3; do
    out="$(tt_week_ledger "${1:-$MW_CUSER}" "$MW_WEEK")"
    case "$out" in ERR:*|NOWEEK|'') sleep 3 ;; *) break ;; esac
  done
  printf '%s' "$out"
}

# mw_submit_fresh_week — step 1. Sets MW_WEEK, MW_ROW_KEEP, MW_ROW_REJ. Fatal on any
# precondition that does not hold, because the specs built on it would otherwise
# report the wrong scenario.
mw_submit_fresh_week() {
  local fresh="" i r mon s0
  tt_login "$MW_CUSER" "My Timesheets"
  for i in $(seq 1 14); do
    if [ "$(mw_week_is_fresh)" = "true" ] \
       && [ "$(tt_week_row_of "$MW_KEEP" editable)" != "0" ] \
       && [ "$(tt_week_row_of "$MW_REJ" editable)" != "0" ]; then
      fresh=1; break
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  [ -n "$fresh" ] || tt_fail "no fresh week (actionable, no hours, editable '$MW_KEEP' and '$MW_REJ' rows) in the next 14 weeks for $MW_CUSER"
  MW_WEEK="$(tt_current_week)"
  [ -n "$MW_WEEK" ] || tt_fail "could not read the week caption"
  mw_set_weekmatch
  echo "  week under test: $MW_WEEK"

  MW_ROW_KEEP="$(tt_week_row_of "$MW_KEEP" editable)"
  MW_ROW_REJ="$(tt_week_row_of "$MW_REJ" editable)"
  mw_fill_row "$MW_ROW_KEEP" "$MW_KEEP_H"
  mw_fill_row "$MW_ROW_REJ" "$MW_REJ_H"
  playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
  sleep 3
  tt_clear_dialogs 4 >/dev/null 2>&1
  tt_refetch_week
  [ "$(tt_current_week)" = "$MW_WEEK" ] || tt_fail "the grid left week $MW_WEEK while re-reading it"
  for r in "$MW_ROW_KEEP" "$MW_ROW_REJ"; do
    mon="$(mw_cell "$r" Mon)"
    case "$mon" in ""|0|0.00|0.0) tt_fail "hours did not persist on row $r (Monday reads '$mon') - a zero-hour line skips approval and the scenario would not be the one under test" ;; esac
  done
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  tt_clear_dialogs 8 || tt_fail "submit blocked by a dialog: $TT_DIALOG_BLOCKED"
  sleep 3

  s0="$(mw_ledger)"
  echo "  after submit: $s0"
  [ "$(tt_ledger_status "$s0" "$MW_KEEP")" = "AwaitingManagerApproval" ] \
    || tt_fail "precondition: '$MW_KEEP' should be AwaitingManagerApproval after submit ($s0)"
  [ "$(tt_ledger_status "$s0" "$MW_REJ")" = "AwaitingManagerApproval" ] \
    || tt_fail "precondition: '$MW_REJ' should be AwaitingManagerApproval after submit ($s0)"
}

# mw_pm_decide — step 2: the PM approves MW_KEEP and rejects MW_REJ. Sets MW_S1, the
# ledger read back afterwards (as the consultant, who is signed in on return).
mw_pm_decide() {
  mw_pm_act "$MW_KEEP" approve
  mw_pm_act "$MW_REJ" reject
  tt_login "$MW_CUSER" "My Timesheets"
  MW_S1="$(mw_ledger)"
  echo "  after PM decisions: $MW_S1"
  case "$(tt_ledger_status "$MW_S1" "$MW_KEEP")" in
    ToProcess|AwaitingExport|Exported) ;;
    *) tt_fail "precondition: the PM approval did not move '$MW_KEEP' on ($MW_S1)" ;;
  esac
  [ "$(tt_ledger_status "$MW_S1" "$MW_REJ")" = "Rejected" ] \
    || tt_fail "precondition: the PM rejection did not land on '$MW_REJ' ($MW_S1)"
  [ "$(tt_ledger_status "$MW_S1" WEEK)" = "Rejected" ] \
    || tt_fail "precondition: the week did not turn Rejected after the rejection ($MW_S1)"
}
