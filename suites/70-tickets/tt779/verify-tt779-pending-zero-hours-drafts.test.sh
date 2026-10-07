#!/usr/bin/env bash
# tt-timeout: 20m
# verify-tt779-pending-zero-hours-drafts.test.sh
#
# TT-779: HR's "Submit 0-hour entries" on the Pending tab also closes DRAFTS, says
# which projects are new and which drafts it is zeroing on separate lines, and
# still never touches a rejection.
#
# WHY THIS EXISTS. Nothing in the suite touched the Pending tab's btnSubmitZeroHours
# or its popup (Main.HR_ConfirmZeroHours) before this file. TT-779 (model cade64ac,
# Gate-4 follow-ups bc824e50) changed three things there:
#   1. a week whose ONLY gap is a draft now offers the button (it was blocked:
#      the visibility rule was MissingEntryCount > 0 alone; it is now
#      MissingEntryCount + DraftEntryCount > 0);
#   2. Submit zeroes and submits drafts as well as creating the missing entries
#      (Main.ACT_Pending_SubmitZeroHours, "Never submitted?" branch) -- including a
#      draft the consultant had typed hours into;
#   3. the popup lists new entries (txtConfirmZeroMissing) and zeroed drafts
#      (txtConfirmZeroDrafts) as their own sentences above the explanation
#      (txtConfirmZeroBody) -- it used to run together: "...for: InternalThis
#      submits 0 hours...".
# Rejections are unchanged: never zeroed, and a week whose only gap is a rejection
# still shows the inert look-alike btnSubmitZeroHoursBlocked instead.
#
# ITS OWN DATA. Closing a week at 0 hours is irreversible and lands entries in
# Weekly to process, so this never touches a fixture consultant. It builds three
# throwaway projects and gives them to 'E2E Consultant Three' -- in
# TT_E2E_CONSULTANTS, driven by no other spec (lib/_fixtures.sh) -- so the deep
# clear in 99-teardown deletes the assignments, the projects and every entry this
# makes. The assignments are also archived on exit, for a run that never reaches
# teardown. It works only in PAST weeks (the Pending tab lists last week and
# earlier, Core.CONST_PendingLookbackWeeks back), which no consultant spec uses.
# It sits in 70-tickets, after tt683's month exports, so its 0-hour Weekly-to-process
# rows exist only for 75-export onward, whose specs scope to their own consultant.
#
# THE THREE WEEKS (W1 = last week, W2 = two weeks ago, W3 = three weeks ago)
#   P1 "E2E TT779 Mgr <epoch>"   manager approval Yes  - from the fixture window start
#   P2 "E2E TT779 Free <epoch>"  no approvals          - from the fixture window start
#   P3 "E2E TT779 Late <epoch>"  no approvals          - created AFTER Three drafted W1,
#                                                        starting on W1's Sunday
#   W3  Three opens it and saves a draft with 4 h on P1   -> drafts only (P1 4 h, P2 0 h)
#   W2  Three submits 8 h on P1, HR rejects it            -> rejection only (P2 went to
#                                                            Weekly to process at 0 h)
#   W1  Three opens it and saves a draft with 6 h on P1,  -> drafts + missing
#       then P3 is created, so W1 has no P3 entry
#
# WHAT IT ASSERTS
#   A. W3 (drafts only): btnSubmitZeroHours is OFFERED (TT-779 #1); the popup lists
#      the drafts, not a missing line; Cancel leaves the drafts exactly as they were.
#   B. W1 (drafts + missing): the popup's missing sentence names P3, its drafts
#      sentence names "P1 (6 h)" and P2, each ends with a full stop, and the
#      explanation starts BELOW them, not on their line (TT-779 #3).
#   C. W1 Submit: the message reads "Submitted N 0-hour entr(ies) for E2E Consultant
#      Three: M new, K draft(s) zeroed." with K = every draft W1 held (2 on a clean
#      run), M >= 1 and N = M + K, and the data layer then holds P1, P2 and P3 at
#      ToProcess with 0.00 hours (TT-779 #2 -- the 6 h are gone).
#   D. W2 (rejection only): the row shows btnSubmitZeroHoursBlocked and no
#      btnSubmitZeroHours, and the rejected P1 entry is still Rejected.
#
# WHAT MAKES IT RED. The old visibility rule (A: blocked), the old submit that left
# drafts alone (C: P1/P2 still Draft with 6.00/0.00, message without the draft
# count), the old popup text (B: no drafts sentence, or the body on the same line),
# or a submit that ever offers to close a rejection (D).
#
# Consumes: three projects and three assignments for E2E Consultant Three, one
# manager rejection, and eight 0-hour Weekly-to-process entries in past weeks.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"
source "$TT_ROOT/lib/_authz.sh"
source "$TT_ROOT/lib/_entries.sh"
source "$TT_ROOT/lib/_rejection.sh"

