#!/usr/bin/env bash
# After Submit, the "Timesheet submitted" receipt tells the consultant the truth:
# the week they submitted, the hours they entered, one line per project, and the
# approval route each project's hours actually took.
#
# tt-timeout: 10m
#
# WHY THIS EXISTS. Submitting now ends on a receipt page
# (Main.Consultant_TimesheetSubmitted, opened by Main.ACT_Timesheet_Submit once the
# submit has committed). Every existing spec that submits dismisses it unread -
# tt_clear_dialogs presses its OK like any other confirmation - so nothing checks a
# word of what it says. It is the last thing the consultant reads about their week
# and the only place they are told where each project's hours went next.
#
# The per-project lines come from Main.DS_Timesheet_SubmitSummary, which works the
# route out AGAIN from the project's approval flags, separately from the submit
# itself (Main.ACT_Timesheet_Submit sets each entry's Status from the same flags,
# and TotalHours = 0 overrides both). Two independent computations of one fact is
# exactly what drifts, so assertion F couples each line's route to the status the
# entry really took, read from the data layer.
#
# WHAT IT ASSERTS (e2e_consultant: Manager / Customer / Dual Approval / Line Items)
#   A. the receipt opens after the submit confirmation (containerReceipt);
#   B. txtReceiptWeek names the week that was on the grid when Submit was pressed;
#   C. txtReceiptTotal equals the hours entered, and the sum of the lines;
#   D. one line per project row on the grid - no project missing, none twice;
#   E. each line's hours equal what was typed into that project's row, and its
#      route matches the project's configuration:
#        E2E Manager Approval  (manager only)   -> "Manager approval ..." , no client step
#        E2E Customer Approval (customer only)  -> "Client sign-off ..."
#        the two rows left at 0                 -> "No hours - goes straight to HR export"
#   F. the route is not just words: the newest entry on each of those projects is
#      AwaitingManagerApproval / AwaitingCustomerApproval / ToProcess respectively,
#      and was submitted by this run;
#   G. OK closes the receipt and leaves the consultant on the SAME week, now locked
#      (no Submit button).
#
# Consumes: one fresh week of e2e_consultant, submitted (the bookend clear removes
# it). The Manager Approval entry lands in e2e_pm's pending queue and the Customer
# Approval entry awaits the customer, as every other submitting spec's do.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_rejection.sh"
source "$TT_ROOT/lib/_fixtures.sh"

CUSER="e2e_consultant"
P_MGR="E2E Manager Approval"
P_CUST="E2E Customer Approval"
# Values chosen so no total can be mistaken for another: 5 x 6 = 30 and 2 x 2 = 4.
MGR_DAY=6
CUST_DAY=2
WANT_MGR=30
WANT_CUST=4
WANT_TOTAL=34
ZERO_ROUTE="No hours - goes straight to HR export"
T0_MS="$(( $(date +%s) * 1000 - 60000 ))"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
num()  { printf '%s' "$1" | tr -d ' ,' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1; }
eqn()  { awk -v a="$1" -v b="$2" 'BEGIN{ exit (a+0==b+0) ? 0 : 1 }'; }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# newest_entry <project> - "<Status>|<SubmittedDT ms>" of this consultant's most
# recently submitted entry on <project>, or ERR:<why>.
newest_entry() {
  local xp="//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Name = '$1'][Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Account/Administration.Account/Name = '$CUSER'][SubmittedDT != empty]"
  ev "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$xp\", filter:{ amount: 1, sort: [['SubmittedDT','desc']] }, callback: function(o){ clearTimeout(t); if(!o||!o.length) return res('ERR:none'); res(String(o[0].get('Status'))+'|'+String(o[0].get('SubmittedDT'))); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e) { res('ERR:'+e.message); } })"
}

tt_login "$CUSER" "My Timesheets"
tt_goto_fresh_week "$P_MGR" >/dev/null || tt_fail "no fresh, actionable week was reachable for '$CUSER'"
GRID_WEEK="$(tt_current_week)"
[ -n "$GRID_WEEK" ] || tt_fail "could not read the week on the grid (txtWeekRange)"

# The project names on the grid, one per row, in row order. The receipt must list
# exactly these.
# Each row is identified by which fixture project name its own container holds
# (the same one-row containment tt_week_row_of uses); the fixture names are not
# substrings of one another. A row matching none reads '?', which fails D loudly.
KNOWN_JS="$(for r in "${FX_PROJECTS[@]}"; do printf "'%s'," "${r%%|*}"; done)"
GRID_PROJECTS="$(ev "() => { const K=[${KNOWN_JS}]; const mons=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; return mons.map(m=>{ let el=m; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('.mx-name-txtDayMon').length!==1) break; const t=(el.innerText||''); const hit=K.find(n=>t.indexOf(n)>=0); if(hit) return hit; } return '?'; }).join('~'); }")"
note "week $GRID_WEEK, rows: ${GRID_PROJECTS//\~/, }"

