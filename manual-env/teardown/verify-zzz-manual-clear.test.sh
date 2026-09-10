#!/usr/bin/env bash
# Manual environment teardown: delete everything the build made, and NOTHING ELSE.
#
# tt-timeout: 20m
#
# WHAT IT DELETES
# ---------------
# Drives the per-consultant "Clear data + structure" control on Core.TestData_Admin for
# each Manual consultant — the same helper the e2e bookends use, pointed at the Manual
# names instead of the E2E ones. At depth=deep that removes, per consultant: timesheets,
# entries, line items, attachments, expense reports, PDFs, approval workflows, change
# logs and approval emails, PLUS their assignments and the projects those assignments
# were on.
#
# WHAT IT LEAVES STANDING
# -----------------------
# The accounts. All seven manual_* logins survive, which is the whole contract of this
# workflow: they are created once, by hand, and every build/teardown cycle runs between
# them. The customer (Costco by default) survives too — it is shared with the E2E set and
# with real dev data, and no clear at any depth touches customers.
#
# WHY IT CANNOT REACH THE E2E DATA
# --------------------------------
# The per-consultant control is scoped to the consultant it is invoked on, and the only
# way it reaches past them is through a shared PROJECT: deleting a project cascades into
# other consultants' assignments on it. So the blast radius is exactly "projects a Manual
# consultant is assigned to", and MANUAL_ASSIGNMENTS points only at MANUAL_PROJECTS.
# Keep that true and the two data sets cannot damage each other. The isolation note at
# the top of manual.env.sh is the full version of this argument.
#
# The GLOBAL controls on that page ("Clear out all data", "Clear out all data and
# structure") are never used here, for the same reason the e2e suite never uses them:
# they delete every consultant's data on a shared dev environment, including work in
# progress that belongs to a person.
#
# IT VERIFIES THE RESULT INSTEAD OF TRUSTING THE CLICK
# ----------------------------------------------------
# tt_clear_consultant_testdata already waits for the app's own confirmation message per
# consultant, so a clear that silently did nothing is caught there. What it cannot tell
# you is whether the environment as a WHOLE came out clean — a Manual project created
# without an assignment, for instance, is attached to no consultant and no clear will ever
# reach it. The checks below read the real rows back through the data API and name what
# survived, because a teardown that reports success over leftover structure is how the
# next build inherits a half-state nobody designed.
#
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS
#      TT_E2E_CONSULTANTS is set from MANUAL_CONSULTANTS below and must NOT be inherited —
#      see the note at the assignment.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test works
# at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_testdata.sh"
source "$TT_ROOT/manual-env/manual.env.sh"

[ -n "${TT_BASE_URL:-}" ] \
  || tt_fail "TT_BASE_URL must be set explicitly — this DELETES data and must never fall back to a default environment"

# OVERWRITTEN, NOT DEFAULTED. lib/_testdata.sh reads TT_E2E_CONSULTANTS from the
# environment, and in CI that variable is a repository secret holding the E2E names. If
# this file merely defaulted it, a teardown dispatched from GitHub would clear the E2E
# consultants — deleting the nightly's data and, through the project cascade, structure
# the Manual set depends on. The assignment is unconditional on purpose.
TT_E2E_CONSULTANTS="$(manual_consultant_names)"
TT_E2E_CLEAR_DEPTH="deep"

[ -n "$TT_E2E_CONSULTANTS" ] \
  || tt_fail "MANUAL_CONSULTANTS produced no Consultant-role names to clear — refusing to run a clear with an empty scope"

manual_log "clearing (deep): $TT_E2E_CONSULTANTS"
tt_clear_e2e_testdata "manual-teardown"

# ---------------------------------------------------------------- verify the result
#
# The session is the administrator's, left on the Test Data page by the helper above.
# An unreadable answer is treated as a FAILURE for the leftover checks: "I could not ask"
# and "there is nothing left" must never collapse into the same green result.
LEFT=""

