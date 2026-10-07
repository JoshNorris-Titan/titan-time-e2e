#!/usr/bin/env bash
# tt-timeout: 14m
# verify-tt779-zero-hours-one-timesheet.test.sh
#
# HR's "Submit 0-hour entries" on the Pending tab closes the consultant's EXISTING
# week. It does not create a second timesheet for the same week next to it.
#
# WHY THIS EXISTS. On dev (2026-10-06, PR #163's evidence) the button did not find
# the week's existing Main.Timesheet. It created a second one for the same week,
# with fresh 0-hour lines, and left the consultant's own sheet untouched. The two
# StartDates differed by an hour (one consultant-created at 09:00Z, the other at
# 10:00Z), because the week start is computed in each creator's time zone and
# Main.SUB_Pending_EnsureTimesheet / SUB_Pending_GapsForWeek matched the week by
# StartDate EQUALITY. The fix (duplicate-week, Gate 2 approved 2026-10-07) matches
# by a +-3-day window instead, in those two flows and in DS_Timesheet_Get. A second
# sheet is not cosmetic: the consultant's grid and HR's ledgers then each read a
# different one, so hours appear to vanish (verify-tt777 and verify-tt780 read an
# empty week ledger in CI run 37524334459).
#
# ITS OWN DATA. It builds one throwaway project with no approvals and gives it to
# 'E2E Consultant Three' (in TT_E2E_CONSULTANTS, driven by no fixture spec), so the
# deep clear in 99-teardown deletes everything this makes. The assignment and the
# project are also archived on exit. It works on LAST week, which the Pending tab
# lists and no consultant spec uses; it runs after verify-tt779-pending-zero-hours-
# drafts, and its new project gives Three a fresh gap there whatever that spec left.
#
# WHAT IT ASSERTS
#   0. (setup) the consultant opens last week and saves it as a draft, so the
#      consultant's own Main.Timesheet for that week exists; exactly ONE timesheet
#      of Three's starts within that week (+-3 days of its Sunday);
#   A. the Pending tab offers Submit 0-hour entries for Three on that week, and the
#      popup's Submit is accepted;
#   B. afterwards Three still has exactly ONE timesheet for that week - the same
#      guid as before - and this project's entry on it is ToProcess at 0.00 h.
#
# WHAT MAKES IT RED. The equality match: B finds two timesheets for the week (the
# new one created by HR's submit), and lists both StartDates and creators.
#
# RED ON DEV UNTIL THE DUPLICATE-WEEK FIX IS DEPLOYED (model saved 2026-10-07, not
# yet committed or deployed). Expected green after the deploy.
#
# Consumes: one project, one assignment and one 0-hour Weekly-to-process entry for
# E2E Consultant Three, in last week.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_entries.sh"

STAMP="$(date +%s)"
PZ="E2E TT779 One $STAMP"
CNAME="E2E Consultant Three"
CUSER="e2e_consultant3"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# ------------------------------------------------------------------ week arithmetic
# Weeks start on Sunday (en_US), in Central time like the CI browser.
_wk_sun() {
  local today dow
  today="$(TZ=America/Chicago date +%Y-%m-%d)"
  dow="$(TZ=America/Chicago date +%w)"
  LC_ALL=C date -d "$today $(( 7 * $1 - dow )) days" +%Y-%m-%d
}
wk_key()    { local s; s="$(_wk_sun "$1")"; printf '%s - %s' "$(LC_ALL=C date -d "$s" +'%b %d')" "$(LC_ALL=C date -d "$s +6 days" +'%b %d')"; }
wk_starts() { local s; s="$(_wk_sun "$1")"; printf '%s|%s' "$(LC_ALL=C date -d "$s" +'%b %d')" "$(LC_ALL=C date -d "$s" +'%b %-d')"; }
W1="$(wk_key -1)"
SUN="$(_wk_sun -1)"            # YYYY-MM-DD
note "week under test: $W1 (Sunday $SUN)"

