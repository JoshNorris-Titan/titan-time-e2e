#!/usr/bin/env bash
# TT-737 — a Timesheet with no StartDate must not take down the consultant dashboard.
#
# THE BUG, from the production runtime log on the ticket: Main.DS_Timesheet_Get read
# $TimesheetHelper/StartDate straight into addDays(), so a helper with an empty start date
# threw and the whole timesheet grid failed to load. The consultant saw a broken dashboard,
# not a bad row.
#
# THE FIX, two parts:
#   1. DS_Timesheet_Get gained an "StartDate missing?" split that falls back to
#      [%BeginOfCurrentWeek%] and writes that week back onto the helper — it heals instead
#      of throwing.
#   2. galTimesheetHistory's constraint gained "and StartDate != empty", so a dateless row
#      cannot be listed or clicked in the first place.
#
# WHY THIS TEST WRITES THROUGH THE CLIENT API. The ticket's own microflow documentation
# says the branch "cannot be reached through the UI — nothing in the front end can produce
# a helper with an empty start date." That is precisely why it broke in production and why
# no UI-driven test can set it up. The row is therefore created with mx.data, the same
# client API lib/_login.sh and lib/_fixtures.sh already use for reads.
#
# IF THE CREATE IS REFUSED, THIS TEST FAILS LOUDLY AND SAYS SO. Consultant entity access
# may not permit creating a Main.Timesheet. A refusal is reported as a setup failure naming
# the client error, NOT as a pass — a test that silently skips its own fixture is worse than
# no test. If it turns out to be permanently refused, the right move is to retire this spec
# and rely on the unit test the ticket already added
# (UT_DS_TimesheetGet_EmptyStartDateHealsToCurrentWeek), not to soften the assertion.
#
# WHAT IS ASSERTED
#   A. With a dateless row present, the grid still renders and the console shows no
#      addDays/MicroflowException/500 — the actual TT-737 symptom.
#   B. The history gallery lists no more rows than before — the StartDate != empty filter.
#      Guarded by a page-size check, see below.
#
# tt-timeout: 8m
# Env: TT_BASE_URL, TT_ROLE_PASS. Uses e2e_consultant, and deletes the row it creates.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CREATED_GUID=""

# tt737_history_count — rows currently rendered in the history gallery.
tt737_history_count() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTimesheetHistory'); return g ? String(g.querySelectorAll('.widget-gallery-item').length) : 'NOGAL'; }" 2>/dev/null | _tt_eval_str
}

# tt737_refetch — force the dashboard's data sources to run again. Stepping a week away
# and back re-invokes DS_Timesheet_Get and re-queries the history gallery, which is the
# same idiom verify-consultant-timesheet-crud.test.sh uses. A plain reload would land on
# TODAY's week rather than the one under test, which has faked results in this suite
# before.
tt737_refetch() {
  playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1; sleep 2
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1; sleep 3
}

tt737_cleanup() {
  [ -n "$CREATED_GUID" ] || return 0
  local r
  r="$(playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.remove({ guid: '$CREATED_GUID', callback: function(){ clearTimeout(t); res('ok'); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str)"
  if [ "$r" = "ok" ]; then
    echo "  cleanup: removed the dateless Timesheet row"
  else
    echo "  WARN: could not remove the dateless Timesheet row $CREATED_GUID ($r) — remove it by hand, it is invisible in the UI by design" >&2
  fi
}
trap tt737_cleanup EXIT

tt_login "e2e_consultant" "My Timesheets"
tt_wait_for ".mx-name-dvTimesheet" "consultant timesheet grid"
tt_wait_for ".mx-name-galTimesheetHistory" "consultant timesheet history gallery"

before="$(tt737_history_count)"
[ "$before" != "NOGAL" ] || tt_fail "TT-737: galTimesheetHistory not found on the consultant dashboard"
echo "  history rows before: $before"

# Assertion B is a count comparison, and the gallery pages at 25 (TT-723). At the cap a
# new row could be hidden by paging rather than by the filter, which would make a passing
# count meaningless. Refuse to pretend.
if [ "$before" -ge 25 ]; then
  tt_fail "TT-737: this consultant already shows $before history rows, at or past the gallery's 25-row page size, so the filter assertion cannot distinguish 'excluded' from 'on page 2'. Point TT737 at a consultant with a shorter history."
fi

# ------------------------------------------------------- create the dateless row
#
# StartDate and EndDate are left unset — that IS the fixture. The account association is
# set from the live session so the row belongs to the consultant whose dashboard is open.
CREATED_GUID="$(playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.create({ entity: 'Main.Timesheet', callback: function(obj){ try { obj.addReference('Main.Timesheet_Account', mx.session.getUserId()); mx.data.commit({ mxobj: obj, callback: function(){ clearTimeout(t); res(obj.getGuid()); }, error: function(e){ clearTimeout(t); res('ERR:commit-'+((e&&e.message)||'refused')); } }); } catch(e){ clearTimeout(t); res('ERR:wire-'+e.message); } }, error: function(e){ clearTimeout(t); res('ERR:create-'+((e&&e.message)||'refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str)"

case "$CREATED_GUID" in
  ERR:*)
    CREATED_GUID=""
    tt_fail "TT-737: SETUP FAILED — could not create a dateless Main.Timesheet through the client API ($CREATED_GUID). This test needs that write to build a state the UI cannot produce. If consultant entity access forbids it permanently, retire this spec and rely on the unit test UT_DS_TimesheetGet_EmptyStartDateHealsToCurrentWeek instead." ;;
  "") tt_fail "TT-737: SETUP FAILED — the client API returned no GUID for the dateless Timesheet row." ;;
esac
echo "  created a dateless Main.Timesheet ($CREATED_GUID)"

# ------------------------------------------------------------------ A. grid survives
tt737_refetch

grid="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-dvTimesheet'))" 2>/dev/null | _tt_eval_str)"
[ "$grid" = "true" ] || tt_fail "TT-737: the timesheet grid (dvTimesheet) is gone after a dateless Timesheet row appeared — DS_Timesheet_Get is throwing again instead of healing to the current week"

# The grid element can survive while its data source failed, so also require the columns
# to have rendered — the same shape verify-consultant-timesheet.test.sh asserts.
tt_assert_all "TT-737 consultant timesheet grid" "Project" "Client" "Total"

if playwright-cli console 2>/dev/null | grep -qiE "addDays|MicroflowException|/xas/.*560|\"result\":560|internal server error"; then
  tt_fail "TT-737: the browser console reports a server error after a dateless Timesheet row appeared — DS_Timesheet_Get's 'StartDate missing?' guard is not holding. Run with --verbose and read the console output."
fi
echo "  ok: grid still renders and the console is clean with a dateless row present"

# ------------------------------------------------------------- B. it stays out of history
after="$(tt737_history_count)"
[ "$after" != "NOGAL" ] || tt_fail "TT-737: galTimesheetHistory disappeared after the dateless row was created"

if [ "$after" -ne "$before" ]; then
  tt_fail "TT-737: the history gallery went from $before to $after rows after a dateless Timesheet was created — galTimesheetHistory's 'StartDate != empty' constraint is not filtering it out, so a consultant can click a row with no week."
fi
echo "  ok: the dateless row is excluded from the history gallery (still $after rows)"

echo "PASS: verify-tt737-null-startdate-heals (TT-737) — a dateless Timesheet neither breaks the grid nor shows up in history"