STAMP="$(date +%s)"
P1="E2E TT779 Mgr $STAMP"
P2="E2E TT779 Free $STAMP"
P3="E2E TT779 Late $STAMP"
CNAME="E2E Consultant Three"
CUSER="e2e_consultant3"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }
ev()   { playwright-cli eval "$1" 2>/dev/null | _tt_eval_str; }

# ------------------------------------------------------------------ week arithmetic
# Weeks start on Sunday in the app's (en_US) calendar, in Central time like the CI
# browser. wk_key <offset> -> the tt_week_key of the week <offset> weeks from this
# one; wk_starts <offset> -> "Mmm DD|Mmm D", the two ways a label can begin.
_wk_sun() {
  local today dow
  today="$(TZ=America/Chicago date +%Y-%m-%d)"
  dow="$(TZ=America/Chicago date +%w)"
  LC_ALL=C date -d "$today $(( 7 * $1 - dow )) days" +%Y-%m-%d
}
wk_key()    { local s; s="$(_wk_sun "$1")"; printf '%s - %s' "$(LC_ALL=C date -d "$s" +'%b %d')" "$(LC_ALL=C date -d "$s +6 days" +'%b %d')"; }
wk_starts() { local s; s="$(_wk_sun "$1")"; printf '%s|%s' "$(LC_ALL=C date -d "$s" +'%b %d')" "$(LC_ALL=C date -d "$s" +'%b %-d')"; }
wk_date()   { LC_ALL=C date -d "$(_wk_sun "$1")" +%m/%d/%Y; }

W1="$(wk_key -1)"; W2="$(wk_key -2)"; W3="$(wk_key -3)"
note "weeks: W1=$W1  W2=$W2  W3=$W3"

# archive_all <xpath> - set Archived=true on every match, as a Boolean (tt_authz_write
# sets a string), committing one object at a time.
archive_all() {
  ev "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),30000); const commit=x=>new Promise((ok,ko)=>mx.data.commit({ mxobj:x, callback:ok, error:ko })); mx.data.get({ xpath: \"$1\", filter:{amount:20}, callback: async o => { if(!o||!o.length){ clearTimeout(t); return res('ERR:notfound'); } try { for (const x of o) { x.set('Archived', true); await commit(x); } clearTimeout(t); res('ok:'+o.length); } catch(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }, error: e => { clearTimeout(t); res('ERR:retrieve-'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })"
}

# The ASSIGNMENTS are archived as well as the projects: an unarchived assignment
# keeps giving Three a row (and, in past weeks, a Pending gap) whatever its
# project's flag says, which the tt780 spec after this one would trip over.
cleanup() {
  tt_login "e2e_tm" "Add Customer" >/dev/null 2>&1 || return 0
  local p
  for p in "$P1" "$P2" "$P3"; do
    archive_all "//Main.Assignment[Main.Assignment_Project/Main.Project/Name = '$p']" >/dev/null
    archive_all "//Main.Project[Name = '$p']" >/dev/null
  done
  echo "  (archived the TT779 projects and assignments; the teardown clear of '$CNAME' deletes them)"
}
trap cleanup EXIT