archive_all() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),30000); const commit=x=>new Promise((ok,ko)=>mx.data.commit({ mxobj:x, callback:ok, error:ko })); mx.data.get({ xpath: \"$1\", filter:{amount:20}, callback: async o => { if(!o||!o.length){ clearTimeout(t); return res('ERR:notfound'); } try { for (const x of o) { x.set('Archived', true); await commit(x); } clearTimeout(t); res('ok:'+o.length); } catch(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }, error: e => { clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })"
}
cleanup() {
  tt_login "e2e_tm" "Add Customer" >/dev/null 2>&1 || return 0
  archive_all "//Main.Assignment[Main.Assignment_Project/Main.Project/Name = '$PZ']" >/dev/null
  archive_all "//Main.Project[Name = '$PZ']" >/dev/null
  echo "  (archived '$PZ' and its assignment; the teardown clear of '$CNAME' deletes them)"
}
trap cleanup EXIT

# week_sheets - Three's timesheets whose StartDate lies within +-3 days of the week's
# Sunday (00:00 in the BROWSER's zone, i.e. Chicago), as "<guid>@<ISO start>@<status>@<creator>"
# joined by ';', or ERR:<why>. Read as the current session (HR). A window, not an
# equality, because the bug this hunts is two sheets whose starts differ by hours.
week_sheets() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); const p='$SUN'.split('-').map(Number); const sun=new Date(p[0],p[1]-1,p[2]).getTime(); mx.data.get({ xpath: \"//Main.Timesheet[Main.Timesheet_Account/Administration.Account/FullName = '$CNAME']\", filter:{amount:500}, callback: o => { clearTimeout(t); const hit=(o||[]).filter(x=>{ const s=Number(x.get('StartDate')||0); return s && Math.abs(s-sun) < 3*864e5; }); res(hit.map(x=>x.getGuid()+'@'+new Date(Number(x.get('StartDate'))).toISOString()+'@'+(x.get('Status')||'(empty)')+'@'+(x.get('System.owner')||'?')).join(';') || 'NONE'); }, error: e => { clearTimeout(t); res('ERR:'+e.message); } }); } catch(e) { res('ERR:'+e.message); } })"
}
count_of() { case "$1" in NONE) echo 0 ;; *) printf '%s' "$1" | tr ';' '\n' | grep -c . ;; esac; }

goto_week() {
  local want="$1" cur i
  for i in $(seq 1 12); do
    cur="$(tt_current_week)"
    [ "$cur" = "$want" ] && return 0
    playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1
    sleep 2
  done
  tt_fail "could not reach week $want on $CUSER's timesheet (last shown: '${cur:-?}')"
}

pending_select() {
  local starts r
  starts="$(wk_starts "$1")"
  r="$(ev "() => { const want='$starts'.split('|'); const els=[...document.querySelectorAll('.mx-name-galAvailableWeeks .mx-name-txtAvailableWeekRange')]; const el=els.find(e=>{ const t=(e.innerText||'').replace(/\\s+/g,' ').trim(); return want.some(w=>t.indexOf(w+' ')===0 || t.indexOf(w+',')===0 || t===w); }); if(!el) return 'NONE:'+els.map(e=>(e.innerText||'').trim()).slice(0,8).join(' / '); (el.closest('.widget-gallery-item')||el).click(); return 'OK'; }")"
  case "$r" in OK) sleep 3; return 0 ;; *) note "(week list does not offer ${starts%%|*}: ${r#NONE:})"; return 1 ;; esac
}
pending_row() {
  local r i
  for i in $(seq 1 10); do
    r="$(ev "() => { const rows=[...document.querySelectorAll('.mx-name-galPending .mx-name-cardPendingRow')]; const row=rows.find(c=>((c.querySelector('.mx-name-txtPendingConsultant')||{}).innerText||'').trim()==='$CNAME'); if(!row) return 'ABSENT'; return 'offered='+(row.querySelector('.mx-name-btnSubmitZeroHours')?1:0)+' blocked='+(row.querySelector('.mx-name-btnSubmitZeroHoursBlocked')?1:0); }")"
    [ "$r" != "ABSENT" ] && break
    sleep 1
  done
  printf '%s' "$r"
}

# =================================================================== setup
tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"
fx_create_project "$PZ" "No" "No" "No"
fx_create_assignment "$CNAME" "$PZ" 40 "$FX_CUSTOMER"

