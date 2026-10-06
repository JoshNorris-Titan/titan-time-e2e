#!/usr/bin/env bash
# The Monthly Hours report adds up to the timesheets behind it: for every E2E
# consultant and project it shows the hours of each week ending in the month, a
# total equal to those weeks, and "Processed" only when every one was exported.
#
# tt-timeout: 12m
#
# WHY THIS EXISTS. Reports -> Monthly Hours Report (Main.Report_MonthlyHours) is
# what HR and the Titan Manager bill from, and nothing checked a figure on it.
# Main.ACT_Report_MonthlyHours_Run rebuilds it whenever the month, year or a column
# filter changes: it works out the weeks whose Friday falls in the month (Saturday week
# endings, up to five), takes every AssignmentEntry whose timesheet ends in one of
# them and is neither Draft nor Rejected, and sums TotalHours into one row per
# customer x project x consultant, per week. Processed is 'Y' only when every entry
# in the row is Exported.
#
# HOW THE EXPECTATION IS BUILT. Independently, from the data layer: this reads the
# E2E consultants' entries and their timesheets straight from Main.AssignmentEntry /
# Main.Timesheet, applies the rule above against the week-ending dates the report
# itself heads its columns with, and compares row by row. Only rows for the E2E
# consultants are compared - the report covers every consultant on the environment,
# and other people's hours are not this suite's to predict - but in the other
# direction EVERY E2E row the data says should exist must be on the report.
#
# The month is chosen from the data too: the month holding the most qualifying
# E2E entries at the moment this runs (earlier specs in the run submit, approve and
# export plenty). If there are none at all the spec fails rather than comparing
# an empty report with an empty expectation, which would prove nothing.
#
# WHAT IT ASSERTS
#   A. the report opens from the Reports hub and runs for the chosen month;
#   B. each E2E row's WeekN cells equal the data-layer hours for that week, and its
#      Total equals both the data and the sum of its own weeks;
#   C. no expected E2E row is missing, and no E2E row appears that the data does
#      not explain (a Draft or Rejected entry leaking in would do that);
#   D. Processed reads Y exactly when every entry behind the row is Exported;
#   E. the Consultant column header sorts (TT-765): one click marks it tt-sort-asc
#      and orders the rows by consultant ascending, a second marks it tt-sort-desc
#      and orders them descending;
#   F. the Consultant column filter (TT-765, cbFltConsultant) narrows the report to
#      exactly that consultant's rows - as many as B found for them - and clearing
#      it brings every row back;
#   G. Back to Reports returns to the hub.
#
# TT-765 (deployed) REMOVED the "Sort by" dropdown (cbSortOption) this spec used to
# drive. Sorting is now a click on a header (cntHeadCustomer / cntHeadProject /
# cntHeadConsultant -> Main.ACT_Report_MonthlyHours_SortBy, which flips SortAscending
# when the same column is clicked again; DS_Report_MonthlyHours_Rows sorts), and each
# of those columns has a filter in cntFilterRow (cbFltCustomer / cbFltProject /
# cbFltConsultant, on Administration.Account.FullName etc., on-change
# Main.ACT_Report_MonthlyHours_Run). Names read from the deployed page on disk.
#
# NON-DESTRUCTIVE: it creates only the report's own header/row objects, which the
# report deletes and rebuilds on every run.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

