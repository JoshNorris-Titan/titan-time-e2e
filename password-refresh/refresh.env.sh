#!/usr/bin/env bash
# Password refresh -- the single source of truth for WHICH accounts get churned and WHAT
# they get churned to.
#
# WHAT THIS DIRECTORY IS FOR
# --------------------------
# Left alone, the test accounts on cloud dev eventually start demanding a password reset,
# and when that happens the nightly does not fail with "the password is wrong" -- it fails
# with whatever the first step to hit a Core.Force_PasswordReset screen happens to be
# doing. lib/_login.sh already tells those two apart (state 2 vs state 1) precisely
# because the confusion cost real debugging time.
#
# So once a week, every one of these accounts has its password SET AWAY and SET BACK. The
# password ends the run exactly as it started, and whatever clock counts towards "this
# password is old" starts again. It is a keep-alive, not a rotation: no secret changes, so
# nothing in GitHub, .e2e-autofix.env or anyone's notes has to be updated afterwards.
#
# THE ROSTER IS AN ALLOWLIST, AND THAT IS THE POINT
# -------------------------------------------------
# Dev carries far more accounts than these -- real people (mindy-hr, warren-tm,
# rishika-consultant, ...), demo logins and one-off test users were all in the grid on
# 2026-09-09. A step that walked the Accounts Overview grid and churned what it found
# would change the password of a colleague's login. Nothing here ever reads the grid for
# candidates: it acts on the names below and on nothing else.
#
# MxAdmin IS DELIBERATELY ABSENT. It is the credential this run authenticates WITH, so
# churning it means changing the password out from under the session doing the changing --
# and if the restore half then failed, the result is not one broken test account but a
# TT_ADMIN_PASS secret that no longer works, which locks every workflow out of the
# environment including this one. If the admin password ever needs the same treatment,
# that is a deliberate, watched, by-hand job.
#
# HOW TO SOURCE IT
#   TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
#   source "$TT_ROOT/lib/_login.sh"
#   source "$TT_ROOT/lib/_accounts.sh"
#   source "$TT_ROOT/password-refresh/refresh.env.sh"
#
# Env:
#   TT_BASE_URL      REQUIRED. No default -- this writes credentials.
#   TT_ADMIN_USER    the administrator whose session does the changing (default MxAdmin)
#   TT_ADMIN_PASS    REQUIRED. Account Overview is administrator-only
#   TT_ROLE_PASS     the password the e2e_* accounts have, and end up with again
#   TT_MANUAL_PASS   same for manual_*; defaults to TT_ROLE_PASS
#   PR_TEMP_SALT     overrides the throwaway-password prefix (see pr_temp)
#   PR_ONLY          one username, to churn a single account

# ---------------------------------------------------------------- the two passwords
#
# THE TARGET IS NEVER IMPLIED, for the same reason the runner refuses to guess one: this
# directory writes CREDENTIALS, and a wrong guess is indistinguishable from environment
# drift in the output. lib/_login.sh has already defaulted TT_BASE to localhost by the
# time this file is sourced, so the check has to be on TT_BASE_URL itself.
[ -n "${TT_BASE_URL:-}" ] \
  || tt_fail "TT_BASE_URL must be set explicitly -- this directory changes credentials and must never fall back to lib/_login.sh's localhost default"