R_MGR="$(tt_week_row_of "$P_MGR" editable)"
R_CUST="$(tt_week_row_of "$P_CUST" editable)"
{ [ -n "$R_MGR" ] && [ "$R_MGR" != "0" ]; }   || tt_fail "no editable '$P_MGR' row in week $GRID_WEEK"
{ [ -n "$R_CUST" ] && [ "$R_CUST" != "0" ]; } || tt_fail "no editable '$P_CUST' row in week $GRID_WEEK"
ROWS="$(ev "() => String(document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon').length)")"
case "$ROWS" in ''|*[!0-9]*) tt_fail "could not count the grid rows (read: [$ROWS])" ;; esac
[ "$ROWS" -ge 3 ] || tt_fail "week $GRID_WEEK shows $ROWS row(s); this test needs at least one row left at zero hours beside the two it fills, or the zero-hours route is never exercised"

for d in Mon Tues Wed Thurs Fri; do
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${R_MGR})" "$MGR_DAY"
done
for d in Mon Tues; do
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${R_CUST})" "$CUST_DAY"
done
tt_commit_focused
sleep 1

# Save first and prove the hours reached the server, for the reason
# tt_consultant_submit_project_row gives: typed values that never commit submit as
# 0 hours, which routes straight to HR and would make every route assertion lie.
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
sleep 3
tt_clear_dialogs 4 >/dev/null 2>&1
tt_refetch_week
[ "$(tt_current_week)" = "$GRID_WEEK" ] || tt_fail "re-reading the week landed on $(tt_current_week), not $GRID_WEEK"
MON_MGR="$(ev "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$R_MGR - 1]||{}).value||'')")"
MON_CUST="$(ev "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$R_CUST - 1]||{}).value||'')")"
{ eqn "$(num "$MON_MGR")" "$MGR_DAY" && eqn "$(num "$MON_CUST")" "$CUST_DAY"; } \
  || tt_fail "the saved draft did not keep the hours (Monday reads '$MON_MGR' on $P_MGR, '$MON_CUST' on $P_CUST) - submitting now would test a zero-hour week"

# --------------------------------------------------------------------- submit
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
tt_wait_for ".mx-name-btnConfirmSubmit" "the Submit timesheet? confirmation (btnConfirmSubmit)"
playwright-cli click ".mx-name-btnConfirmSubmit" >/dev/null 2>&1

# ------------------------------------------------------------------ A. receipt
up=""
for _ in $(seq 1 20); do
  up="$(ev "() => String(!!document.querySelector('.mx-name-containerReceipt'))")"
  [ "$up" = "true" ] && break
  sleep 1
done
[ "$up" = "true" ] || tt_fail "A: no receipt (containerReceipt) within 20s of confirming the submit. Dialog on screen: $(ev "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\\s+/g,' ').slice(0,160) : '(none)'; }")"
note "A ok: the receipt opened"

# One read of the whole receipt: "WEEK|TOTAL" then one "project|hours-text|route" per line.
REC="$(ev "() => { const r=document.querySelector('.mx-name-containerReceipt'); const g=s=>{ const e=r.querySelector('.mx-name-'+s); return e ? (e.innerText||'').replace(/\\s+/g,' ').trim() : ''; }; const out=[g('txtReceiptWeek')+'|'+g('txtReceiptTotal')]; for (const l of r.querySelectorAll('.mx-name-lstReceiptProjects .mx-name-containerReceiptLine')) { const p=(l.querySelector('.mx-name-txtReceiptLineProject')||{}).innerText||''; const ro=(l.querySelector('.mx-name-txtReceiptLineRoute')||{}).innerText||''; const m=p.replace(/\\s+/g,' ').trim().match(/^(.*?)\\s+\\u2014\\s+(.*)\$/); out.push((m?m[1]:p.trim())+'|'+(m?m[2]:'')+'|'+ro.replace(/\\s+/g,' ').trim()); } return out.join('~'); }")"
IFS='~' read -r -a PARTS <<< "$REC"
HEAD="${PARTS[0]:-}"
REC_WEEK_RAW="${HEAD%%|*}"
REC_TOTAL_RAW="${HEAD#*|}"
LINES=("${PARTS[@]:1}")

# ------------------------------------------------------------------ B. week
REC_WEEK="$(tt_week_key "$REC_WEEK_RAW")"
if [ -n "$REC_WEEK" ] && [ "$REC_WEEK" = "$GRID_WEEK" ]; then
  note "B ok: the receipt names the submitted week ('$REC_WEEK_RAW')"
else
  bad "B: the receipt names week '$REC_WEEK_RAW' (key '$REC_WEEK'), but the week submitted was $GRID_WEEK"
fi

# ------------------------------------------------------------------ C. total
REC_TOTAL="$(num "$REC_TOTAL_RAW")"
LINE_SUM="$(for l in "${LINES[@]}"; do IFS='|' read -r _ h _ <<< "$l"; num "$h"; echo; done | awk 'NF{s+=$1} END{print s+0}')"
if [ -n "$REC_TOTAL" ] && eqn "$REC_TOTAL" "$WANT_TOTAL"; then
  note "C ok: total reads '$REC_TOTAL_RAW', the $WANT_TOTAL hours entered"
