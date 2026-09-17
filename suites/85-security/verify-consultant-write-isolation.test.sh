#!/usr/bin/env bash
# A consultant must not be able to WRITE another consultant's timesheet entry,
# and must not be able to set their own Status.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. suites/20-consultant/verify-consultant-data-isolation.test.sh
# already records the thing that makes this necessary: the Main.Consultant access
# rule grants members WRITE on Main.AssignmentEntry - including Status - over the
# whole entity, with no XPath constraint. It then tests only READS. So the suite
# has written down, in its own words, that a consultant may be able to edit
# anybody's hours and approve their own, and has never once tried it.
#
# A read-only isolation test cannot see this. Neither can a page test: no screen
# offers a consultant somebody else's week, and no screen offers them a Status
# control at all. The grant is only reachable through the client API, which is
# what lib/_authz.sh's write side exists for.
#
# WHAT IT ASSERTS
#   A. the session really holds Consultant and nothing more;
#   B. a CONTROL write the consultant is supposed to be able to make succeeds -
#      without it, every refusal below is unattributable (a typo'd attribute, a
#      validation rule and a genuine denial all look identical, because this
#      runtime returns "Internal server error" for all of them);
#   C. writing Monday on ANOTHER consultant's entry does not visibly succeed;
#   D. that entry's Monday is UNCHANGED, read back as an entitled user;
#   E. setting their OWN entry's Status to ToProcess - self-approval - does not
#      visibly succeed;
#   F. that entry's Status is UNCHANGED.
#
# D and F are the assertions that matter. C and E only establish that the call
# did not report success, and a write that reports failure and lands anyway is
# precisely the shape this pair is here to catch.
#
# SCOPE. Acts only on entries belonging to consultants whose name starts "E2E ",
# and the "other" consultant is whichever E2E consultant is not the one logged in.
# It restores anything it successfully changes.
#
# IF C/D OR E/F FAIL this is not a test defect - it is a consultant able to edit
# another person's hours, or to approve their own, through the client API.
#
# Consumes: one entry belonging to each of two E2E consultants. Restores what it
# changes.
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

ME="${TT_ISO_USER:-e2e_consultant}"
MINE="${TT_ISO_MINE:-E2E Consultant}"
THEIRS="${TT_ISO_THEIRS:-E2E Consultant Two}"

ent_of() { printf "//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '%s']" "$1"; }
MY_ENT="$(ent_of "$MINE")"
THEIR_ENT="$(ent_of "$THEIRS")"

# ------------------------------------------------- control reads, as an entitled user
tt_login "e2e_hr" "WEEKLY TO PROCESS"
THEIR_MON_BEFORE="$(tt_authz_readback "$THEIR_ENT" 'Monday')"
MY_STATUS_BEFORE="$(tt_authz_readback "$MY_ENT" 'Status')"
case "$THEIR_MON_BEFORE" in
  ERR:notfound) tt_fail "'$THEIRS' has no AssignmentEntry, so there is nothing to attempt a cross-consultant write against. suites/00-setup builds the fixtures; run the suite in order." ;;
  ERR:*)        tt_fail "the control could not read '$THEIRS' entry Monday ($THEIR_MON_BEFORE)" ;;
esac
case "$MY_STATUS_BEFORE" in
  ERR:*) tt_fail "the control could not read '$MINE' entry Status ($MY_STATUS_BEFORE)" ;;
esac
note "before: $THEIRS Monday=$THEIR_MON_BEFORE / $MINE Status=$MY_STATUS_BEFORE"

# --------------------------------------------------------------- A. be the consultant
tt_login "$ME" "My Timesheets"
ROLES="$(tt_authz_roles)"
note "session roles: $ROLES"
case "$ROLES" in
  *'"Consultant"'*) : ;;
  *) bad "A: the session does not hold Consultant ($ROLES) - nothing below would mean anything" ;;
esac
for privileged in HR TitanManager Administrator ProjectManager; do
  case "$ROLES" in
    *"\"$privileged\""*) bad "A: a consultant session also holds $privileged ($ROLES)" ;;
  esac
done

# ------------------------------------------------------------------ B. positive control
# A consultant editing their OWN hours is ordinary. If this is refused the refusals
# below prove nothing, so it is fatal rather than counted.
CTRL="$(tt_authz_write "$MY_ENT" 'Monday' "$(tt_authz_readback "$MY_ENT" 'Monday')")"
tt_authz_expect_ok "B" "$CTRL" >/dev/null
note "B ok: the consultant can write their own entry ($CTRL)"

# ----------------------------------------------------- C/D. another consultant's hours
W="$(tt_authz_write "$THEIR_ENT" 'Monday' '23')"
case "$W" in
  ERR:*) note "C ok: writing '$THEIRS' Monday did not visibly succeed ($W)" ;;
  *)     bad "C: '$ME' wrote Monday=23 on an entry belonging to '$THEIRS' and the call returned [$W]" ;;
esac

tt_login "e2e_hr" "WEEKLY TO PROCESS"
THEIR_MON_AFTER="$(tt_authz_readback "$THEIR_ENT" 'Monday')"
if [ "$THEIR_MON_AFTER" = "$THEIR_MON_BEFORE" ]; then
  note "D ok: $THEIRS Monday is still $THEIR_MON_AFTER"
else
  bad "D: $THEIRS Monday moved from $THEIR_MON_BEFORE to $THEIR_MON_AFTER, written by '$ME'"
  # Put it back rather than leave someone else's hours altered.
  tt_authz_write "$THEIR_ENT" 'Monday' "$THEIR_MON_BEFORE" >/dev/null 2>&1 \
    && note "     (restored $THEIRS Monday to $THEIR_MON_BEFORE)"
fi

# ------------------------------------------------------------ E/F. self-approval
tt_login "$ME" "My Timesheets"
S="$(tt_authz_write "$MY_ENT" 'Status' 'ToProcess')"
case "$S" in
  ERR:*) note "E ok: setting own Status did not visibly succeed ($S)" ;;
  *)     bad "E: '$ME' set their own entry Status and the call returned [$S]" ;;
esac

tt_login "e2e_hr" "WEEKLY TO PROCESS"
MY_STATUS_AFTER="$(tt_authz_readback "$MY_ENT" 'Status')"
if [ "$MY_STATUS_AFTER" = "$MY_STATUS_BEFORE" ]; then
  note "F ok: $MINE Status is still $MY_STATUS_AFTER"
else
  bad "F: $MINE Status moved from $MY_STATUS_BEFORE to $MY_STATUS_AFTER, set by the consultant themselves - this is self-approval"
  tt_authz_write "$MY_ENT" 'Status' "$MY_STATUS_BEFORE" >/dev/null 2>&1 \
    && note "     (restored $MINE Status to $MY_STATUS_BEFORE)"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-consultant-write-isolation — $fails problem(s). D and F are findings about the access rule, not about this script."
  exit 1
fi
echo "PASS: verify-consultant-write-isolation — '$ME' could not write $THEIRS' hours or set their own Status; both values unchanged."
