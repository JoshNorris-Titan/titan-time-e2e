#!/usr/bin/env bash
# verify-run-budget.test.sh
#
# The suite knows how many steps it is supposed to have, and says so when that
# changes. No browser, no app, about a second.
#
# WHY THIS EXISTS. run-tests.sh solves this with --expect-count, and its own
# comment says "CI should always pass --expect-count". For a long time CI did not,
# so a test renamed out of the verify-*.test.sh glob produced a run reporting
# "82 tests: 82 passed" and a green tick - the run itself could not fail, which is
# the failure mode this suite has already been bitten by once (see
# suites/10-smoke/verify-helper-selftest and the note about a green tick that ran
# nothing).
#
# The nightly NOW passes --expect-count. This step is still not redundant: it
# guards from inside the suite, so it also covers a local run, a manual dispatch,
# and the case where CI is passing a stale number on the command line. It needs
# nobody's permission to run and the autofix loop cannot edit it away, because the
# loop is forbidden to touch workflows.
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

# --------------------------------------------------- the README's headline totals
#
# The badge and the intro table are the first two numbers anybody reads, and they
# had drifted three ways at once: the badge said 51, the intro said 51, the
# walkthrough header said 91, and the suite discovered 96. Nothing checked them,
# because they are prose. They are mechanical enough to check, so check them.
#
# Only the two TOTALS are policed. The walkthrough's per-step numbering (step 51,
# steps 51-52) is a different sequence and is not derived from this count, so it is
# deliberately left alone - a guard that failed every time a step was inserted
# mid-list would be turned off within a week.
README="$TT_ROOT/README.md"
if [ -f "$README" ]; then
  doc_fails=0

  badge="$(grep -o 'badge/steps-[0-9]\+-' "$README" | head -1 | sed 's/badge\/steps-//; s/-$//')"
  if [ -z "$badge" ]; then
    echo "FAIL: README.md has no steps badge to check (expected .../badge/steps-<N>-...)"
    doc_fails=$((doc_fails+1))
  elif [ "$badge" != "$EXPECTED" ]; then
    echo "FAIL: README.md's badge says $badge step(s); suites/expected-count.txt says $EXPECTED."
    doc_fails=$((doc_fails+1))
  fi

  intro="$(grep -o 'for all [0-9]\+ steps' "$README" | head -1 | sed 's/for all //; s/ steps//')"
  if [ -z "$intro" ]; then
    echo "FAIL: README.md's intro table has no 'for all <N> steps' total to check"
    doc_fails=$((doc_fails+1))
  elif [ "$intro" != "$EXPECTED" ]; then
    echo "FAIL: README.md's intro table says $intro step(s); suites/expected-count.txt says $EXPECTED."
    doc_fails=$((doc_fails+1))
  fi

  if [ "$doc_fails" -ne 0 ]; then
    echo ""
    echo "      The count moved and the README did not. Update both in the same change,"
    echo "      the same way suites/expected-count.txt is updated - deliberately."
    exit 1
  fi
  echo "  README badge and intro total both read $EXPECTED"
fi

echo "PASS: verify-run-budget - the suite discovers $ACTUAL tests, which is what suites/expected-count.txt declares"