MONTHS=(January February March April May June July August September October November December)
CONSULTANTS_JS="$(for c in "E2E Consultant" "E2E Consultant Two" "E2E Consultant Three"; do printf "'%s'," "$c"; done)"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# ENTRIES_JS - a Promise of the qualifying E2E entries as
#   [{c: consultant, p: project, h: hours, s: status, end: timesheet EndDate ms}]
# Two retrieves (entries, then their timesheets by guid), because a client
# retrieve returns references as guids, not the objects behind them.
ENTRIES_JS="new Promise((res, rej) => { const C=[${CONSULTANTS_JS}]; const or=C.map(n=>\"Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '\"+n+\"'\").join(' or '); mx.data.get({ xpath: \"//Main.AssignmentEntry[\"+or+\"][Status != 'Draft'][Status != 'Rejected']\", filter:{amount:2000}, callback: es => { const ag=[...new Set(es.map(e=>e.get('Main.AssignmentEntry_Assignment')).filter(Boolean))]; const tg=[...new Set(es.map(e=>e.get('Main.AssignmentEntry_Timesheet')).filter(Boolean))]; if(!es.length) return res([]); mx.data.get({ guids: ag, callback: as => { const A={}; as.forEach(a=>A[a.getGuid()]=a); mx.data.get({ guids: tg, callback: ts => { const T={}; ts.forEach(t=>T[t.getGuid()]=t); const P={}; const pg=[...new Set(as.map(a=>a.get('Main.Assignment_Project')).filter(Boolean))]; mx.data.get({ guids: pg, callback: ps => { ps.forEach(p=>P[p.getGuid()]=p); res(es.map(e=>{ const a=A[e.get('Main.AssignmentEntry_Assignment')]; const t=T[e.get('Main.AssignmentEntry_Timesheet')]; const p=a&&P[a.get('Main.Assignment_Project')]; return { c: a?a.get('ConsultantName'):'', p: p?p.get('Name'):'', h: Number(e.get('TotalHours')||0), s: e.get('Status'), end: t?Number(t.get('EndDate')||0):0 }; })); }, error: rej }); }, error: rej }); }, error: rej }); }, error: rej }); })"

tt_login "e2e_tm" "Add Customer"

# ------------------------------------------------------------------ choose the month
# The month whose weeks hold the most qualifying entries. A week belongs to the
# month holding its Friday (the day before its Saturday EndDate).
PICK="$(ev "() => ${ENTRIES_JS}.then(E => { const n={}; E.filter(e=>e.end).forEach(e=>{ const f=new Date(e.end - 86400000); const k=f.getFullYear()+'-'+(f.getMonth()+1); n[k]=(n[k]||0)+1; }); const best=Object.entries(n).sort((a,b)=>b[1]-a[1])[0]; return best ? best[0]+'|'+best[1] : 'NONE'; }).catch(e=>'ERR:'+(e&&e.message))")"
case "$PICK" in
  NONE)   tt_fail "no E2E entry is past Draft/Rejected, so there is nothing for the report to add up - run this inside a suite run, after 00-setup and the submitting specs" ;;
  ERR:*|'') tt_fail "could not read the E2E entries from the data layer ($PICK)" ;;
esac
YM="${PICK%%|*}"; YEAR="${YM%%-*}"; MON="${YM#*-}"; MONTH_NAME="${MONTHS[$((MON-1))]}"
note "month: $MONTH_NAME $YEAR (${PICK#*|} qualifying E2E entries)"

# ------------------------------------------------------------------ A. open and run
for _ in 1 2 3; do
  tt_try_click_text "Reports"
  sleep 2
  [ "$(ev "() => String(!!document.querySelector('.mx-name-cardReportMonthlyHours'))")" = "true" ] && break
done
[ "$(ev "() => String(!!document.querySelector('.mx-name-cardReportMonthlyHours'))")" = "true" ] || tt_fail "A: the Reports hub (cardReportMonthlyHours) is not reachable from the menu"
playwright-cli click ".mx-name-cardReportMonthlyHours" >/dev/null 2>&1
tt_wait_for ".mx-name-cbMonth" "the Monthly Hours report (cbMonth)"
tt_combobox_select_text ".mx-name-cbYear" "$YEAR" || tt_fail "A: year $YEAR is not offered"
tt_combobox_select_text ".mx-name-cbMonth" "$MONTH_NAME" || tt_fail "A: month $MONTH_NAME is not offered"
sleep 3

