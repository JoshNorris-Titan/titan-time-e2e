#!/usr/bin/env bash
# tt-timeout: 15m
# verify-tt777-no-processed-email-zero-hours.test.sh
#
# TT-777: HR processing a 0-hour week sends the consultant NO "processed" email; a
# week with hours still sends one.
#
# WHY THIS EXISTS. When HR processes a consultant's week (Main.ACT_AssignmentEntry_
# Process), the consultant - and anyone on their CC list (TT-761) - gets a
# confirmation email with the week's timesheet attached. For a week with no hours
# that mail is noise, so since model fa8f6d17 the flow skips it when the entry's
# TotalHours is empty or 0 and writes one log line instead ("TT-777: no processed
# email sent for ..."). Nothing in the suite looked at the processed email at all.
#
# WHAT THE SUITE CAN SEE. The log line is server-side and unreachable from here.
# The email is not: every message the app composes is an Email_Connector row that
# Core.EmailsSent_Overview lists the moment it is committed (QUEUED, before the
# send event delivers it), and lib/_login_mail.sh searches that list by exact
# recipient. So this counts rows addressed to the consultant before and after each
# Process.
#
# THE CONTROL IS WHAT MAKES THE ABSENCE MEAN SOMETHING. "No new row" also follows
# from a broken mail list, a wrong address or a Process that never ran. So the week
# WITH hours is processed first and must raise exactly the row the 0-hour week must
# not; the 0-hour week is then given at least as long as the control needed, and
# never less than 60 s.
#
# ITS OWN DATA. One throwaway project (no approvals, so a submitted week goes
# straight to Weekly to process) assigned to 'E2E Consultant Three' - in
# TT_E2E_CONSULTANTS, driven by no fixture spec - and two of its weeks, three and
# four weeks ahead (tt780 uses two ahead, tt778 the current one). The deep clear in
# 99-teardown deletes all of it; the project and assignment are archived on exit.
#
# WHAT IT ASSERTS
#   setup (fatal): the two entries are ToProcess at 8.00 h and 0.00 h, and
#     Three's account has an email address;
#   A. control (fatal): processing the 8-hour week adds a mail row to that address;
#   B. processing the 0-hour week adds none, and the entry did leave ToProcess (it
#      was processed, not skipped).
#
# WHAT MAKES IT RED. The TT-777 guard removed or inverted: B sees a new row.
#
# Consumes: one project, one assignment, two processed weeks for E2E Consultant
# Three, one processed-email to Three's address.
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_entries.sh"

STAMP="$(date +%s)"
PQ="E2E TT777 Proc $STAMP"
CNAME="E2E Consultant Three"
CUSER="e2e_consultant3"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

_wk_sun() {
  local today dow
  today="$(TZ=America/Chicago date +%Y-%m-%d)"
  dow="$(TZ=America/Chicago date +%w)"
  LC_ALL=C date -d "$today $(( 7 * $1 - dow )) days" +%Y-%m-%d
}
wk_key() { local s; s="$(_wk_sun "$1")"; printf '%s - %s' "$(LC_ALL=C date -d "$s" +'%b %d')" "$(LC_ALL=C date -d "$s +6 days" +'%b %d')"; }
WA="$(wk_key 3)"   # 8 hours
WB="$(wk_key 4)"   # 0 hours
note "weeks: with hours $WA, without $WB"

archive_all() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),30000); const commit=x=>new Promise((ok,ko)=>mx.data.commit({ mxobj:x, callback:ok, error:ko })); mx.data.get({ xpath: \"$1\", filter:{amount:20}, callback: async o => { if(!o||!o.length){ clearTimeout(t); return res('ERR:notfound'); } try { for (const x of o) { x.set('Archived', true); await commit(x); } clearTimeout(t); res('ok:'+o.length); } catch(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }, error: e => { clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })"
}
cleanup() {
  tt_login "e2e_tm" "Add Customer" >/dev/null 2>&1 || return 0
  archive_all "//Main.Assignment[Main.Assignment_Project/Main.Project/Name = '$PQ']" >/dev/null
  archive_all "//Main.Project[Name = '$PQ']" >/dev/null
  echo "  (archived '$PQ' and its assignment; the teardown clear of '$CNAME' deletes them)"
}
trap cleanup EXIT

goto_week() {
  local want="$1" cur i
  for i in $(seq 1 10); do
    cur="$(tt_current_week)"
    [ "$cur" = "$want" ] && return 0
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  tt_fail "could not reach week $want on $CUSER's timesheet (last shown: '${cur:-?}')"
}

submit_week() {
  playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
  sleep 3
  tt_clear_dialogs 4 >/dev/null 2>&1
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1 || tt_fail "no Submit button on $(tt_current_week)"
  sleep 2
  tt_clear_dialogs 8 || tt_fail "submitting $(tt_current_week) was blocked by a dialog: $TT_DIALOG_BLOCKED"
  sleep 2
}

# mail_count <address> - "processed" rows in Emails Sent addressed to exactly
# <address>. Counted by subject ("Your timesheet has been processed", read on dev
# 2026-10-06), not every row: on dev E2E Consultant Three's address is the shared
# approver mailbox (jnorris+tt@...), so an approval request or a reminder landing
# in B's window would otherwise read as a processed email.
mail_count() {
  local out
  out="$(_tt_mail_lookup "$1")"
  case "$out" in
    EMPTY) echo 0 ;;
    MATCHES:*) printf '%s\n' "$out" | tail -n +2 | grep -ci 'has been processed' ;;
    *) echo "ERR:$out" ;;
  esac
}

