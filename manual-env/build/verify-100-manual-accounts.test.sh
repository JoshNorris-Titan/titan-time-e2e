#!/usr/bin/env bash
# Manual environment, step 1 of 3: PROVE every manual_* login exists and lands on the
# dashboard its role should land on.
#
# tt-timeout: 25m
#
# WHY THIS IS A SEPARATE STEP AND WHY IT COMES FIRST
# -------------------------------------------------
# Nothing in manual-env/ creates an account, deliberately — see the note above
# MANUAL_ACCOUNTS in manual.env.sh. Everything downstream then assumes they exist:
# verify-110 signs in as manual_tm to build structure and picks 'Manual ProjectManager'
# out of a combobox, and verify-120 signs in as three consultants and as manual_hr.
#
# Without this step a missing account surfaces as whichever of those happens to run
# first, and the message is about the thing that failed rather than the thing that is
# missing — "project manager 'Manual ProjectManager' not selectable" when the real
# answer is that nobody created manual_pm. That is the exact failure shape lib/_fixtures.sh
# was written to stop for the E2E set, one level earlier.
#
# IT REPORTS ALL OF THEM, NOT THE FIRST
# -------------------------------------
# tt_login ends in tt_fail, which exits. Calling it in a SUBSHELL contains that exit, so
# the loop can try every account and print one list at the end. The alternative — reading
# the admin Accounts Overview and searching for each name — was rejected: it proves a row
# exists, not that the credentials work and not that the role is right, and those are the
# two things that actually block the rest of the run.
#
# The landing text per account is the role check. An account created with the wrong role
# authenticates perfectly and lands somewhere else, so waiting for the dashboard text is
# what turns "created, but as a plain Consultant" into a named failure here rather than a
# confusing seeding error twenty minutes later.
#
# THIS STEP WILL FAIL UNTIL THE ACCOUNTS ARE CREATED. That is its job. The message names
# every missing login and points at the one-time recipe in manual-env/README.md.
#
# Env:
#   TT_BASE_URL      REQUIRED
#   TT_MANUAL_PASS   manual_* password, defaults to TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test works
# at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/manual-env/manual.env.sh"

[ -n "${TT_BASE_URL:-}" ] \
  || tt_fail "TT_BASE_URL must be set explicitly — the Manual environment steps write data and must never fall back to a default environment"

OK=0
MISSING=""

for row in "${MANUAL_ACCOUNTS[@]}"; do
  IFS='|' read -r user full role empl ready <<< "$row"

  # Subshell: tt_login exits on failure, and we want the whole list, not the first gap.
  # Its own diagnosis goes to stderr and is captured here so a genuine surprise (an app
  # that will not render a login form at all) is still readable in the report.
  # TT_AUTH_CACHE=0, deliberately. tt_login normally reuses a saved storage state, and
  # _tt_auth_try accepts it on identity plus landing text WITHOUT re-authenticating — so a
  # still-valid cookie in .auth/ would satisfy this step whatever the password is, and the
  # one thing this preflight exists to prove is that these credentials work. In CI the
  # checkout has no .auth/ at all, so this only changes local runs; it changes them from
  # "cannot fail" to "actually checks".
  if out="$( ( TT_AUTH_CACHE=0 tt_login "$user" "$ready" ) 2>&1 )"; then
    OK=$((OK + 1))
    manual_log "ok      $user -> '$ready'  ($full, $role/$empl)"
  elif [ "$(playwright-cli eval "() => { let n=''; try { n=mx.session.userObject.jsonData.attributes.Name.value; } catch(e){} return String(n==='$user' && (document.body?document.body.innerText:'').indexOf('$ready')>=0); }" 2>/dev/null | _tt_eval_str)" = "true" ]; then
    # DO NOT BELIEVE tt_login's FAILURE WITHOUT CHECKING. Its success test is
    #     location.pathname.indexOf('index.html') >= 0 && body contains <ready>
    # and the pathname half is wrong for the app's own Core.Login page: signing in there
    # leaves the browser on "/", never "/index.html". Whether a given login routes via
    # /login.html (which redirects, and passes) or Core.Login (which does not) is not
    # deterministic, so the same healthy account can pass one call and fail the next —
    # measured on manual_consultant, 2026-09-09, twice within a minute.
    #
    # This step gates an hour-long build, so a coin-flip here is expensive. Identity plus
    # landing text is the question that matters; the URL is not.
    OK=$((OK + 1))
    manual_log "ok      $user -> '$ready'  ($full, $role/$empl) — signed in at '/' (tt_login wanted /index.html)"
  else
    MISSING="$MISSING\n    $user  ($full, role $role, $empl) — expected to land on '$ready'"
    manual_log "MISSING $user — $(printf '%s' "$out" | tail -1)"
  fi
done

if [ -n "$MISSING" ]; then
  printf 'FAIL: verify-100-manual-accounts — %d of %d Manual accounts could not sign in:%b\n' \
    "$(( ${#MANUAL_ACCOUNTS[@]} - OK ))" "${#MANUAL_ACCOUNTS[@]}" "$MISSING" >&2
  echo "" >&2
  echo "      These are created ONCE and are never provisioned by either workflow. Run:" >&2
  echo "        manual-env/provision-accounts.sh" >&2
  echo "      which creates any that are missing, reads each temporary password out of" >&2
  echo "      Admin Hub -> Emails Sent, and completes the forced reset to TT_ROLE_PASS." >&2
  echo "      Full walkthrough: manual-env/README.md" >&2
  exit 1
fi

echo "PASS: verify-100-manual-accounts — all $OK Manual accounts signed in and landed correctly on $TT_BASE"