# The consultant opens last week and saves it: that is the consultant-created sheet.
tt_login "$CUSER" "My Timesheets"
goto_week "$W1"
ORD="$(tt_week_row_of "$PZ" editable)"
case "$ORD" in ''|0|*[!0-9]*) tt_fail "setup: no editable '$PZ' row on $W1 (rows: $(tt_rows_text | cut -c1-200))" ;; esac
playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 || tt_fail "setup: no Save Draft button on $W1"
sleep 3
tt_clear_dialogs 4 >/dev/null 2>&1

tt_login "e2e_hr" "$TT_HR_READY"
BEFORE="$(week_sheets)"
case "$BEFORE" in ERR:*) tt_fail "setup: HR could not read $CNAME's timesheets ($BEFORE)" ;; esac
note "before: $BEFORE"
[ "$(count_of "$BEFORE")" = "1" ] \
  || tt_fail "setup: $CNAME already has $(count_of "$BEFORE") timesheet(s) for $W1 before HR acts [$BEFORE] - expected exactly the one the consultant just saved"
SHEET="${BEFORE%%@*}"

# =================================================================== A. Submit 0 hours
tt_hr_click_tab "Pending"
sleep 2
pending_select -1 || tt_fail "A: the Pending tab does not list $W1, although $CNAME has a 0-hour gap on '$PZ' there"
R="$(pending_row)"
[ "$R" = "offered=1 blocked=0" ] || tt_fail "A: $CNAME's row on $W1 reads [$R]; expected Submit 0-hour entries offered"
ev "() => { const rows=[...document.querySelectorAll('.mx-name-galPending .mx-name-cardPendingRow')]; const row=rows.find(c=>((c.querySelector('.mx-name-txtPendingConsultant')||{}).innerText||'').trim()==='$CNAME'); const b=row && row.querySelector('.mx-name-btnSubmitZeroHours'); if(!b) return 'NOBUTTON'; b.click(); return 'OK'; }" >/dev/null
tt_wait_for ".mx-name-btnConfirmZeroSubmit" "the 0-hour confirmation popup (HR_ConfirmZeroHours)"
playwright-cli click ".mx-name-btnConfirmZeroSubmit" >/dev/null 2>&1
sleep 4
tt_clear_dialogs 4 >/dev/null 2>&1
note "A ok: Submit 0-hour entries offered and confirmed for $CNAME on $W1"

# =================================================================== B. still one sheet
AFTER="$(week_sheets)"
case "$AFTER" in ERR:*) tt_fail "B: HR could not read $CNAME's timesheets afterwards ($AFTER)" ;; esac
note "after: $AFTER"
N="$(count_of "$AFTER")"
if [ "$N" = "1" ] && [ "${AFTER%%@*}" = "$SHEET" ]; then
  note "B ok: $CNAME still has exactly one timesheet for $W1, the consultant's own ($SHEET)"
elif [ "$N" = "1" ]; then
  bad "B: $CNAME has one timesheet for $W1, but it is not the consultant's ($SHEET) - it is [${AFTER%%@*}]"
else
  bad "B: $CNAME has $N timesheets for $W1 after HR's Submit 0-hour entries [$AFTER] - the button created a second sheet for an existing week"
fi
L="$(tt_week_ledger "$CNAME" "$W1")"
if [ "$(tt_ledger_status "$L" "$PZ")" = "ToProcess" ] && [ "$(tt_ledger_hours "$L" "$PZ")" = "0.00" ]; then
  note "B ok: '$PZ' on $W1 is ToProcess at 0.00 h"
else
  bad "B: '$PZ' on $W1 reads [$(tt_ledger_status "$L" "$PZ")] at [$(tt_ledger_hours "$L" "$PZ")] h; expected ToProcess at 0.00 [$L]"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt779-zero-hours-one-timesheet - $fails problem(s): closing an existing week at 0 hours did not keep it to one timesheet."
  exit 1
fi
echo "PASS: verify-tt779-zero-hours-one-timesheet - HR's 0-hour submit closed $CNAME's existing $W1 timesheet without creating a second."
