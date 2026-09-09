#!/usr/bin/env bash
# tt-timeout: 8m
# verify-role-token-denial.test.sh
#
# No signed-in role may retrieve Main.ApprovalToken - not the consultant, not the
# project manager, not HR, not the Titan Manager, and not the administrator.
#
# WHY THIS ENTITY AND ONLY THIS ENTITY. An approval token is a bearer credential:
# whoever holds the string can approve a customer's timesheets with no login at
# all. It is protected today in the strongest way Mendix offers - by having NO
# ACCESS RULE WHATSOEVER, for any role - which is also the easiest protection to
# undo by accident. Adding a rule so that some screen or data source "just works"
# is one click in Studio Pro, it produces no error, no page changes, and nothing
# else in this suite would notice. This step exists to notice.
#
# suites/85-security/verify-anonymous-data-denial already asks this question as an
# anonymous visitor. That is the loudest case but not the only one: an access rule
# added for a staff role hands every one of those users a list of live tokens,
# which is a standing ability to approve on the client's behalf, unattributed. No
# authenticated role has ever been asked.
#
# WHY THE MATRIX IS ONE ENTITY WIDE, WHICH IS NOT WHAT WAS PLANNED. The intention
# was a role x entity denial matrix over the core tables. Reading the access rules
# out of the live model first turned that plan down to this: there is almost
# nothing else a signed-in role is denied at the DATA LAYER.
#
#   Main.Timesheet, Main.AssignmentEntry  unconstrained read for Consultant, HR,
#                                         ProjectManager, TitanManager and
#                                         Administrator alike
#   Main.Project, Main.Customer           readable by every staff role
#   Main.Assignment                       constrained per role, but readable by all
#   Main.ChangeLog                        the one other genuine denial, and it is
#                                         already covered by
#                                         verify-changelog-role-denial
#
# So a consultant CAN retrieve another consultant's entries by asking the data
# layer directly; what keeps them to their own rows is the XPath on the pages and
# microflows that fetch them. That is not this step's news - it is stated at
# length in the header of suites/20-consultant/verify-consultant-data-isolation,
# which tests it through an association whose own rule IS constrained. It is
# recorded here so the next person who plans a broad denial matrix does not spend
# the afternoon discovering it again, and does not write assertions that the model
# says should fail.
#
# HOW A ZERO IS MADE MEANINGFUL. A zero from a session that was never really
# established looks exactly like a zero from a well-defended one, so for every
# role this step first proves that (1) the server says the session holds the role
# it signed in as, and (2) the same retrieve machinery returns a NUMBER for an
# entity that role is entitled to. Only then is the token count treated as an
# answer.
#
# WHAT IT CANNOT PROVE. That a token exists at the moment it runs. Minting one
# means driving the customer-approval mail flow, which is far heavier than this
# step and already covered in suites/30-approval and by
# verify-token-replay-refused beside this file. So a zero here is "was not given
# any" rather than "was refused some" - the same limit verify-anonymous-data-denial
# states about itself. What this catches is the change that matters: an access
# rule appearing on an entity that must not have one.
#
# Reads only. Creates nothing, changes nothing.
#
# Env: TT_BASE_URL, TT_ROLE_PASS, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

TOKENS="//Main.ApprovalToken"
# The control entity. Every staff role and the administrator hold an unconstrained
# read on Main.Project, so it is the one question all five sessions can be asked
# with the same expected shape - a number, and in a seeded environment a positive
# one. Do NOT swap this for Timesheet or AssignmentEntry: both are legitimately
# empty at points in the run, and an empty control cannot separate "defended" from
# "never asked".
CONTROL="//Main.Project"

fails=0

# check_role <user> <landing text> <expected module role> [password]
check_role() {
  local user="$1" land="$2" role="$3" pass="${4:-}" roles ctrl n

  if [ -n "$pass" ]; then tt_login "$user" "$land" "$pass"; else tt_login "$user" "$land"; fi

  roles="$(tt_authz_roles)"
  # '-' means "do not assert the role name". Used only for the administrator: the
  # e2e_* accounts hold exactly one Main module role each and their names are known
  # from the four other specs that assert them, but the admin account's user role
  # maps to several module roles across modules and the exact string the session
  # reports is not pinned anywhere in this repo. Asserting a guess there would fail
  # for a reason that has nothing to do with tokens. The control retrieve below
  # still proves the admin session is real.
  if [ "$role" != "-" ]; then
    case "$roles" in
      *"\"$role\""*) ;;
      *) tt_fail "$user signed in but the session holds ${roles:-nothing}, not $role. A denial measured on the wrong session proves nothing about $role." ;;
    esac
  fi

  ctrl="$(tt_authz_expect_count "control ($user)" "$CONTROL")"
  if [ "$ctrl" -eq 0 ]; then
    tt_fail "$user retrieved 0 projects. The control is meant to prove the retrieve machinery works for this session; a zero here means the question below was never really asked, and its zero would be meaningless. Run suites/00-setup first - it builds the projects."
  fi

  n="$(tt_authz_count "$TOKENS")"
  case "$n" in
    ERR:no-mx-client)
      tt_fail "the Mendix client API was not available to $user, so the data layer was never asked" ;;
    ERR:*)
      echo "  $user ($role): the data layer refused the request outright ($n) - control saw $ctrl project(s)" ;;
    ''|*[!0-9]*)
      tt_fail "$user: the token retrieve returned something that is not a count: [$n]" ;;
    0)
      echo "  $user ($role): retrieved 0 approval tokens - control saw $ctrl project(s)" ;;
    *)
      echo "FAIL: $user ($role) retrieved $n approval token(s)."
      echo "      Main.ApprovalToken has NO access rule for any role, so no signed-in"
      echo "      session should be able to retrieve it at all. Each row is a bearer"
      echo "      credential that approves a customer's timesheets with no login, so a"
      echo "      role that can list them can approve on the client's behalf, and the"
      echo "      approval is credited to the client rather than to whoever used it."
      echo "      The fix belongs on the entity access rules for Main.ApprovalToken -"
      echo "      most likely a rule added recently to make a screen or data source work."
      fails=$((fails+1)) ;;
  esac
}

check_role "e2e_consultant" "My Timesheets"               "Consultant"
check_role "e2e_pm"         "Project Manager Dashboard"   "ProjectManager"
check_role "e2e_hr"         "WEEKLY TO PROCESS"           "HR"
check_role "e2e_tm"         "Add Customer"                "TitanManager"

# The administrator is checked LAST and separately. It is the account most likely
# to be granted something "just to get it working", and the only one for which a
# non-zero answer might be argued to be intended - so it is worth seeing on its
# own line. Main.ApprovalToken has no Administrator rule either.
check_role "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "-" "${TT_ADMIN_PASS:-${TT_PASS:-}}"

[ "$fails" -eq 0 ] || exit 1
echo "PASS: verify-role-token-denial - no signed-in role (consultant, project manager, HR, Titan Manager, administrator) can retrieve Main.ApprovalToken, and each session proved it could retrieve the control entity first"