# READ FROM TT_ROLE_PASS DIRECTLY, AND NEVER FROM TT_PASS. This looked like a harmless
# widening at first and is the most dangerous line in the directory if it is:
#
#     TT_PASS="${TT_ROLE_PASS:-E2ETest123!}"          # lib/_login.sh, at source time
#
# lib/_login.sh is sourced BEFORE this file and defaults TT_PASS to a password hardcoded
# for local convenience. So a `${TT_ROLE_PASS:-$TT_PASS}` fallback can never be empty, the
# "is it set?" guard below could never fire, and a CI run whose TT_ROLE_PASS secret was
# missing or blank would cheerfully churn all fourteen deployed accounts and "restore"
# them to `E2ETest123!` -- CHANGING the real password on a shared environment and
# reporting PASS, because the verification step would then confirm the value it had just
# set. The suite's README says the lib defaults must never be relied on against a deployed
# environment; here that is not a style preference, it is the difference between a
# keep-alive and a silent rotation nobody asked for.
#
# Hence: no fallback, and a hard refusal. It lives in this file rather than in the two
# steps so the roster cannot be sourced at all without a real password behind it.
PR_ROLE_PASS="${TT_ROLE_PASS-}"
[ -n "$PR_ROLE_PASS" ] \
  || tt_fail "TT_ROLE_PASS is not set (or is empty). Refusing to continue: lib/_login.sh would have supplied its local default 'E2ETest123!', and this directory would then set every e2e_* account's password TO that value on $TT_BASE and report success. Pass the real secret."

PR_MANUAL_PASS="${TT_MANUAL_PASS:-$PR_ROLE_PASS}"

# ---------------------------------------------------------------- the roster
#
# username|password group|landing text
#
# The landing text is not decoration: it is what the verification step waits for, and so
# it is also the cheapest proof that the account came back with its ROLE intact. An
# account whose password is fine but whose roles were lost authenticates perfectly and
# renders something else entirely.
#
# The e2e half is declared here because the suite has no single canonical array of its
# role accounts -- lib/_fixtures.sh carries display names (FX_CONSULTANTS), not logins.
# The seven below are the set README.md documents, plus e2e_consultant3, which that list
# omits but which the seeders write timesheets for and lib/_testdata.sh clears.
PR_ACCOUNTS=(
  "e2e_consultant|role|My Timesheets"
  "e2e_consultant2|role|My Timesheets"
  "e2e_consultant3|role|My Timesheets"
  "e2e_pm|role|Project Manager Dashboard"
  "e2e_pm2|role|Project Manager Dashboard"
  "e2e_hr|role|WEEKLY TO PROCESS"
  "e2e_tm|role|Add Customer"
)

# The manual half, declared the same way.
#
# DECLARED HERE RATHER THAN SOURCED FROM manual-env/manual.env.sh, which is what this file
# did first and which was wrong for two separate reasons:
#
# 1. IT WOULD NOT SURVIVE CI. manual-env/ is a working directory that is not committed --
#    actions/checkout would hand the runner a tree without it, and the `source` line would
#    abort this job before it read a single account. A scheduled workflow may not depend on
#    a file that only exists on somebody's laptop.
# 2. SOURCING IT HAS A SIDE EFFECT. manual.env.sh ends with
#
#        if [ -n "${TT_MANUAL_PASS:-}" ]; then TT_PASS=...; TT_ROLE_PASS="$TT_MANUAL_PASS"; fi
#
#    which OVERWRITES TT_ROLE_PASS. That is right for a directory that only ever drives the
#    Manual data set and wrong here, where both sets are in scope at once: it would set
#    every e2e_* account to the manual password and then "restore" it to the same wrong
#    value. It was worked around by capturing and restoring; not sourcing it at all is a
#    better answer than remembering to undo it.
#
# The cross-check below keeps the copies honest, which is what sourcing was really for.
PR_ACCOUNTS+=(
  "manual_consultant|manual|My Timesheets"
  "manual_consultant2|manual|My Timesheets"
  "manual_consultant3|manual|My Timesheets"
  "manual_pm|manual|Project Manager Dashboard"
  "manual_pm2|manual|Project Manager Dashboard"
  "manual_hr|manual|WEEKLY TO PROCESS"
  "manual_tm|manual|Add Customer"
)

