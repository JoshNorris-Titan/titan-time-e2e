#!/usr/bin/env bash
# verify-changelog-role-denial.test.sh
#
# tt-timeout: 10m
#
# The audit trail is readable by the roles that field timesheet disputes, and by
# nobody else.
#
# THE RULE, PRECISELY. Main.ChangeLog carries exactly two access rules: one for
# Main.Administrator and one for Main.HR + Main.TitanManager (read-only, added
# 2026-08-18 so the trail stays tamper-evident). Main.Consultant and
# Main.ProjectManager have NO rule on the entity at all. In Mendix that is not a
# narrower view of the table -- it is no view of it, so a consultant or a project
# manager asking the data layer for change-log rows must come back with nothing.
#
# WHAT IT PROTECTS. Every row records who moved a timesheet entry, when, from
# which status to which, and by what method, across every consultant. A single
# unconstrained rule for Consultant would hand each of them the movement history
# of everyone else's hours -- and it would do so without changing a single
# screen, because nothing in the app draws this entity for those roles. That is
# exactly the kind of change no other test in this suite can see.
#
# WHY THIS IS ASKED OF THE DATA LAYER AND NOT OF A SCREEN. Page-level scoping is
# real protection for anyone using the app through its screens, but it is one
# layer, and it is the layer every other step here exercises. A grant added to
# the entity would render no differently anywhere. So this asks the data layer
# directly, as an ordinary logged-in user, using the app's own client API -- no
# tooling and no exploit, the same call the app itself makes with a different
# XPath. See lib/_authz.sh for why page access could not be asked instead.
#
# HOW A ZERO IS MADE MEANINGFUL, WHICH IS THE WHOLE DESIGN. "The consultant
# retrieved no change-log rows" is worth nothing on its own: it is also what an
# empty table, a broken retrieve and a dead session all look like. So the SAME
# query is run first as a role that is entitled to the rows, and must come back
# with at least one. Only then is the same question put to the roles that are
# not entitled. A run where nobody can see any rows ABORTS rather than reporting
# a pass -- otherwise this would be a test that passes hardest on an empty
# database, which is the defect this file exists to avoid, not to commit.
#
# The control tries HR, then Titan Manager, then the administrator. Any one of
# the three is enough; all three are asked before giving up because they are
# granted by two different rules and a failure of one is worth telling apart
# from an empty table.
#
# WHERE THE ROWS COME FROM. Change-log rows are written on status transitions,
# so an ordinary suite run has produced several by the time this step is
# reached -- 30-approval and 40-hr both move entries. That is why this suite
# sits at 85 and not, say, 05. Run standalone against a freshly cleared
# environment it will abort on the control, correctly: it has nothing to
# measure a denial against.
#
# WHY ROLES ARE ASSERTED TOO. A zero is only attributable once you know who was
# asking. mx.session.sessionData.roles is the server's own answer, delivered
# with the session, so each step below states the role it actually held rather
# than the role the account name implies. A session that had silently fallen
# back to Anonymous would see nothing either, and would otherwise read as a pass.
#
# IF IT FAILS on the consultant or the project manager, a role that should have
# no visibility of the audit trail can read the whole of it by asking. The fix
# belongs on the entity access rules for Main.ChangeLog, not on any screen.
#
# Reads only. Creates nothing, changes nothing.
#
# Env:
#   TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

XPATH="//Main.ChangeLog"

# assert_role <user> <expected-role> <why> — echo the session's roles, or stop.
assert_role() {
  local user="$1" role="$2" why="$3" got
  got="$(tt_authz_roles)"
  case "$got" in
    *"\"$role\""*) printf '%s' "$got" ;;
    *) tt_fail "$user signed in but the session holds ${got:-nothing}, not $role - $why" ;;
  esac
}

# ------------------------------------------------------- 1. control: rows exist
control_user=""
control_rows=0
tried=""

for candidate in "e2e_hr:WEEKLY TO PROCESS:HR" "e2e_tm:Add Customer:TitanManager"; do
  user="${candidate%%:*}"
  rest="${candidate#*:}"
  land="${rest%:*}"
  role="${rest##*:}"

  tt_login "$user" "$land"
  roles="$(assert_role "$user" "$role" "the control cannot be trusted")"
  n="$(tt_authz_expect_count "control ($user)" "$XPATH")"
  tried="$tried $user=$n"
  echo "  control: $user (roles $roles) retrieved $n change-log row(s)"
  if [ "$n" -gt 0 ]; then
    control_user="$user"
    control_rows="$n"
    break
  fi
done

if [ -z "$control_user" ]; then
  tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}"
  n="$(tt_authz_expect_count "control (administrator)" "$XPATH")"
  tried="$tried admin=$n"
  echo "  control: administrator retrieved $n change-log row(s)"
  if [ "$n" -gt 0 ]; then
    control_user="${TT_ADMIN_USER:-MxAdmin}"
    control_rows="$n"
  fi
fi

if [ -z "$control_user" ]; then
  tt_fail "no entitled role can see a single change-log row (tried:$tried), so there is nothing for an unentitled role to be denied. Run the suite in order so the approval steps produce a transition first - passing here would mean nothing."
fi

# ------------------------------------------- 2. the same question, unentitled
# Two roles, both with no access rule on the entity whatsoever.
fails=0

for candidate in "e2e_consultant:My Timesheets:Consultant" "e2e_pm:Project Manager Dashboard:ProjectManager"; do
  user="${candidate%%:*}"
  rest="${candidate#*:}"
  land="${rest%:*}"
  role="${rest##*:}"

  tt_login "$user" "$land"
  roles="$(assert_role "$user" "$role" "a denial measured on it would prove nothing")"
  n="$(tt_authz_count "$XPATH")"

  case "$n" in
    ERR:no-mx-client)
      tt_fail "the Mendix client API was not available to $user, so the data layer was never asked. This step cannot report a pass without having asked." ;;
    ERR:*)
      # A refused retrieve is the correct outcome: the platform declined outright.
      echo "  $user (roles $roles): the data layer refused the request ($n)" ;;
    ''|*[!0-9]*)
      tt_fail "$user: the retrieve returned something that is not a count: [$n]" ;;
    0)
      echo "  $user (roles $roles): retrieved 0 of the $control_rows row(s) $control_user can see" ;;
    *)
      echo "FAIL: $user retrieved $n change-log row(s) of the $control_rows $control_user can see."
      echo "      $role has NO access rule on Main.ChangeLog, so this role should not be"
      echo "      able to retrieve the entity at all. Every row names a consultant, a"
      echo "      status transition and who made it, across the whole company, so this is"
      echo "      a data-protection issue rather than a bug in a screen - nothing in the"
      echo "      app draws this entity for $role, which is why no other test notices."
      echo "      The fix belongs on the access rules for Main.ChangeLog."
      fails=$((fails+1)) ;;
  esac
done

[ "$fails" -eq 0 ] || exit 1
echo "PASS: verify-changelog-role-denial - the audit trail is visible to $control_user ($control_rows row(s)) and to neither the consultant nor the project manager"