# ------------------------------------------------------------------ consultant helpers
# goto_week <key> — step the consultant grid back from wherever it opens until it
# shows <key>. Fatal if it never does: every later step would act on the wrong week.
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

# set_monday <project> <hours> — type <hours> into <project>'s Monday and commit.
set_monday() {
  local ord
  ord="$(tt_week_row_of "$1" editable)"
  case "$ord" in ''|0|*[!0-9]*) tt_fail "no editable '$1' row on $(tt_current_week) (rows: $(tt_rows_text | cut -c1-200))" ;; esac
  tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, $ord)" "$2"
  tt_commit_focused
  sleep 1
}

save_draft() {
  playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1 || tt_fail "no Save Draft button on $(tt_current_week)"
  sleep 3
  tt_clear_dialogs 4 >/dev/null 2>&1
}

# ------------------------------------------------------------------ HR Pending helpers
# pending_select <offset> — pick that week in the Pending tab's week list. Returns 1
# when the list does not offer it (a week with no gap for anyone is not listed).
pending_select() {
  local starts r
  starts="$(wk_starts "$1")"
  r="$(ev "() => { const want='$starts'.split('|'); const els=[...document.querySelectorAll('.mx-name-galAvailableWeeks .mx-name-txtAvailableWeekRange')]; const el=els.find(e=>{ const t=(e.innerText||'').replace(/\\s+/g,' ').trim(); return want.some(w=>t.indexOf(w+' ')===0 || t.indexOf(w+',')===0 || t===w); }); if(!el) return 'NONE:'+els.map(e=>(e.innerText||'').trim()).slice(0,8).join(' / '); (el.closest('.widget-gallery-item')||el).click(); return 'OK'; }")"
  case "$r" in
    OK) sleep 3; return 0 ;;
    *) note "(week list does not offer ${starts%%|*}: ${r#NONE:})"; return 1 ;;
  esac
}

# pending_row — Three's row on the selected week: "ABSENT", or
# "offered=<0|1> blocked=<0|1>". Polled: the gallery reloads after a week click.
pending_row() {
  local r i
  for i in $(seq 1 10); do
    r="$(ev "() => { const rows=[...document.querySelectorAll('.mx-name-galPending .mx-name-cardPendingRow')]; const row=rows.find(c=>((c.querySelector('.mx-name-txtPendingConsultant')||{}).innerText||'').trim()==='$CNAME'); if(!row) return 'ABSENT'; return 'offered='+(row.querySelector('.mx-name-btnSubmitZeroHours')?1:0)+' blocked='+(row.querySelector('.mx-name-btnSubmitZeroHoursBlocked')?1:0); }")"
    [ "$r" != "ABSENT" ] && break
    sleep 1
  done
  printf '%s' "$r"
}

pending_open_popup() {
  ev "() => { const rows=[...document.querySelectorAll('.mx-name-galPending .mx-name-cardPendingRow')]; const row=rows.find(c=>((c.querySelector('.mx-name-txtPendingConsultant')||{}).innerText||'').trim()==='$CNAME'); const b=row && row.querySelector('.mx-name-btnSubmitZeroHours'); if(!b) return 'NOBUTTON'; b.click(); return 'OK'; }" >/dev/null
  tt_wait_for ".mx-name-btnConfirmZeroSubmit" "the 0-hour confirmation popup (HR_ConfirmZeroHours)"
}