# pr_check_manual_roster -- when manual-env/ IS present (a local checkout, not CI), read
# MANUAL_ACCOUNTS out of it and fail if it has grown, shrunk, or been renamed relative to
# the list above.
#
# Read in a SUBSHELL so manual.env.sh's TT_ROLE_PASS assignment cannot reach this shell.
# That is the whole trick: the drift protection that sourcing was for, with none of the
# coupling that made it unsafe. An eighth manual_* account added for a reviewer now stops
# a local run with a message naming it, instead of being silently left to age into the
# forced reset this job exists to prevent -- and CI, which has no manual-env/ to check
# against, simply skips the comparison rather than failing on its absence.
pr_check_manual_roster() {
  local env_file="$TT_ROOT/manual-env/manual.env.sh" theirs mine
  [ -r "$env_file" ] || { pr_log "note: manual-env/ is not in this checkout, so the manual_* roster could not be cross-checked (expected in CI)"; return 0; }

  theirs="$(
    # shellcheck disable=SC1090
    source "$env_file" >/dev/null 2>&1
    for r in "${MANUAL_ACCOUNTS[@]}"; do printf '%s\n' "${r%%|*}"; done | sort
  )"
  mine="$(for r in "${PR_ACCOUNTS[@]}"; do case "$r" in *"|manual|"*) printf '%s\n' "${r%%|*}" ;; esac; done | sort)"

  [ -n "$theirs" ] || { pr_log "note: manual-env/manual.env.sh defined no MANUAL_ACCOUNTS; skipping the cross-check"; return 0; }
  [ "$theirs" = "$mine" ] && return 0

  tt_fail "the manual_* roster in password-refresh/refresh.env.sh has drifted from MANUAL_ACCOUNTS in manual-env/manual.env.sh.
    only in manual-env: $(comm -23 <(printf '%s\n' "$theirs") <(printf '%s\n' "$mine") | tr '\n' ' ')
    only here:          $(comm -13 <(printf '%s\n' "$theirs") <(printf '%s\n' "$mine") | tr '\n' ' ')
  An account missing from here is never refreshed and will eventually demand a password reset. Reconcile the two lists."
}

pr_log() { echo "  [refresh] $*"; }

# pr_password <group> -- the password an account in that group has, and must end up with.
pr_password() {
  case "$1" in
    role)   printf '%s' "$PR_ROLE_PASS" ;;
    manual) printf '%s' "$PR_MANUAL_PASS" ;;
    *)      return 1 ;;
  esac
}

# pr_temp <n> <original> -- the nth throwaway password in the chain.
#
# DERIVED FROM THE ORIGINAL, NOT A LITERAL. A fixed string committed here would be a real
# password that briefly opens seven or fourteen accounts on a deployed environment, in a
# file anyone with repo access can read. Derived, it is only computable by something that
# already holds TT_ROLE_PASS -- and it is never printed: see the note on logging in
# verify-200.
#
# WHY THERE ARE TWO OF THEM AND NOT ONE
# -------------------------------------
# The obvious chain is original -> temp -> original, and it works only if the app's
# no-reuse rule means "the new password may not be the one you have right now". If it
# means "the new password may not be the one you had immediately before" -- history of one
# -- then the last hop is refused, because the password immediately before temp was the
# original. Josh's answer ("it only blocks reusing your last password") reads the first
# way, but the two readings are one word apart and the cost of being wrong is every
# account stranded on a throwaway password.
#
#   original -> temp1 -> temp2 -> original
#
# survives both readings, and stays true week after week: at the final hop the current
# password is temp2 and the previous one is temp1, so the original collides with neither.
# The price is one extra form submit per account, which is the cheapest insurance in this
# directory.
PR_TEMP_SALT="${PR_TEMP_SALT:-Rx7!}"
pr_temp() {
  printf '%s%s%s' "$PR_TEMP_SALT" "$2" "$1"
}

# pr_selected <username> -- is this account in scope? (PR_ONLY narrows a run to one.)
pr_selected() { [ -z "${PR_ONLY:-}" ] || [ "${PR_ONLY}" = "$1" ]; }

# Run the drift check at source time, so BOTH steps get it and neither can be the one that
# forgets. It is deliberately last: it calls pr_log, and a check that aborted the shell
# before the helpers existed would report the drift with a "command not found".
pr_check_manual_roster
