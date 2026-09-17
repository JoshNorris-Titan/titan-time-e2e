#!/usr/bin/env bash
# Password refresh, step 1 of 2: set every test account's password AWAY and BACK, so the
# clock that eventually turns these logins into a forced password reset starts again.
#
# tt-timeout: 75m
#
# WHAT IT DOES, PER ACCOUNT
# -------------------------
#     original -> temp1 -> temp2 -> original
#
# Three form submits, all of them as the administrator through
# Administration.Account_Overview -> Edit Account -> Change password. The account's
# password is the same at the end of this step as it was at the start, so NO SECRET
# CHANGES: TT_ROLE_PASS, TT_MANUAL_PASS, the GitHub secrets and .e2e-autofix.env are all
# still correct afterwards. See pr_temp in refresh.env.sh for why the chain has two
# throwaway hops rather than one.
#
# ACCOUNT-MAJOR, NOT HOP-MAJOR, and this is the one ordering decision that matters. Doing
# all three hops for one account before starting the next means any given login is away
# from its real password for about a minute. The other order -- every account to temp1,
# then every account to temp2 -- would leave all fourteen wrong for the whole run, so a
# crash in the middle would strand fourteen accounts instead of one.
#
# THE ADMIN NEVER NEEDS THE CURRENT PASSWORD, which is what makes this safe to re-run.
# The Change password dialog asks for a new value and a confirmation, nothing else. So an
# account left on a throwaway password by a run that died is fixed by simply running
# again -- there is no state to reconcile and no recovery mode.
#
# IT PROVES NOTHING ABOUT WHETHER THE PASSWORDS WORK. It can't: an administrator setting
# a password cannot tell whether the account can sign in with it. All this step knows is
# that every submit was accepted. verify-zzz-password-verify signs in as all fourteen and
# is the step that actually decides whether the run was a success -- which is why it
# carries the teardown prefix and runs even after this one fails.
#
# PASSWORDS ARE NEVER PRINTED, not even the throwaway ones. They are derived from
# TT_ROLE_PASS (see pr_temp), so a temp value in a CI log leaks the real secret in a form
# GitHub's masking will not catch. The log names the account and the hop -- "temp 1",
# "restore" -- and nothing else.
#
# Env:
#   TT_BASE_URL     REQUIRED
#   TT_ADMIN_USER   default MxAdmin
#   TT_ADMIN_PASS   REQUIRED -- Account Overview is administrator-only
#   TT_ROLE_PASS    the e2e_* password
#   TT_MANUAL_PASS  the manual_* password; defaults to TT_ROLE_PASS
#   PR_ONLY         churn a single account
#   PR_UNBLOCK      1 = also clear a failed-login lockout when one is found (default off)
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test works
# at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_accounts.sh"
source "$TT_ROOT/password-refresh/refresh.env.sh"

# TT_BASE_URL and TT_ROLE_PASS are asserted by refresh.env.sh, which refuses to define a
# roster at all without them -- deliberately, so neither step can be the one that forgets.
# Only the administrator credential is this step's own requirement.
ADMIN_U="${TT_ADMIN_USER:-MxAdmin}"
ADMIN_P="${TT_ADMIN_PASS:-}"
[ -n "$ADMIN_P" ] || tt_fail "TT_ADMIN_PASS is not set -- Administration.Account_Overview is administrator-only"

DONE=0
SKIPPED=0
PROBLEMS=""
STRANDED=""

problem() { PROBLEMS="$PROBLEMS\n    $*"; pr_log "FAIL  $*"; }

# stranded <user> <why> -- the account is NOT on its real password and this step could not
# put it back. Tracked apart from every other failure because it is the only outcome that
# leaves the environment worse than it found it, and the report has to lead with it.
stranded() { STRANDED="$STRANDED\n    $*"; pr_log "STRANDED  $*"; }

pr_log "refreshing ${#PR_ACCOUNTS[@]} account(s) on $TT_BASE as $ADMIN_U"
acct_admin_login "$ADMIN_U" "$ADMIN_P"