# popup_facts — "missing=<text>|drafts=<text>|bodyBelow=<yes|no|n/a>", '-' for an
# absent sentence. bodyBelow compares the explanation's top edge with the bottom of
# the last sentence above it: the run-together bug put them on one line.
popup_facts() {
  ev "() => { const g=n=>document.querySelector('.mx-name-'+n); const t=e=>e?(e.innerText||'').replace(/\\s+/g,' ').trim():'-'; const m=g('txtConfirmZeroMissing'), d=g('txtConfirmZeroDrafts'), b=g('txtConfirmZeroBody'); const last=[m,d].filter(Boolean).pop(); let below='n/a'; if(b&&last){ below = b.getBoundingClientRect().top >= last.getBoundingClientRect().bottom - 1 ? 'yes' : 'no'; } return 'missing='+t(m)+'|drafts='+t(d)+'|bodyBelow='+below; }"
}

# dialog_text — the live message dialog's text, polled until it says something.
dialog_text() {
  local d r i
  d="$(_tt_dialog_js)"
  for i in $(seq 1 15); do
    r="$(ev "() => { const x=$d; return x ? (x.innerText||'').replace(/\\s+/g,' ').trim() : ''; }")"
    case "$r" in *Submitted*|*"no missing"*) break ;; esac
    sleep 1
  done
  printf '%s' "$r"
}

# =================================================================== setup
tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"
fx_create_project "$P1" "Yes" "No" "No"
fx_create_project "$P2" "No" "No" "No"
fx_create_assignment "$CNAME" "$P1" 40 "$FX_CUSTOMER"
fx_create_assignment "$CNAME" "$P2" 40 "$FX_CUSTOMER"

tt_login "$CUSER" "My Timesheets"
# Newest first, because goto_week only steps back. Opening a week runs
# Main.SUB_Timesheet_SyncAssignments, which gives every active assignment a Draft
# entry - that is what makes P1 and P2 drafts below.
# W1 - drafts: 6 h on P1, P2 at 0.
goto_week "$W1"
set_monday "$P1" 6
save_draft
# W2 - submit 8 h on P1 (manager approval) and 0 on P2, then HR rejects P1.
goto_week "$W2"
set_monday "$P1" 8
save_draft
playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1 || tt_fail "no Submit button on $W2"
sleep 2
tt_clear_dialogs 8 || tt_fail "submitting $W2 was blocked by a dialog: $TT_DIALOG_BLOCKED"
sleep 2
# W3 - drafts only: 4 h on P1, P2 left at 0.
goto_week "$W3"
set_monday "$P1" 4
save_draft

TT_REJECT_WEEK="$W2" tt_hr_reject_project "$CNAME" "$P1" "Manager approval" "E2E TT-779 rejection-only week" \
  || tt_fail "setup: could not reject '$P1' for $CNAME in $W2 from the Manager approval tab"

# P3 arrives after W1 was drafted and starts on W1's Sunday: missing in W1, not
# active in W2 or W3.
tt_login "e2e_tm" "Add Customer"
fx_view "cardProjects" "galProjects"
fx_create_project "$P3" "No" "No" "No"
FX_START_DATE="$(wk_date -1)" fx_create_assignment "$CNAME" "$P3" 40 "$FX_CUSTOMER"

# What the data layer holds before HR acts - the baseline every assertion compares to.
tt_login "e2e_hr" "$TT_HR_READY"
L3="$(tt_week_ledger "$CNAME" "$W3")"; L2="$(tt_week_ledger "$CNAME" "$W2")"; L1="$(tt_week_ledger "$CNAME" "$W1")"
note "before: W3 [$L3]"
note "before: W2 [$L2]"
note "before: W1 [$L1]"
[ "$(tt_ledger_status "$L3" "$P1")" = "Draft" ] && [ "$(tt_ledger_hours "$L3" "$P1")" = "4.00" ] \
  || tt_fail "setup: W3's '$P1' entry is not a 4.00 h draft [$L3]"
[ "$(tt_ledger_status "$L1" "$P1")" = "Draft" ] && [ "$(tt_ledger_hours "$L1" "$P1")" = "6.00" ] \
  || tt_fail "setup: W1's '$P1' entry is not a 6.00 h draft [$L1]"