# Read the whole report in one eval: headers, then rows.
#   HEAD|<week1 text>|...          one entry per visible week column
#   ROW|customer|project|consultant|w1|..|w5|total|processed
read_report() {
  ev "() => { const t=s=>(s&&s.innerText||'').replace(/\\s+/g,' ').trim(); const out=['HEAD|'+[1,2,3,4,5].map(i=>t(document.querySelector('.mx-name-lblColWeek'+i))).join('|')]; for (const r of document.querySelectorAll('.mx-name-lstReportRows .mx-name-cntReportRow')) { const g=s=>t(r.querySelector('.mx-name-'+s)); out.push(['ROW',g('txtRowCustomer'),g('txtRowProject'),g('txtRowConsultant'),g('txtRowWeek1'),g('txtRowWeek2'),g('txtRowWeek3'),g('txtRowWeek4'),g('txtRowWeek5'),g('txtRowTotal'),g('txtRowProcessed')].join('|')); } return out.join('~'); }"
}
REPORT="$(read_report)"
HEADS="$(printf '%s' "$REPORT" | tr '~' '\n' | grep '^HEAD|' | head -1)"
note "columns: ${HEADS#HEAD|}"

# ------------------------------------------------------------------ B/C/D. compare with the data
# Build the expected E2E rows in the browser, keyed on the report's own week-ending
# headers ("WeekEnding MM/dd"): an entry lands in the week whose header date is
# within a day of its timesheet's EndDate (a day either way absorbs timezone).
EXPECT="$(ev "() => ${ENTRIES_JS}.then(E => { const H=[1,2,3,4,5].map(i=>{ const e=document.querySelector('.mx-name-lblColWeek'+i); const m=e&&(e.innerText||'').match(/(\\d{1,2})\\/(\\d{1,2})/); return m ? {m:+m[1], d:+m[2]} : null; }); const idx=end=>{ const x=new Date(end); for(let i=0;i<5;i++){ const h=H[i]; if(!h) continue; for (const y of [x.getFullYear()-1,x.getFullYear(),x.getFullYear()+1]) { const hd=new Date(y,h.m-1,h.d).getTime(); if (Math.abs(hd - end) <= 36*3600000) return i; } } return -1; }; const R={}; E.forEach(e=>{ const i=idx(e.end); if(i<0) return; const k=e.p+'|'+e.c; R[k]=R[k]||{w:[0,0,0,0,0],t:0,x:true}; R[k].w[i]+=e.h; R[k].t+=e.h; R[k].x = R[k].x && e.s==='Exported'; }); return Object.keys(R).sort().map(k=>k+'|'+R[k].w.join('|')+'|'+R[k].t+'|'+(R[k].x?'Y':'N')).join('~') || 'NONE'; }).catch(e=>'ERR:'+(e&&e.message))")"
case "$EXPECT" in ERR:*|'') tt_fail "B: could not build the expectation from the data layer ($EXPECT)" ;; esac
[ "$EXPECT" != "NONE" ] || tt_fail "B: no qualifying E2E entry falls in the report's own weeks for $MONTH_NAME $YEAR (headers: ${HEADS#HEAD|}) - the month choice and the report's weeks disagree"

declare -A GOT=()
while IFS= read -r line; do
  case "$line" in ROW\|*) ;; *) continue ;; esac
  IFS='|' read -r _ cu pr co w1 w2 w3 w4 w5 to pz <<< "$line"
  case "$co" in "E2E "*) ;; *) continue ;; esac
  GOT["$pr|$co"]="$cu|$w1|$w2|$w3|$w4|$w5|$to|$pz"
# A trailing newline, or `read` silently drops the last line.
done < <(printf '%s\n' "$REPORT" | tr '~' '\n')

