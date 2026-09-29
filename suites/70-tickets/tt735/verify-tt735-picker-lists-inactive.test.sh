#!/usr/bin/env bash
# HR's consultant picker lists every consultant account, including deactivated
# ones — the behaviour TT-735 deliberately restored.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. verify-tt735-consultant-picker records what happened: an
# [Active] XPath constraint was added to cbCreateForAccount and it EMPTIED the
# picker for HR, who then could not create a timesheet on anyone's behalf. The
# constraint was removed on 2026-09-03 and the deliberate behaviour since then is
# that deactivated consultants ARE listed.
#
# That decision is asserted nowhere. The existing spec checks the options come
# back sorted and that there are at least two - which catches a total wipe, and
# nothing short of it. Re-add the constraint tomorrow and, as long as two active
# consultants remain, the suite stays green while HR silently loses the ability to
# act for anyone who has been deactivated.
#
# WHAT IT ASSERTS, and why it is a count rather than a name:
#   the picker offers exactly as many options as the data layer returns for the
#   picker's own source - every Administration.Account HR can read, ACTIVE OR NOT.
#
# WHY NOT "CONSULTANT-ROLE ACCOUNTS" ANY MORE. It used to compare against
# //Administration.Account[Administration.UserRoles/System.UserRole/Name =
# 'Consultant']. HR cannot read UserRoles, so that count came back 0 on dev with
# no error, and C failed for a reason that had nothing to do with TT-735 (it also
# never got that far until 2026-09-29: the spec read the picker without first
# opening Create Timesheet). The model's cbCreateForAccount is an XPath source on
# Administration.Account sorted by FullName with NO constraint at all, which is
# TT-735's fix, so the widget's source is the right thing to compare with. That
# the picker therefore offers HR, Titan Manager and admin accounts as well is the
# model as built - a product question, not something this spec can settle.
#
# Naming a specific deactivated consultant would be the obvious test and is the
# wrong one: no fixture guarantees a deactivated account exists, so the test would
# pass vacuously on most environments and fail on the rest for reasons that have
# nothing to do with the constraint. The equality holds on every environment, and
# it is exactly what a reintroduced [Active] filter breaks - the picker would come
# back SHORT by however many are deactivated.
#
#   A. the picker renders at all and offers options;
#   B. the data layer's count of the picker's source is readable, and non-zero;
#   C. the two agree. If they do not, the step says which way and by how many,
#      because "fewer than the data layer holds" points at a filter and "more"
#      points at the picker reaching past its own source.
#
# If the environment happens to have no deactivated consultants, C still holds and
# still passes - it just cannot fail for the specific reason it was written for.
# The step says so rather than claiming more than it proved.
#
# Reads only.
#
# Consumes: nothing.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

CB='.mx-name-cbCreateForAccount'

picker_options() {
  playwright-cli eval "() => { const w=document.querySelector('$CB'); if(!w) return '-1'; const sel=w.querySelector('select'); if(sel) return String([...sel.options].filter(o=>(o.value||'')!=='' && (o.text||'').trim()!=='').length); const items=w.querySelectorAll('[role=option], li'); return String(items.length); }" 2>/dev/null | _tt_eval_str
}

tt_login "e2e_hr" "$TT_HR_READY"

# The picker is on Main.CreateTimesheet, not on the HR dashboard the login lands
# on. This spec used to read it straight after login and so always hit the -1
# ("not on the page") branch below; reach it the way verify-tt735-consultant-picker
# does, through the "Create Timesheet" navigation item.
tt_click_text "Create Timesheet" "HR Create Timesheet nav item"
tt_wait_for "$CB" "TT-735 Create Timesheet consultant picker"
sleep 1

# Open the picker, then read the options.
playwright-cli eval "() => { const w=document.querySelector('$CB'); if(w){ const i=w.querySelector('input,select,button'); if(i){ i.click(); return 'ok'; } } return 'nf'; }" >/dev/null 2>&1
sleep 2

# ------------------------------------------------------------------- A. it renders
OPTS="$(picker_options)"
case "$OPTS" in
  -1)          tt_fail "cbCreateForAccount is not on the page, so the picker could not be read. The existing verify-tt735-consultant-picker spec reaches it; if the layout moved, fix both together." ;;
  ''|*[!0-9]*) tt_fail "could not count the picker's options (read: [$OPTS])" ;;
  0)           bad "A: the picker offers no options at all - this is the TT-735 symptom exactly, and HR cannot create a timesheet for anyone" ;;
  *)           note "A ok: the picker offers $OPTS option(s)" ;;
esac

# --------------------------------------------------------- B. what the data layer holds
ALL="$(tt_authz_count "//Administration.Account")"
INACTIVE="$(tt_authz_count "//Administration.Account[Active = false()]")"
case "$ALL" in
  ERR:*|''|*[!0-9]*) tt_fail "could not count the accounts HR can read (read: [$ALL]), so the picker has nothing to be compared against" ;;
  0) tt_fail "the data layer returned 0 accounts to HR while the picker offers $OPTS - the count is not reading what the picker reads, so C would compare against nothing" ;;
esac
case "$INACTIVE" in
  ERR:*|''|*[!0-9]*) tt_fail "could not count the deactivated accounts HR can read (read: [$INACTIVE])" ;;
esac
note "B ok: the data layer gives HR $ALL account(s), $INACTIVE of them deactivated"

# ---------------------------------------------------------------------- C. they agree
if [ "$OPTS" -eq "$ALL" ]; then
  note "C ok: the picker lists all $ALL"
  case "$INACTIVE" in
    0) note "note: no consultant is currently deactivated, so this run could not have caught a reintroduced [Active] filter - the equality held, but not for the reason this test was written for" ;;
    *) note "note: $INACTIVE deactivated consultant(s) are listed, which is the TT-735 decision holding" ;;
  esac
elif [ "$OPTS" -lt "$ALL" ]; then
  bad "C: the picker lists $OPTS of the $ALL account(s) HR can read - short by $((ALL-OPTS)), and $INACTIVE are deactivated. That is what a reintroduced [Active] constraint looks like, and it is the TT-735 regression."
else
  bad "C: the picker lists $OPTS options where the data layer gives HR only $ALL accounts - it is reaching past its own source"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-tt735-picker-lists-inactive — $fails problem(s) with the consultant picker's scope."
  exit 1
fi
echo "PASS: verify-tt735-picker-lists-inactive — the picker lists all $ALL account(s) HR can read, $INACTIVE of them deactivated."