OLD_IFS="$IFS"; IFS='|'
for who in $TT_E2E_CONSULTANTS; do
  IFS="$OLD_IFS"
  [ -n "$who" ] || continue

  n="$(manual_xpath_count "//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$who']")"
  case "$n" in
    ERR:*|''|*[!0-9]*) tt_fail "could not count '$who' entries after the clear ($n) — the teardown is unverified, so it cannot report PASS" ;;
    0) manual_log "ok      no entries left for '$who'" ;;
    *) LEFT="$LEFT\n    $n timesheet entr(ies) still attached to '$who'" ;;
  esac

  n="$(manual_xpath_count "//Main.Assignment[ConsultantName = '$who']")"
  case "$n" in
    ERR:*|''|*[!0-9]*) tt_fail "could not count '$who' assignments after the clear ($n) — the teardown is unverified" ;;
    0) manual_log "ok      no assignments left for '$who'" ;;
    *) LEFT="$LEFT\n    $n assignment(s) still attached to '$who'" ;;
  esac
  IFS='|'
done
IFS="$OLD_IFS"

# Projects are matched on the NAME PREFIX rather than per consultant, deliberately: a
# project whose assignments were all deleted is no longer reachable from any consultant,
# and a project that never had one never was. Both are exactly the leftovers worth naming.
PROJECTS="$(manual_names_matching "Main.Project" "Name")"
case "$PROJECTS" in
  ERR:*) tt_fail "could not list remaining '$MANUAL_PREFIX' projects ($PROJECTS) — the teardown is unverified" ;;
  "")    manual_log "ok      no '$MANUAL_PREFIX' projects left" ;;
  *)     LEFT="$LEFT\n    project(s) still present: $PROJECTS" ;;
esac

# The other half of the promise: the accounts must SURVIVE. Read on the username prefix
# ('manual_'), not MANUAL_PREFIX ('Manual '), because those are two different strings.
#
# This one degrades to a note rather than a failure when it cannot be read. It is a
# check on something the clear microflows do not touch at all, so an unreadable answer
# says something about this session's retrieve rights, not about the teardown — and
# turning a successful clear red over that would be the wrong trade. It still fails
# loudly on a number it CAN read that is too low, which is the case that would matter.
WANT_ACCOUNTS="${#MANUAL_ACCOUNTS[@]}"
ACCOUNTS_NOTE="not verified"
HAVE_ACCOUNTS="$(manual_xpath_count "//Administration.Account[starts-with(Name,'manual_')]")"
case "$HAVE_ACCOUNTS" in
  ERR:*|''|*[!0-9]*)
    manual_log "note    could not verify the manual_* accounts survived ($HAVE_ACCOUNTS) — the clear does not delete accounts, but this run did not prove it" ;;
  *)
    if [ "$HAVE_ACCOUNTS" -lt "$WANT_ACCOUNTS" ]; then
      tt_fail "only $HAVE_ACCOUNTS of $WANT_ACCOUNTS manual_* accounts remain after the clear. The accounts are meant to outlive every teardown — do not re-run the build until this is understood, and see manual-env/README.md for how to recreate one."
    fi
    ACCOUNTS_NOTE="$HAVE_ACCOUNTS of $WANT_ACCOUNTS"
    manual_log "ok      $HAVE_ACCOUNTS manual_* account(s) still present" ;;
esac

if [ -n "$LEFT" ]; then
  printf 'FAIL: verify-zzz-manual-clear — the clear ran, but Manual data survived it:%b\n' "$LEFT" >&2
  echo "" >&2
  echo "      The per-consultant control only reaches projects a Manual consultant is" >&2
  echo "      ASSIGNED to, so the usual cause is a project with no assignment — created" >&2
  echo "      by a build that failed between the project and the assignment step." >&2
  echo "      Remove it as manual_tm (Titan Manager -> Projects), or re-run the build to" >&2
  echo "      give it an assignment and then run this teardown again." >&2
  exit 1
fi

echo "PASS: verify-zzz-manual-clear — Manual data and structure cleared on $TT_BASE; accounts left standing: $ACCOUNTS_NOTE ($TT_E2E_CONSULTANTS)"
