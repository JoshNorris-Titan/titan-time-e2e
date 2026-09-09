#!/usr/bin/env bash
# Password refresh, step 2 of 2: PROVE every account still signs in with the password it
# started the run with, and still lands on its own dashboard.
#
# tt-timeout: 30m
#
# THIS IS THE STEP THAT DECIDES WHETHER THE RUN WORKED. verify-200 can only report that
# each form submit was accepted; an administrator changing someone else's password has no
# way to tell whether the account can actually use it. Everything this job exists to
# guarantee -- "no test account needs a password reset" -- is asserted here and nowhere
# else.
#
# WHY IT CARRIES THE verify-zzz- PREFIX
# -------------------------------------
# run-tests.sh treats verify-zzz-* as teardown, so it runs even after a fail-fast abort
# (see is_teardown in run-tests.sh). That is exactly what is wanted: the run where
# verify-200 failed is the run where "which of the fourteen can still log in?" is the most
# valuable question in the log, and a NOTRUN there would answer it with silence. It is not
# a cleanup step; it borrows the prefix for the always-runs property, which is why this
# paragraph exists.
#
# TT_AUTH_CACHE=0 IS NOT OPTIONAL. tt_login normally reuses saved storage state from
# .auth/, and _tt_auth_try accepts it on identity plus landing text WITHOUT
# re-authenticating -- so a cookie left behind by an earlier local run would satisfy this
# step no matter what the password is, and the one thing it exists to prove is that these
# credentials work. In CI the checkout has no .auth/ at all, so this only changes local
# runs: it changes them from "cannot fail" to "actually checks".
#
# IT REPORTS ALL OF THEM, NOT THE FIRST. tt_login ends in tt_fail, which exits; calling it
# in a SUBSHELL contains that exit so the loop can try every account and print one list.
# Fourteen accounts and one failure is a very different morning from fourteen accounts and
# fourteen failures, and the difference has to be in the log.
#
# THE LANDING TEXT IS THE ROLE CHECK. An account whose password is right but whose roles
# were lost authenticates perfectly and renders something else, so waiting for the
# dashboard text is what separates "signed in" from "signed in as the thing it should be".
#
# Env:
#   TT_BASE_URL     REQUIRED
#   TT_ROLE_PASS    the e2e_* password
#   TT_MANUAL_PASS  the manual_* password; defaults to TT_ROLE_PASS
#   PR_ONLY         check a single account
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test works
# at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_accounts.sh"
source "$TT_ROOT/password-refresh/refresh.env.sh"

# TT_BASE_URL and TT_ROLE_PASS are asserted by refresh.env.sh, which refuses to define a
# roster at all without them. That matters more here than anywhere else in the directory:
# with lib/_login.sh's local default silently standing in for a missing TT_ROLE_PASS, this
# step would sign in with 'E2ETest123!', confirm the value verify-200 had just set, and
# report PASS on an environment whose real passwords had been overwritten.

OK=0
CHECKED=0
BROKEN=""
RESETS=""

pr_log "verifying ${#PR_ACCOUNTS[@]} account(s) against $TT_BASE"

for row in "${PR_ACCOUNTS[@]}"; do
  IFS='|' read -r user group ready <<< "$row"
  pr_selected "$user" || continue
  CHECKED=$((CHECKED + 1))

  pass="$(pr_password "$group")" || { BROKEN="$BROKEN\n    $user -- unknown password group '$group'"; continue; }

  if out="$( ( TT_AUTH_CACHE=0 tt_login "$user" "$ready" "$pass" ) 2>&1 )"; then
    OK=$((OK + 1))
    pr_log "ok      $user -> '$ready'"
    continue
  fi

  last="$(printf '%s' "$out" | tail -1)"
  pr_log "BROKEN  $user -- $last"

  # A forced password reset is called out separately from a rejected password, because
  # tt_login already distinguishes them (its state 2 vs state 1) and because they mean
  # opposite things here. A demanded reset means the churn ARMED the very condition this
  # job exists to prevent -- which would make the whole approach wrong, not just this run.
  # A rejected password means the restore did not take. Merging them would hide the first
  # behind the second.
  case "$out" in
    *"demands a password change"*|*"must reset your password"*|*Force_PasswordReset*)
      RESETS="$RESETS\n    $user ($group) -- the credentials were ACCEPTED but the app demands a password change" ;;
    *)
      BROKEN="$BROKEN\n    $user ($group) -- expected to land on '$ready': $last" ;;
  esac
done

echo ""

if [ -n "$RESETS" ]; then
  {
    echo "FAIL: verify-zzz-password-verify -- accounts are being FORCED TO RESET their password:"
    printf '%b\n' "$RESETS"
    echo ""
    echo "      This is the condition the whole password-refresh job exists to prevent, so"
    echo "      finding it here means the refresh CAUSED it rather than deferring it: the"
    echo "      admin Change password dialog arms the force-reset flag. If that is what"
    echo "      happened, this approach cannot work as built -- stop running the schedule"
    echo "      and re-open the design, rather than clearing the flag every week."
    echo ""
    echo "      Clear it for now by signing in as the account once and completing the"
    echo "      reset back to the TT_ROLE_PASS (or TT_MANUAL_PASS) value."
  } >&2
  [ -n "$BROKEN" ] && { echo "      Also could not sign in:" >&2; printf '%b\n' "$BROKEN" >&2; }
  exit 1
fi

if [ -n "$BROKEN" ]; then
  {
    printf 'FAIL: verify-zzz-password-verify -- %d of %d account(s) could not sign in:\n' \
      "$(( CHECKED - OK ))" "$CHECKED"
    printf '%b\n' "$BROKEN"
    echo ""
    echo "      Most likely one of three things, in order of likelihood:"
    echo "        1. verify-200 left the account on a throwaway password. Its own report"
    echo "           says so explicitly if it did -- look for STRANDED. Re-running the"
    echo "           workflow fixes that case."
    echo "        2. The account is BLOCKED by the failed-login lockout, which is"
    echo "           indistinguishable from a wrong password at the login form. verify-200"
    echo "           reports the flag when it sees it; re-run with PR_UNBLOCK=1 to clear it."
    echo "        3. TT_ROLE_PASS / TT_MANUAL_PASS does not match what the account actually"
    echo "           has, in which case this job has been restoring the wrong value and the"
    echo "           secret is what needs fixing."
  } >&2
  exit 1
fi

echo "PASS: verify-zzz-password-verify -- all $OK account(s) signed in with their original password on $TT_BASE"