# process_week <week-key> - as HR, open Weekly to process, expand that week and
# Process Three's PQ row. Fatal when the row or the Process page is not there.
process_week() {
  local r i
  tt_login "e2e_hr" "$TT_HR_READY" >/dev/null 2>&1
  tt_hr_click_tab "Weekly to process"
  sleep 2
  tt_hr_select_week "$1" || tt_fail "Weekly to process lists no group for $1"
  r="$(tt_hr_row_click "$CNAME" "$PQ" "$TT_HR_BTN_PROCESS")"
  [ "$r" = "ok" ] || tt_fail "no Process button on $CNAME / '$PQ' in $1 ($r)"
  for i in $(seq 1 20); do
    [ "$(ev "() => { const b=document.querySelector('.mx-name-btnProcessConfirm'); if(b && b.offsetParent!==null){ b.click(); return 'ok'; } return 'nf'; }")" = "ok" ] && break
    sleep 2
  done
  [ "$i" -lt 20 ] || tt_fail "the Process page for $CNAME / '$PQ' in $1 never offered btnProcessConfirm"
  sleep 4
  tt_clear_dialogs 3 >/dev/null 2>&1
}

# ------------------------------------------------------------------ own data
tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"
fx_create_project "$PQ" "No" "No" "No"
fx_create_assignment "$CNAME" "$PQ" 40 "$FX_CUSTOMER"

tt_login "$CUSER" "My Timesheets"
goto_week "$WA"
ORD="$(tt_week_row_of "$PQ" editable)"
case "$ORD" in ''|0|*[!0-9]*) tt_fail "no editable '$PQ' row on $WA" ;; esac
tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, $ORD)" "8"
tt_commit_focused
sleep 1
submit_week
goto_week "$WB"
submit_week

tt_login "e2e_hr" "$TT_HR_READY"
LA="$(tt_week_ledger "$CNAME" "$WA")"; LB="$(tt_week_ledger "$CNAME" "$WB")"
[ "$(tt_ledger_status "$LA" "$PQ")" = "ToProcess" ] && [ "$(tt_ledger_hours "$LA" "$PQ")" = "8.00" ] \
  || tt_fail "setup: $WA's '$PQ' entry is not ToProcess at 8.00 h [$LA]"
[ "$(tt_ledger_status "$LB" "$PQ")" = "ToProcess" ] && [ "$(tt_ledger_hours "$LB" "$PQ")" = "0.00" ] \
  || tt_fail "setup: $WB's '$PQ' entry is not ToProcess at 0.00 h [$LB]"

# As the administrator, the same sign-in lib/_login_mail.sh uses for Emails Sent.
tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}"
ADDR="$(tt_authz_readback "//Administration.Account[FullName = '$CNAME']" Email)"
case "$ADDR" in
  *@*) note "$CNAME's address: $ADDR" ;;
  *) tt_fail "setup: could not read an email address for '$CNAME' ([$ADDR]) - there is no inbox to watch" ;;
esac

# ------------------------------------------------------------------ A. control
C0="$(mail_count "$ADDR")"
case "$C0" in ERR:*) tt_fail "could not read Emails Sent for '$ADDR' ($C0)" ;; esac
T0="$(date +%s)"
process_week "$WA"
C1="$C0"
while [ $(( $(date +%s) - T0 )) -lt 180 ]; do
  C1="$(mail_count "$ADDR")"
  case "$C1" in ''|ERR:*) C1="$C0" ;; esac
  [ "$C1" -gt "$C0" ] && break
  sleep 10
done
LATENCY=$(( $(date +%s) - T0 ))
[ "$C1" -gt "$C0" ] || tt_fail "A: processing the 8-hour week raised no mail to '$ADDR' within 180 s, so the absence in B could not mean anything (rows: $C0 -> $C1)"
note "A ok: the 8-hour week's processed email is listed ($C0 -> $C1 rows, ${LATENCY}s)"

# ------------------------------------------------------------------ B. the 0-hour week
WAIT=$(( LATENCY * 2 )); [ "$WAIT" -lt 60 ] && WAIT=60
T1="$(date +%s)"
process_week "$WB"
C2="$C1"
while [ $(( $(date +%s) - T1 )) -lt "$WAIT" ]; do
  sleep 10
  C2="$(mail_count "$ADDR")"
  case "$C2" in ''|ERR:*) C2="$C1" ;; esac
  [ "$C2" -gt "$C1" ] && break
done
if [ "$C2" -gt "$C1" ]; then
  bad "B: processing the 0-hour week sent mail to '$ADDR' ($C1 -> $C2 rows) - TT-777 says a week with no hours gets no processed email"
else
  note "B ok: no mail to '$ADDR' in ${WAIT}s after processing the 0-hour week"
fi
tt_login "e2e_hr" "$TT_HR_READY" >/dev/null 2>&1
LB2="$(tt_week_ledger "$CNAME" "$WB")"
S="$(tt_ledger_status "$LB2" "$PQ")"
if [ "$S" = "ToProcess" ] || [ -z "$S" ]; then
  bad "B: the 0-hour entry reads [${S:-absent}] after Process - it was not processed, so the missing mail proves nothing [$LB2]"
else
  note "B ok: the 0-hour entry was processed (now $S)"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt777-no-processed-email-zero-hours - $fails problem(s) with the processed email for a 0-hour week."
  exit 1
fi
echo "PASS: verify-tt777-no-processed-email-zero-hours - a week with hours sends the processed email and a 0-hour week does not."