nz() { [ -z "$1" ] && echo 0 || printf '%s' "$1" | tr -d ' ,'; }
eqn() { awk -v a="$(nz "$1")" -v b="$(nz "$2")" 'BEGIN{ exit (a+0==b+0) ? 0 : 1 }'; }
declare -A SEEN=()
while IFS='|' read -r pr co e1 e2 e3 e4 e5 et ex; do
  key="$pr|$co"; SEEN["$key"]=1
  got="${GOT[$key]:-}"
  if [ -z "$got" ]; then bad "C: no report row for $co on $pr, though the data holds $et qualifying hours in $MONTH_NAME"; continue; fi
  IFS='|' read -r cu g1 g2 g3 g4 g5 gt gp <<< "$got"
  rowbad=""
  for i in 1 2 3 4 5; do eval "ew=\$e$i; gw=\$g$i"; eqn "$gw" "$ew" || rowbad="$rowbad week$i=$gw(want $ew)"; done
  eqn "$gt" "$et" || rowbad="$rowbad total=$gt(want $et)"
  own="$(awk -v a="$(nz "$g1")" -v b="$(nz "$g2")" -v c="$(nz "$g3")" -v d="$(nz "$g4")" -v e="$(nz "$g5")" 'BEGIN{print a+b+c+d+e}')"
  eqn "$gt" "$own" || rowbad="$rowbad total=$gt-but-weeks-sum=$own"
  [ "$cu" = "$FX_CUSTOMER" ] || rowbad="$rowbad customer=$cu(want $FX_CUSTOMER)"
  if [ -n "$rowbad" ]; then bad "B: $co / $pr:$rowbad"; else note "B ok: $co / $pr - weeks $g1 $g2 $g3 $g4 $g5, total $gt"; fi
  if [ "$gp" = "$ex" ]; then note "D ok: $co / $pr processed=$gp"; else bad "D: $co / $pr shows Processed '$gp', the data says '$ex' (Y only when every entry is Exported)"; fi
done < <(printf '%s\n' "$EXPECT" | tr '~' '\n')
for key in "${!GOT[@]}"; do
  [ -n "${SEEN[$key]:-}" ] || bad "C: the report has a row for ${key#*|} on ${key%%|*} (${GOT[$key]}) that no qualifying entry explains"
done

# ------------------------------------------------------------------ E. header sort
row_count() { ev "() => String(document.querySelectorAll('.mx-name-lstReportRows .mx-name-cntReportRow').length)"; }
head_class() { ev "() => (document.querySelector('.mx-name-cntHeadConsultant')||{}).className||'__MISSING__'"; }
# consultant_order <asc|desc> - SORTED|<n>|<names> or UNSORTED|<n>|<names>
consultant_order() {
  ev "() => { const n=[...document.querySelectorAll('.mx-name-lstReportRows .mx-name-txtRowConsultant')].map(e=>(e.innerText||'').trim()); const c=(a,b)=>a.toLowerCase().localeCompare(b.toLowerCase()); const ok=n.every((x,i)=>i===0||('$1'==='asc' ? c(n[i-1],x)<=0 : c(n[i-1],x)>=0)); return (ok?'SORTED':'UNSORTED')+'|'+n.length+'|'+n.join(', ').slice(0,300); }"
}
# sort_consultant <asc|desc> - click the Consultant header (at most twice) until its
# class reads tt-sort-<dir>, then wait up to 10 s for the rows to follow.
sort_consultant() {
  local dir="$1" k o=""
  for k in 1 2; do
    case "$(head_class)" in *"tt-sort-$dir"*) break ;; esac
    playwright-cli click ".mx-name-cntHeadConsultant" >/dev/null 2>&1
    sleep 2
  done
  for k in $(seq 1 10); do
    o="$(consultant_order "$dir")"
    case "$o" in SORTED\|0\|*) ;; SORTED*) break ;; esac
    sleep 1
  done
  printf '%s' "$o"
}
TOTAL_ROWS="$(row_count)"
for dir in asc desc; do
  ORDER="$(sort_consultant "$dir")"
  HC="$(head_class)"
  case "$HC" in
    __MISSING__) bad "E: no .mx-name-cntHeadConsultant header to sort by (TT-765)"; break ;;
    *"tt-sort-$dir"*) ;;
    *) bad "E: after clicking the Consultant header it reads class [$HC], not tt-sort-$dir" ;;
  esac
  case "$ORDER" in
    SORTED\|0\|*) bad "E: sorting by consultant ($dir) emptied the report" ;;
    SORTED*)      note "E ok: rows ordered by consultant, $dir (${ORDER#SORTED|})" ;;
    *)            bad "E: header says $dir by consultant, the rows read ${ORDER#UNSORTED|}" ;;
  esac
done

