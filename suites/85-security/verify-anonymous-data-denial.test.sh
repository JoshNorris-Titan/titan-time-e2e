#!/usr/bin/env bash
# verify-anonymous-data-denial.test.sh
#
# tt-timeout: 6m
#
# An unauthenticated visitor holds the anonymous role and nothing else, and
# cannot read the two entities no anonymous rule covers.
#
# WHY THE APP HAS AN ANONYMOUS SURFACE AT ALL. Customers approve timesheets from
# an emailed token link without ever logging in, so Main.Anonymous is a real,
# deliberately-granted role rather than a leftover. That makes it the one role
# whose reach nobody has to authenticate to obtain: whatever it can read, anyone
# on the internet with the app's URL can read. Nothing else in this suite looks
# at it from the outside -- suites/10-smoke/verify-anon-bad-token.test.sh checks
# that a bad token is refused, which is a different question from what a plain
# anonymous session can retrieve when it asks the data layer nicely.
#
# WHAT IS ASSERTED, AND WHY ONLY THESE TWO ENTITIES. Most of the business
# entities DO carry an anonymous access rule, constrained to the customer
# approval flow:
#
#   Main.AssignmentEntry  [Status = 'AwaitingCustomerApproval']
#   Main.Timesheet        [.../Main.AssignmentEntry/Status = 'AwaitingCustomerApproval']
#   Main.Project          [.../Main.AssignmentEntry/Status = 'AwaitingCustomerApproval']
#   Main.Customer         [.../Main.AssignmentEntry/Status = 'AwaitingCustomerApproval']
#
# So an anonymous count of zero on any of those is CIRCUMSTANTIAL -- it means no
# entry happens to be awaiting a customer right now, and it would legitimately
# become non-zero while suites/30-approval is mid-flight. Asserting zero on them
# would be asserting the absence of test data, and would go red for a correct
# app. They are named here so the next person does not add them.
#
# The two below are different. Neither has an anonymous rule of any kind, so
# their zero is unconditional and holds whatever state the database is in:
#
#   Main.ChangeLog     - rules for Administrator and for HR + TitanManager only.
#   Main.ApprovalToken - NO access rules at all, for any role.
#
# Main.ApprovalToken is the one that matters most. Its rows are the tokens that
# let a customer approve a timesheet with no login, so an anonymous session able
# to list them could approve other people's hours at will. It is protected today
# by having no access rule whatsoever, which is the strongest form available and
# also the easiest to undo by accident -- adding a rule to make some screen work
# is a one-click change in Studio Pro, and nothing else here would notice.
#
# THE CONTROL, AND WHAT IT CAN AND CANNOT PROVE. A zero from a session that was
# never really established looks exactly like a zero from a well-defended one.
# So before asserting anything this step proves that (1) the Mendix client came
# up, (2) the server says the session holds Anonymous, and (3) the retrieve
# machinery works, by running the SAME call as a signed-in role that must get a
# number back. That rules out the realistic false-pass -- a probe that silently
# stopped asking.
#
# It does NOT prove that an approval token exists at the moment it runs, so a
# zero on Main.ApprovalToken is "was not given any" rather than "was refused
# some". That is a real limit and is stated rather than papered over: minting a
# token means driving the customer-approval mail flow, which is a far heavier
# step than this one and already has coverage in suites/30-approval. What this
# catches is the change that matters -- an access rule appearing on an entity
# that must not have one.
#
# IF IT FAILS. An unauthenticated visitor can read either the audit trail or the
# approval tokens. Both are fixed on the entity access rules, not on any screen.
#
# Reads only. Creates nothing, changes nothing. It DOES clear the browser's
# cookies, so it must not run between a login and an assertion that depends on
# it; as a standalone step in its own suite directory that cannot happen.
#
# Env:
#   TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

# The entities with no anonymous access rule. Anything added here must be
# checked against the domain model first - see the header.
UNREACHABLE="//Main.ChangeLog //Main.ApprovalToken"

# --------------------------------------- 1. control: the retrieve machinery works
# Asked as HR, who is entitled to Main.ChangeLog. A number here proves the call
# shape is sound and the environment has rows, so a later zero is about access.
tt_login "e2e_hr" "WEEKLY TO PROCESS"
control="$(tt_authz_expect_count "control (e2e_hr)" "//Main.ChangeLog")"
echo "  control: e2e_hr retrieved $control change-log row(s) with the same call"
if [ "$control" -eq 0 ]; then
  tt_fail "the control retrieve came back empty as HR, so a zero from an anonymous session would prove nothing about access. Run the suite in order so the approval steps produce a transition first."
fi

# ------------------------------------------------- 2. become anonymous, and say so
roles="$(tt_authz_anonymous)"
echo "  anonymous session reports roles $roles"

case "$roles" in
  *Anonymous*) : ;;
  *) tt_fail "after clearing the session the app reported roles $roles, which does not include Anonymous. Either the sign-out did not take (so what follows would be measuring a privileged session) or the app no longer has an anonymous role." ;;
esac

# No privileged role may survive a sign-out. Checked explicitly because the
# assertion above only establishes that Anonymous is present, not that it is alone.
for privileged in Consultant ProjectManager HR TitanManager Administrator; do
  case "$roles" in
    *"\"$privileged\""*)
      echo "FAIL: an unauthenticated session still holds the $privileged role ($roles)."
      echo "      Signing out did not drop it, so every anonymous visitor has it."
      exit 1 ;;
  esac
done

# ------------------------------------------------------- 3. what it cannot read
fails=0
for xpath in $UNREACHABLE; do
  n="$(tt_authz_count "$xpath")"
  case "$n" in
    ERR:no-mx-client)
      tt_fail "the Mendix client API was not available to the anonymous session, so the data layer was never asked about $xpath. This step cannot report a pass without having asked." ;;
    ERR:*)
      # A refused retrieve is the correct outcome: the platform declined outright.
      echo "  anonymous $xpath: the data layer refused the request ($n)" ;;
    ''|*[!0-9]*)
      tt_fail "the anonymous retrieve of $xpath returned something that is not a count: [$n]" ;;
    0)
      echo "  anonymous $xpath: 0 rows" ;;
    *)
      echo "FAIL: an anonymous, unauthenticated session retrieved $n row(s) of $xpath."
      echo "      That entity has no anonymous access rule, so this is reachable by"
      echo "      anyone who knows the app's URL, with no login and no token."
      if [ "$xpath" = "//Main.ApprovalToken" ]; then
        echo "      Main.ApprovalToken rows are the tokens that let a customer approve a"
        echo "      timesheet without signing in - listing them is enough to approve"
        echo "      other people's hours."
      fi
      echo "      The fix belongs on the entity access rules, not on any screen."
      fails=$((fails+1)) ;;
  esac
done

[ "$fails" -eq 0 ] || exit 1
echo "PASS: verify-anonymous-data-denial - an anonymous session holds only Anonymous and retrieved nothing from Main.ChangeLog or Main.ApprovalToken (control: HR saw $control change-log row(s))"
