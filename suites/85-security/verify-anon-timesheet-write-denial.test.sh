#!/usr/bin/env bash
# An unauthenticated session must not be able to create a timesheet, nor to
# re-own or re-status one that already exists.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. docs/reference/SECURITY-FINDING-anonymous-grants.md records
# that Anonymous holds Create and Delete on Main.Timesheet, with Status and
# Timesheet_Account writable and no XPath constraint. Nothing in this suite has
# ever tried any of it. verify-anonymous-data-denial covers reads, and covers the
# two entities Anonymous is genuinely denied; the write surface is untested.
#
# The one existing create in the whole suite is
# suites/70-tickets/tt737/verify-tt737-null-startdate-heals.test.sh, which creates
# a Main.Timesheet as a signed-in consultant and treats a refusal as a SETUP
# failure. This is the same call with the polarity inverted: here a success is the
# finding.
#
# WHAT IT ASSERTS
#   A. the session really is anonymous;
#   B. creating a Main.Timesheet does not visibly succeed;
#   C. nothing new appeared - the count of timesheets with no owner is unchanged,
#      read back as an entitled user. B alone cannot see a create that reported an
#      error and committed anyway;
#   D. writing Status on an existing E2E timesheet does not visibly succeed;
#   E. that Status is unchanged;
#   F. re-pointing Timesheet_Account is refused at the attribute level too - this
#      is the one that would let an anonymous caller hand somebody else's week to
#      an account of their choosing.
#
# WHY C IS COUNTED THE WAY IT IS. A created-but-orphaned Timesheet has no
# consultant, so it cannot be found through the ConsultantName path the rest of
# this suite scopes by, and the bookend clear is scoped to named consultants and
# would never remove it. Counting rows the control can see before and after is the
# only honest way to notice one appearing, and if one does, this test says so
# loudly rather than quietly leaking it.
#
# IF B/C OR D/E/F FAIL an unauthenticated caller can forge or hijack timesheets.
#
# Consumes: reads, plus one refused write against an existing E2E timesheet.
# Clears cookies - safe here, in 85-security.
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

ALL_TS="//Main.Timesheet"
MINE_TS="//Main.Timesheet[Main.Timesheet_Account/Administration.Account/FullName = 'E2E Consultant']"

# ------------------------------------------------------------------ control, as HR
tt_login "e2e_hr" "WEEKLY TO PROCESS"
BEFORE_ALL="$(tt_authz_expect_count "control: all timesheets" "$ALL_TS")"
TS_STATUS_BEFORE="$(tt_authz_readback "$MINE_TS" 'Status')"
case "$TS_STATUS_BEFORE" in
  ERR:notfound) tt_fail "'E2E Consultant' has no Main.Timesheet, so D/E/F have nothing to act on. suites/20-consultant creates one; run the suite in order." ;;
  ERR:*)        tt_fail "the control could not read the E2E timesheet Status ($TS_STATUS_BEFORE)" ;;
esac
note "before: $BEFORE_ALL timesheet(s) visible to HR; E2E Consultant week Status=$TS_STATUS_BEFORE"

# --------------------------------------------------------------- A. become anonymous
ROLES="$(tt_authz_anonymous)"
note "anonymous session roles: $ROLES"
for privileged in Consultant ProjectManager HR TitanManager Administrator; do
  case "$ROLES" in
    *"\"$privileged\""*) bad "A: the 'anonymous' session still holds $privileged ($ROLES)" ;;
  esac
done

# ------------------------------------------------------------------------ B. create
C="$(tt_authz_create 'Main.Timesheet')"
case "$C" in
  ERR:create-*|ERR:commit-*) note "B ok: creating a Main.Timesheet did not visibly succeed ($C)" ;;
  ERR:*)                     note "B ok: create refused ($C)" ;;
  *)                         bad "B: an anonymous session CREATED Main.Timesheet $C" ;;
esac

# ------------------------------------------------------------------- D/F. writes
W="$(tt_authz_write "$MINE_TS" 'Status' 'Approved')"
case "$W" in
  ERR:*) note "D ok: writing Status on an existing timesheet did not visibly succeed ($W)" ;;
  *)     bad "D: an anonymous session wrote Status='Approved' on E2E Consultant's timesheet and the call returned [$W]" ;;
esac

# Timesheet_Account is an association; writing it through set() is refused at a
# different layer than an attribute write, so it is asked separately rather than
# assumed to follow from D.
O="$(tt_authz_write "$MINE_TS" 'Timesheet_Account' '')"
case "$O" in
  ERR:*) note "F ok: re-pointing Timesheet_Account did not visibly succeed ($O)" ;;
  *)     bad "F: an anonymous session altered Timesheet_Account and the call returned [$O]" ;;
esac

# ------------------------------------------------------------------ C/E. read back
tt_login "e2e_hr" "WEEKLY TO PROCESS"
AFTER_ALL="$(tt_authz_expect_count "readback: all timesheets" "$ALL_TS")"
if [ "$AFTER_ALL" -le "$BEFORE_ALL" ]; then
  note "C ok: timesheet count is $AFTER_ALL (was $BEFORE_ALL) - nothing was forged"
else
  bad "C: timesheet count went from $BEFORE_ALL to $AFTER_ALL across an anonymous create attempt - a row was committed and it has no owner to clean it up"
fi

TS_STATUS_AFTER="$(tt_authz_readback "$MINE_TS" 'Status')"
case "$TS_STATUS_AFTER" in
  ERR:*)              bad "E: could not read the timesheet back ($TS_STATUS_AFTER)" ;;
  "$TS_STATUS_BEFORE") note "E ok: Status is still $TS_STATUS_AFTER" ;;
  *)                  bad "E: Status moved from $TS_STATUS_BEFORE to $TS_STATUS_AFTER while only an anonymous session acted" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-anon-timesheet-write-denial — $fails problem(s). B/C and D/E/F are findings about the Anonymous grants, not about this script."
  exit 1
fi
echo "PASS: verify-anon-timesheet-write-denial — anonymous could not create, re-status or re-own a timesheet; count $AFTER_ALL, Status $TS_STATUS_AFTER."