# ------------------------------------------------------------------ F. column filter
# One E2E consultant B found on the report; prefer one whose name is not a prefix of
# another's, though the pick below matches the option text exactly either way.
FCONS=""
for key in "${!GOT[@]}"; do
  c="${key#*|}"
  [ -z "$FCONS" ] && FCONS="$c"
  [ "$c" = "E2E Consultant Two" ] && FCONS="$c"
done
WANT_ROWS=0
for key in "${!GOT[@]}"; do [ "${key#*|}" = "$FCONS" ] && WANT_ROWS=$((WANT_ROWS+1)); done
if [ -z "$FCONS" ]; then
  bad "F: no E2E row on the report to filter to"
else
  PICKED=""
  for _ in $(seq 1 6); do
    if [ "$(ev "() => String(document.querySelectorAll('[role=option]').length)")" = "0" ]; then
      playwright-cli click ".mx-name-cbFltConsultant" >/dev/null 2>&1
      sleep 1
    fi
    PICKED="$(ev "() => { const o=[...document.querySelectorAll('[role=option]')].find(e=>(e.innerText||'').trim()==='$FCONS'); if(o){ o.click(); return 'PICKED'; } return 'NOMATCH:'+[...document.querySelectorAll('[role=option]')].map(e=>(e.innerText||'').trim()).join(', ').slice(0,200); }")"
    [ "$PICKED" = "PICKED" ] && break
    sleep 1
  done
  if [ "$PICKED" != "PICKED" ]; then
    bad "F: cbFltConsultant does not offer '$FCONS' ($PICKED)"
  else
    F=""
    for _ in $(seq 1 15); do
      F="$(ev "() => { const n=[...document.querySelectorAll('.mx-name-lstReportRows .mx-name-txtRowConsultant')].map(e=>(e.innerText||'').trim()); return n.length+'|'+n.filter(x=>x!=='$FCONS').length+'|'+[...new Set(n)].join(', ').slice(0,200); }")"
      case "$F" in 0\|*) ;; *\|0\|*) break ;; esac
      sleep 1
    done
    FN="${F%%|*}"; FO="${F#*|}"; FO="${FO%%|*}"
    if [ "$FN" = "$WANT_ROWS" ] && [ "$FO" = "0" ]; then
      note "F ok: filtered to '$FCONS', the report shows exactly their $FN row(s)"
    else
      bad "F: filtered to '$FCONS' the report shows $FN row(s), $FO of them for someone else (consultants: ${F#*|*|}); B found $WANT_ROWS for them"
    fi
    playwright-cli eval "() => { const b=document.querySelector('.mx-name-cbFltConsultant .widget-combobox-clear-button'); if(b){ b.click(); return 'ok'; } return 'none'; }" >/dev/null 2>&1
    N_BACK=""
    for _ in $(seq 1 15); do N_BACK="$(row_count)"; [ "$N_BACK" = "$TOTAL_ROWS" ] && break; sleep 1; done
    if [ "$N_BACK" = "$TOTAL_ROWS" ]; then
      note "F ok: clearing the filter brought all $TOTAL_ROWS row(s) back"
    else
      bad "F: after clearing the consultant filter the report shows [$N_BACK] row(s), it showed $TOTAL_ROWS before filtering"
    fi
  fi
fi

# ------------------------------------------------------------------ G. back
playwright-cli click ".mx-name-btnBack" >/dev/null 2>&1
BACK=""
for _ in $(seq 1 10); do BACK="$(ev "() => String(!!document.querySelector('.mx-name-cardReportMonthlyHours') && !document.querySelector('.mx-name-cbMonth'))")"; [ "$BACK" = "true" ] && break; sleep 1; done
[ "$BACK" = "true" ] && note "G ok: Back returned to the Reports hub" || bad "G: Back to Reports did not return to the hub"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-report-monthly-hours - $fails problem(s) with the Monthly Hours report for $MONTH_NAME $YEAR."
  exit 1
fi
echo "PASS: verify-report-monthly-hours - every E2E row for $MONTH_NAME $YEAR matches its entries week by week, and header sort, the consultant filter and Back work."