else
  bad "C: txtReceiptTotal reads '$REC_TOTAL_RAW'; $WANT_TOTAL hours were entered ($WANT_MGR on $P_MGR + $WANT_CUST on $P_CUST)"
fi
eqn "$LINE_SUM" "${REC_TOTAL:-0}" || bad "C: the project lines add up to $LINE_SUM, but the receipt's total says '$REC_TOTAL_RAW'"

# ------------------------------------------------------------------ D. one line per project
GRID_SORTED="$(printf '%s\n' "${GRID_PROJECTS//\~/$'\n'}" | sort)"
LINE_SORTED="$(for l in "${LINES[@]}"; do printf '%s\n' "${l%%|*}"; done | sort)"
if [ "${#LINES[@]}" -eq "$ROWS" ] && [ "$GRID_SORTED" = "$LINE_SORTED" ]; then
  note "D ok: ${#LINES[@]} lines, one per project row on the grid"
else
  bad "D: the receipt lists [$(echo $LINE_SORTED | tr '\n' ',')] (${#LINES[@]} lines) for a grid of $ROWS rows [$(echo $GRID_SORTED | tr '\n' ',')]"
fi

# ------------------------------------------------------------------ E. hours and route per line
ZERO_PROJECTS=()
for l in "${LINES[@]}"; do
  IFS='|' read -r p h ro <<< "$l"
  hv="$(num "$h")"
  case "$p" in
    "$P_MGR")
      eqn "${hv:-x}" "$WANT_MGR" || bad "E: '$p' shows '$h' on the receipt; $WANT_MGR were entered"
      case "$ro" in
        "Manager approval"*"client"*) bad "E: '$p' needs manager approval only, but its route reads '$ro'" ;;
        "Manager approval"*)          note "E ok: $p - $h - $ro" ;;
        *)                            bad "E: '$p' needs manager approval, but its route reads '$ro'" ;;
      esac ;;
    "$P_CUST")
      eqn "${hv:-x}" "$WANT_CUST" || bad "E: '$p' shows '$h' on the receipt; $WANT_CUST were entered"
      case "$ro" in
        "Client sign-off"*) note "E ok: $p - $h - $ro" ;;
        *)                  bad "E: '$p' needs customer approval only, but its route reads '$ro'" ;;
      esac ;;
    *)
      ZERO_PROJECTS+=("$p")
      eqn "${hv:-x}" 0 || bad "E: '$p' was left empty but the receipt shows '$h'"
      if [ "$ro" = "$ZERO_ROUTE" ]; then note "E ok: $p - $h - $ro"; else bad "E: '$p' had no hours, so its route should read '$ZERO_ROUTE', not '$ro'"; fi ;;
  esac
done

# ------------------------------------------------------------------ F. the route really happened
check_status() {
  local proj="$1" want="$2" got st ts
  got="$(newest_entry "$proj")"
  case "$got" in
    ERR:*) bad "F: could not read the newest '$proj' entry ($got)"; return ;;
  esac
  st="${got%%|*}"; ts="${got#*|}"
  case "$ts" in ''|*[!0-9]*) bad "F: '$proj' entry has no readable SubmittedDT ([$ts])"; return ;; esac
  if [ "$ts" -lt "$T0_MS" ]; then
    bad "F: the newest submitted '$proj' entry predates this run (SubmittedDT $ts < $T0_MS) - this submit did not reach it"
  elif [ "$st" = "$want" ]; then
    note "F ok: '$proj' entry is $st"
  else
    bad "F: the receipt told the consultant one route, but the '$proj' entry is $st (expected $want)"
  fi
}
check_status "$P_MGR"  "AwaitingManagerApproval"
check_status "$P_CUST" "AwaitingCustomerApproval"
[ "${#ZERO_PROJECTS[@]}" -gt 0 ] && check_status "${ZERO_PROJECTS[0]}" "ToProcess"

# ------------------------------------------------------------------ G. OK
playwright-cli click ".mx-name-btnReceiptOk" >/dev/null 2>&1
gone=""
for _ in $(seq 1 10); do
  gone="$(ev "() => String(!document.querySelector('.mx-name-containerReceipt'))")"
  [ "$gone" = "true" ] && break
  sleep 1
done
if [ "$gone" != "true" ]; then
  bad "G: the receipt is still open after OK"
else
  sleep 2
  AFTER_WEEK="$(tt_current_week)"
  LOCKED="$(tt_week_actionable)"
  if [ "$AFTER_WEEK" = "$GRID_WEEK" ] && [ "$LOCKED" = "false" ]; then
    note "G ok: OK returned to week $AFTER_WEEK, which no longer offers Submit"
  else
    bad "G: after OK the grid shows week '$AFTER_WEEK' (submitted: $GRID_WEEK) and actionable=$LOCKED (expected false)"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-submit-receipt - $fails problem(s) with the submit receipt for week $GRID_WEEK."
  exit 1
fi
echo "PASS: verify-submit-receipt - the receipt for $GRID_WEEK shows $WANT_TOTAL hours, one line per project, and the route each one really took."