for row in "${PR_ACCOUNTS[@]}"; do
  IFS='|' read -r user group _ready <<< "$row"
  pr_selected "$user" || continue

  orig="$(pr_password "$group")" || { problem "$user: unknown password group '$group'"; continue; }
  t1="$(pr_temp 1 "$orig")"
  t2="$(pr_temp 2 "$orig")"

  pr_log "--- $user ($group)"

  # Read the lockout flag before touching anything. A blocked account's password can be
  # changed perfectly well by an administrator, so this is not a blocker here -- but it IS
  # why verify-zzz would then report "the restored password does not work" for an account
  # whose password is entirely correct. Saying so now makes that attributable.
  state="$(acct_state "$user")"
  case "$state" in
    ABSENT)
      problem "$user: no such account on $TT_BASE -- the roster in refresh.env.sh names an account that does not exist"
      continue ;;
    ERR:*)
      pr_log "note: could not read $user's state ($state); continuing" ;;
    *"Blocked=true"*)
      if [ "${PR_UNBLOCK:-0}" = "1" ]; then
        acct_unblock "$user" || problem "$user: is blocked and the flag could not be cleared -- $ACCT_LAST_ERROR"
      else
        pr_log "note: $user is BLOCKED (failed-login lockout). Its password will still be refreshed, but it cannot sign in until the flag is cleared -- re-run with PR_UNBLOCK=1, or clear it on Accounts Overview."
      fi ;;
  esac

  # --- the two throwaway hops ----------------------------------------------------
  #
  # A REFUSED hop (exit 2) is survivable and is deliberately not fatal: the account's
  # password is unchanged, so the chain is simply one hop shorter than planned. A
  # MECHANICAL failure (exit 1) means nothing is known about what the form did, so stop
  # walking forward and go straight to the restore.
  moved=0
  broke=""
  for hop in 1 2; do
    case "$hop" in 1) val="$t1" ;; 2) val="$t2" ;; esac
    acct_set_password "$user" "$val"
    case "$?" in
      0) moved=1; pr_log "ok    $user -> temp $hop" ;;
      2) pr_log "note  $user -> temp $hop refused, password unchanged: $ACCT_LAST_ERROR" ;;
      *) broke="$ACCT_LAST_ERROR"
         pr_log "note  $user -> temp $hop failed mechanically: $ACCT_LAST_ERROR"
         break ;;
    esac
  done

  # --- the restore ---------------------------------------------------------------
  #
  # Attempted no matter what happened above, including after a mechanical failure: if that
  # failure happened AFTER a form was submitted, the account may already be on a throwaway
  # password, and the one thing worse than not refreshing it is leaving it there.
  acct_set_password "$user" "$orig"
  rc=$?

  if [ "$rc" -eq 2 ] && [ "$moved" -eq 1 ]; then
    # Refused while the account is known to be away from its real password. Under a
    # history-of-one rule this is exactly the deadlock pr_temp's two-hop chain exists to
    # avoid, so something is off -- but one more throwaway hop breaks any such cycle, and
    # trying it costs seconds against an account that is currently unusable.
    pr_log "note  $user: the restore was refused while the account is on a throwaway password -- inserting a rescue hop"
    acct_set_password "$user" "$(pr_temp 3 "$orig")" >/dev/null 2>&1
    acct_set_password "$user" "$orig"
    rc=$?
  fi

  case "$rc" in
    0)
      if [ "$moved" -eq 1 ]; then
        DONE=$((DONE + 1))
        pr_log "ok    $user restored -- password refreshed"
      else
        # Nothing moved, so the restore was a no-op and the account still holds the
        # password it started with. Safe, but NOT refreshed: whatever clock this job
        # exists to reset was not reset, and saying "ok" would hide that.
        SKIPPED=$((SKIPPED + 1))
        problem "$user: both throwaway hops were refused, so the password was never actually changed and nothing was refreshed. The account is UNHARMED and still on its original password. Check the app's password rules against pr_temp in refresh.env.sh."
      fi ;;
    2)
      if [ "$moved" -eq 1 ]; then
        stranded "$user: is on a THROWAWAY password and the app refused to set the original back -- $ACCT_LAST_ERROR"
      else
        SKIPPED=$((SKIPPED + 1))
        problem "$user: every hop was refused, including the restore, so nothing changed. The account is UNHARMED and still on its original password -- $ACCT_LAST_ERROR"
      fi ;;
    *)
      if [ "$moved" -eq 1 ]; then
        stranded "$user: MAY be on a throwaway password -- the restore failed mechanically and the outcome is unknown: $ACCT_LAST_ERROR"
      else
        problem "$user: could not be refreshed -- ${broke:-$ACCT_LAST_ERROR}"
      fi ;;
  esac
done

echo ""
pr_log "refreshed: $DONE   not refreshed: $SKIPPED   stranded: $(printf '%b' "$STRANDED" | grep -c . || true)"

if [ -n "$STRANDED" ]; then
  {
    echo "FAIL: verify-200-password-refresh -- ACCOUNTS ARE LEFT ON A THROWAWAY PASSWORD:"
    printf '%b\n' "$STRANDED"
    echo ""
    echo "      These logins are BROKEN until they are put back. The nightly will fail on"
    echo "      them. Two ways to fix it, in order of preference:"
    echo ""
    echo "        1. Re-run this workflow. The administrator does not need to know an"
    echo "           account's current password to set a new one, so a second pass walks the"
    echo "           chain again and lands on the original with no recovery mode needed."
    echo "        2. By hand: Admin Hub -> Accounts Overview -> filter the login ->"
    echo "           Edit Account -> Change password -> type the TT_ROLE_PASS (or"
    echo "           TT_MANUAL_PASS) value."
    echo ""
    echo "      Do NOT use the row's 'Force Reset Password' action. That arms the very"
    echo "      forced-reset state this job exists to prevent."
  } >&2
  [ -n "$PROBLEMS" ] && { echo "      Other problems this run:" >&2; printf '%b\n' "$PROBLEMS" >&2; }
  exit 1
fi

if [ -n "$PROBLEMS" ]; then
  {
    echo "FAIL: verify-200-password-refresh -- every account still holds its original"
    echo "      password (nothing is stranded), but the refresh did not do its job:"
    printf '%b\n' "$PROBLEMS"
  } >&2
  exit 1
fi

echo "PASS: verify-200-password-refresh -- $DONE account(s) churned away and back on $TT_BASE"
