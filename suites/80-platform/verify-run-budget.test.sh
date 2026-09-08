#!/usr/bin/env bash
# verify-run-budget.test.sh
#
# The suite knows how many steps it is supposed to have, and says so when that
# changes. No browser, no app, about a second.
#
# WHY THIS EXISTS. run-tests.sh already solves this with --expect-count, and its
# own comment says "CI should always pass --expect-count". CI does not pass it.
# So today a test that is renamed out of the verify-*.test.sh glob, or a folder
# that stops being discovered, produces a run that reports "82 tests: 82 passed"
# and a green tick - the run itself cannot fail, which is the failure mode this
# suite has already been bitten by once (see suites/10-smoke/verify-helper-selftest
# and the note about a green tick that ran nothing).
#
# The right fix is one line in .github/workflows/e2e.yml. That is a workflow
# change, which the autofix loop is forbidden to make and which needs a human, so
# this stands in for it from INSIDE the suite - where a step is just another step
# and needs nobody's permission to run.
#
# HOW IT WORKS. suites/expected-count.txt holds the number. This counts what the
# runner would discover, using the runner's own glob, and fails when the two
# disagree. Adding a test is therefore deliberately a TWO-file change: the test,
# and the number. That is the whole point - an accidental disappearance and a
# deliberate addition look identical to everything else in the repo.
#
# NOT A DUPLICATE OF --expect-count. That flag guards the run from outside and
# still should be passed; this guards it from inside, and the two disagree only
# if someone passes a stale number on the command line, which is worth knowing
# too.
#
# WHY NOT ASSERT WALL-CLOCK BUDGET TOO. Because a step cannot see the run's
# elapsed time, and a per-step timing assertion on shared cloud dev is a flake
# generator. The count is the half that can be checked honestly.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"

EXPECTED_FILE="$TT_ROOT/suites/expected-count.txt"

[ -f "$EXPECTED_FILE" ] \
  || { echo "FAIL: $EXPECTED_FILE is missing - this step cannot say what the suite should contain."; exit 1; }

# Strip comments and blanks; the file is one number plus an explanation.
EXPECTED="$(grep -vE '^[[:space:]]*(#|$)' "$EXPECTED_FILE" | head -1 | tr -d '[:space:]')"
case "$EXPECTED" in
  ''|*[!0-9]*) echo "FAIL: $EXPECTED_FILE does not begin with a number (read: [$EXPECTED])"; exit 1 ;;
esac

# The runner's own discovery, verbatim: find -name 'verify-*.test.sh' -type f
# under suites/. Kept identical on purpose - a cleverer count here would be
# measuring something the runner does not.
ACTUAL="$(find "$TT_ROOT/suites" -name 'verify-*.test.sh' -type f | wc -l | tr -d '[:space:]')"

if [ "$ACTUAL" -ne "$EXPECTED" ]; then
  echo "FAIL: the suite discovers $ACTUAL test(s); suites/expected-count.txt says $EXPECTED."
  echo ""
  if [ "$ACTUAL" -lt "$EXPECTED" ]; then
    echo "      $(( EXPECTED - ACTUAL )) test(s) VANISHED from discovery. That is the"
    echo "      dangerous direction: a renamed file, a folder that stopped matching, or a"
    echo "      deletion. None of those turn the run red on their own - the runner simply"
    echo "      reports fewer tests, all passing, and CI shows a green tick."
  else
    echo "      $(( ACTUAL - EXPECTED )) test(s) were ADDED without updating the number."
    echo "      That is the harmless direction, and the fix is to write the new figure in"
    echo "      suites/expected-count.txt as part of the same change."
  fi
  echo ""
  echo "      Run ./run-tests.sh --list to see exactly what is discovered."
  echo "      Update suites/expected-count.txt DELIBERATELY - never to make this pass."
  exit 1
fi

echo "PASS: verify-run-budget - the suite discovers $ACTUAL tests, which is what suites/expected-count.txt declares"