[ -z "$(tt_ledger_status "$L1" "$P3")" ] || tt_fail "setup: W1 already has a '$P3' entry, so there is no missing line to test [$L1]"
[ "$(tt_ledger_status "$L2" "$P1")" = "Rejected" ] || tt_fail "setup: W2's '$P1' entry is not Rejected [$L2]"
case "$(tt_ledger_status "$L2" "$P2")" in Draft|'(empty)'|'') tt_fail "setup: W2's '$P2' entry was not submitted, so W2 is not rejection-only [$L2]" ;; esac

tt_hr_click_tab "Pending"
sleep 2

# =================================================================== A. W3, drafts only
if pending_select -3; then
  R="$(pending_row)"
  case "$R" in
    "offered=1 blocked=0")
      note "A ok: a week whose only gap is drafts offers Submit 0-hour entries"
      pending_open_popup
      F="$(popup_facts)"
      case "$F" in
        missing=-\|drafts=*"$P1 (4 h)"*"$P2"*|missing=-\|drafts=*"$P2"*"$P1 (4 h)"*) note "A ok: popup lists the drafts only [$F]" ;;
        *) bad "A: popup for a drafts-only week reads [$F]; expected no missing line and drafts naming '$P1 (4 h)' and '$P2'" ;;
      esac
      playwright-cli click ".mx-name-btnConfirmZeroCancel" >/dev/null 2>&1
      sleep 2
      A3="$(tt_week_ledger "$CNAME" "$W3")"
      if [ "$A3" = "$L3" ]; then note "A ok: Cancel left W3 untouched"; else bad "A: Cancel changed W3: before [$L3] after [$A3]"; fi
      ;;
    *) bad "A: $CNAME's drafts-only row on $W3 reads [$R]; expected the button offered (offered=1 blocked=0). Before TT-779 a draft-only week was blocked." ;;
  esac
else
  bad "A: the Pending tab does not list $W3 at all, although $CNAME has two drafts there"
fi

