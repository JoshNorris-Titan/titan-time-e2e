#!/usr/bin/env bash
# verify-session-identity.test.sh
#
# When a step says it is logged in as someone, it really is.
#
# WHY THIS EXISTS. The suite shares ONE browser session across every step and
# caches an authentication state per identity, to avoid re-logging-in constantly.
# That cache used to be accepted on landing text alone: replay the cookie, look
# for a phrase on the page, carry on. Which is not proof of identity. Two roles
# can share a landing phrase, and a replayed cookie belongs to whoever was logged
# in when it was written - so a cache hit could hand a step the wrong user while
# looking perfectly healthy, and every assertion after it would be describing
# somebody else's data.
#
# It is a nasty failure precisely because it does not look like one. Nothing goes
# red; the results are simply about the wrong person. Every role-scoped step, and
# all of verify-consultant-data-isolation, rests on this being right.
#
# The login helper now checks who the session actually belongs to as well. This
# step is the proof that it does, and the guard against it being loosened later.
#
# WHAT IT ASSERTS
#   * each role account, logged in one after another, yields a session whose user
#     is that account and not the previous one;
#   * returning to an earlier identity does not resurrect the wrong session from
#     the cache - the case the landing-text check could not see, and the reason
#     the list below ends where it started;
#   * the identity probe itself works, so a pass cannot come from it quietly
#     returning nothing.
#
# Read-only. Logs in, reads who it is, moves on.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# si_whoami - the username the CURRENT session belongs to, per the Mendix client.
# The same expression lib/_seed.sh uses. Empty means the probe could not read it.
si_whoami() {
  playwright-cli eval "() => { try { return String(mx.session.userObject.jsonData.attributes.Name.value || ''); } catch (e) { return ''; } }" 2>/dev/null | _tt_eval_str
}

# The roles, with the landing text each is known to reach - taken from the steps
# that already log in as them, not guessed. The list ends by revisiting the first
# identity: that return trip is what exercises the cache rather than a fresh login.
ROLES="e2e_consultant|My Timesheets
e2e_hr|WEEKLY TO PROCESS
e2e_pm|Project Manager Dashboard
e2e_tm|Add Customer
e2e_consultant|My Timesheets"

# ------------------------------------------------- 0. the probe must work at all
tt_login "e2e_hr" "WEEKLY TO PROCESS"
probe="$(si_whoami)"
if [ -z "$probe" ]; then
  tt_fail "the session-identity probe returned nothing, so this step cannot tell who it is logged in as. Every assertion below would pass vacuously; refusing to report a result."
fi
note "probe works (session reports '$probe')"

# ------------------------------------------------------- 1. each role is itself
# Read from a here-document rather than a pipe. A piped while loop runs in a
# subshell, so every failure it counted would be discarded on the way out and the
# step would report success whatever it found - the exact bug class this suite
# spent Tier 0 removing.
prev=""
step=0
while IFS='|' read -r user ready; do
  [ -n "$user" ] || continue
  step=$((step + 1))
  if ! tt_login "$user" "$ready"; then
    bad "$step could not log in as '$user'"
    continue
  fi
  who="$(si_whoami)"
  if [ "$who" = "$user" ]; then
    note "$step $user -> session is '$who'"
  elif [ -z "$who" ]; then
    bad "$step logged in as '$user' but the session reports no user at all"
  elif [ -n "$prev" ] && [ "$who" = "$prev" ]; then
    bad "$step logged in as '$user' but the session still belongs to '$who', the PREVIOUS identity - a cached state was replayed without checking whose it was"
  else
    bad "$step logged in as '$user' but the session belongs to '$who'"
  fi
  prev="$user"
done <<ROLELIST
$ROLES
ROLELIST

# --------------------------------------------------------------------- verdict
if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-session-identity - $fails identity mismatch(es)."
  echo "      A step that believes it is one user while the session is another does not go"
  echo "      red on its own; it quietly reports the wrong person's data. Treat this as"
  echo "      higher priority than any single failing scenario."
  exit 1
fi

echo "PASS: verify-session-identity - every role login yields that role's session, including on the return trip through the cache"