# =================================================================== B/C. W1, drafts + missing
if pending_select -1; then
  R="$(pending_row)"
  if [ "$R" = "offered=1 blocked=0" ]; then
    pending_open_popup
    F="$(popup_facts)"
    MISS="${F#missing=}"; MISS="${MISS%%|drafts=*}"
    DRFT="${F#*|drafts=}"; DRFT="${DRFT%%|bodyBelow=*}"
    BELOW="${F##*bodyBelow=}"
    case "$MISS" in
      "New 0-hour entries will be created for: "*"$P3"*.) note "B ok: missing sentence [$MISS]" ;;
      *) bad "B: missing sentence reads [$MISS]; expected 'New 0-hour entries will be created for: ...$P3.'" ;;
    esac
    case "$DRFT" in
      "Drafts that will be zeroed out and submitted: "*.)
        case "$DRFT" in *"$P1 (6 h)"*) ;; *) bad "B: drafts sentence does not name '$P1 (6 h)': [$DRFT]" ;; esac
        case "$DRFT" in *"$P2"*) ;; *) bad "B: drafts sentence does not name '$P2': [$DRFT]" ;; esac
        case "$DRFT" in *"$P3"*) bad "B: drafts sentence names the MISSING project '$P3': [$DRFT]" ;; esac
        note "B: drafts sentence [$DRFT]" ;;
      *) bad "B: drafts sentence reads [$DRFT]; expected 'Drafts that will be zeroed out and submitted: ....' (TT-779: drafts are listed)" ;;
    esac
    [ "$BELOW" = "yes" ] && note "B ok: the explanation starts below the lists" \
      || bad "B: the explanation is not below the lists (bodyBelow=$BELOW) - the run-together text TT-779 fixed"

    playwright-cli click ".mx-name-btnConfirmZeroSubmit" >/dev/null 2>&1
    sleep 3
    MSG="$(dialog_text)"
    tt_clear_dialogs 3 >/dev/null 2>&1
    # Counted from the ledger rather than written as "3 / 1 / 2": any other active
    # assignment Three still holds (an earlier spec's, if its archive-on-exit
    # failed) adds to both, and the rule is what matters - every draft is zeroed,
    # at least P3 is new, and the total is the two together.
    DRAFTS_BEFORE=0
    _IFS="$IFS"; IFS='|'
    for f in $L1; do
      case "$f" in WEEK=*) ;; *=Draft@*|*='(empty)'@*) DRAFTS_BEFORE=$((DRAFTS_BEFORE+1)) ;; esac
    done
    IFS="$_IFS"
    RX="Submitted ([0-9]+) 0-hour entr\\(ies\\) for $CNAME: ([0-9]+) new, ([0-9]+) draft\\(s\\) zeroed\\."
    if [[ $MSG =~ $RX ]]; then
      N="${BASH_REMATCH[1]}"; M="${BASH_REMATCH[2]}"; K="${BASH_REMATCH[3]}"
      if [ "$K" -eq "$DRAFTS_BEFORE" ] && [ "$M" -ge 1 ] && [ "$N" -eq $((M + K)) ]; then
        note "C ok: [$MSG] - all $DRAFTS_BEFORE draft(s) zeroed"
      else
        bad "C: the confirmation reads [$MSG]; W1 held $DRAFTS_BEFORE draft(s) and at least one missing entry, so expected '$DRAFTS_BEFORE draft(s) zeroed', at least 1 new, and a total of the two"
      fi
    else
      bad "C: the confirmation reads [$MSG]; expected 'Submitted N 0-hour entr(ies) for $CNAME: M new, K draft(s) zeroed.'"
    fi
    sleep 2
    A1="$(tt_week_ledger "$CNAME" "$W1")"
    note "after: W1 [$A1]"
    for p in "$P1" "$P2" "$P3"; do
      s="$(tt_ledger_status "$A1" "$p")"; h="$(tt_ledger_hours "$A1" "$p")"
      if [ "$s" = "ToProcess" ] && [ "$h" = "0.00" ]; then
        note "C ok: '$p' is ToProcess at 0.00 h"
      else
        bad "C: '$p' in W1 is [${s:-absent}] at [${h:-?}] h; expected ToProcess at 0.00 (TT-779: drafts are zeroed and submitted too)"
      fi
    done
  else
    bad "B: $CNAME's row on $W1 reads [$R]; expected offered=1 blocked=0 (one missing project, two drafts)"
  fi
else
  bad "B: the Pending tab does not list $W1 at all, although $CNAME has drafts and a missing entry there"
fi

# =================================================================== D. W2, rejection only
tt_hr_click_tab "Pending"
sleep 2
if pending_select -2; then
  R="$(pending_row)"
  case "$R" in
    "offered=0 blocked=1") note "D ok: a rejection-only week offers no Submit 0-hour entries (blocked look-alike shown)" ;;
    ABSENT) bad "D: $CNAME is not on $W2's Pending list at all - a rejected entry must stay on Pending so HR can chase it" ;;
    *) bad "D: $CNAME's rejection-only row on $W2 reads [$R]; expected offered=0 blocked=1" ;;
  esac
else
  bad "D: the Pending tab does not list $W2, although $CNAME has a rejected entry there"
fi
A2="$(tt_week_ledger "$CNAME" "$W2")"
[ "$(tt_ledger_status "$A2" "$P1")" = "Rejected" ] && note "D ok: the rejected entry is still Rejected" \
  || bad "D: W2's rejected '$P1' entry is now [$(tt_ledger_status "$A2" "$P1")] - rejections must never be touched [$A2]"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt779-pending-zero-hours-drafts - $fails problem(s) with closing a week at 0 hours from the Pending tab."
  exit 1
fi
echo "PASS: verify-tt779-pending-zero-hours-drafts - drafts-only weeks are offered, the popup lists new and zeroed lines apart, Submit zeroes drafts too, and rejections are left alone."
