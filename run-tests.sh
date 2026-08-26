#!/usr/bin/env bash
# run-tests.sh — portable runner for the Titan Time Playwright E2E suite.
#
# Replaces `mxcli playwright verify`, which only existed as a Windows-only binary
# (C:\Users\Josh\bin\mxcli.exe) and so could never run in CI. This reproduces the
# same contract using only `playwright-cli` (npm: @playwright/cli), which installs
# on any platform.
#
# Contract kept deliberately identical to the old runner so the 50 existing
# verify-*.test.sh scripts and tests/lib/ work unchanged:
#
#   * discover verify-*.test.sh and run them SORTED — order is load-bearing:
#     verify-000-testdata-clear-before and verify-zzz-testdata-clear-after
#     bracket the run.
#   * one SHARED playwright-cli browser session for the whole run; the scripts
#     call bare `playwright-cli` (no -s= flag), i.e. the default session, and
#     rely on login in one script persisting into the next.
#   * a non-zero exit from a script marks it FAILED.
#   * screenshot captured on failure.
#   * optional JUnit XML for CI.
#
# Usage:
#   ./run-tests.sh                              run every test in this directory
#   ./run-tests.sh verify-smoke-login.test.sh   run one script
#   ./run-tests.sh --list
#   ./run-tests.sh --expect-count 52        fail unless exactly 52 tests are found
#   ./run-tests.sh --junit results.xml --skip-file ci-skip.txt
#
# Env:
#   TT_BASE_URL    app origin, no trailing slash (default http://localhost:8080)
#   TT_ADMIN_USER / TT_ADMIN_PASS / TT_ROLE_PASS   see lib/_login.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_URL="${TT_BASE_URL:-http://localhost:8080}"
JUNIT=""
SKIP_FILE=""
# 2m was tuned against a local F5 run. Against Mendix Cloud dev the same steps take
# noticeably longer -- the first CI baseline lost nine steps to the cap, several of
# which were merely slow rather than stuck. A longer cap costs nothing on a passing
# step and only spends time on one that was going to fail anyway.
TIMEOUT="4m"
# Set when --timeout is passed, so a per-test "# tt-timeout:" declaration does not
# silently override what the caller explicitly asked for.
TIMEOUT_EXPLICIT=""
LIST_ONLY=0
EXPECT_COUNT=""
VERBOSE=0
HEALTH_CHECK=1
TARGETS=()

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)         BASE_URL="$2"; shift 2 ;;
    --junit|-j)         JUNIT="$2"; shift 2 ;;
    --skip-file)        SKIP_FILE="$2"; shift 2 ;;
    --timeout|-t)       TIMEOUT="$2"; TIMEOUT_EXPLICIT=1; shift 2 ;;
    --list|-l)          LIST_ONLY=1; shift ;;
    --expect-count)     EXPECT_COUNT="$2"; shift 2 ;;
    --verbose|-v)       VERBOSE=1; shift ;;
    --skip-health-check) HEALTH_CHECK=0; shift ;;
    --color)            shift ;;   # accepted for compatibility, no-op
    -h|--help)          usage ;;
    -*)                 echo "unknown flag: $1" >&2; exit 2 ;;
    *)                  TARGETS+=("$1"); shift ;;
  esac
done

BASE_URL="${BASE_URL%/}"
export TT_BASE_URL="$BASE_URL"

# --- discovery -------------------------------------------------------------
# Sorted, because the suite depends on run order (000 clears before, zzz after).
collect() {
  local t
  if [ ${#TARGETS[@]} -eq 0 ]; then TARGETS=("$HERE/suites"); fi
  for t in "${TARGETS[@]}"; do
    if [ -d "$t" ]; then
      # Recursive, sorted by FULL PATH. The numeric directory prefixes under
      # suites/ (00-setup ... 99-teardown) are what impose run order now.
      # Previously order came from a flat lexical sort and depended on the
      # accident that '-' (0x2D) sorts before '0' (0x30), which is how
      # verify-00-fixtures came before verify-000-testdata-clear-before.
      # Directories make that intent explicit instead of incidental.
      find "$t" -name 'verify-*.test.sh' -type f | LC_ALL=C sort
    elif [ -f "$t" ]; then
      printf '%s\n' "$t"
    else
      echo "no such file or directory: $t" >&2; exit 2
    fi
  done
}

if [ ${#TARGETS[@]} -gt 0 ]; then
  for _t in "${TARGETS[@]}"; do
    [ -e "$_t" ] || { echo "no such file or directory: $_t" >&2; exit 2; }
  done
fi

mapfile -t SCRIPTS < <(collect)

# --- skip list -------------------------------------------------------------
# Scripts that cannot run against a remote environment (hardcoded localhost,
# local-only infrastructure). One basename per line; # comments allowed.
declare -A SKIP=()
if [ -n "$SKIP_FILE" ]; then
  [ -f "$SKIP_FILE" ] || { echo "skip file not found: $SKIP_FILE" >&2; exit 2; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && SKIP["$line"]=1
  done < "$SKIP_FILE"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${SCRIPTS[@]}"; do
    b="$(basename "$s")"
    # Show the path so the suite grouping is visible, but skip-matching stays on
    # the basename so ci-skip.txt does not have to churn when a test is re-filed.
    rel="${s#$HERE/}"
    if [ -n "${SKIP[$b]:-}" ]; then echo "$rel  (skipped)"; else echo "$rel"; fi
  done
  exit 0
fi

[ ${#SCRIPTS[@]} -gt 0 ] || { echo "no verify-*.test.sh scripts found" >&2; exit 2; }

# Discovery gate. Without this the RUN ITSELF cannot fail: rename a test out of the
# verify-*.test.sh glob, or drop a folder, and the runner happily reports
# "3 tests: 3 passed" with exit 0. Same class of bug as an assertion that cannot
# fail, one level up. CI should always pass --expect-count.
if [ -n "$EXPECT_COUNT" ]; then
  case "$EXPECT_COUNT" in
    ''|*[!0-9]*) echo "--expect-count needs a number, got: $EXPECT_COUNT" >&2; exit 2 ;;
  esac
  if [ "${#SCRIPTS[@]}" -ne "$EXPECT_COUNT" ]; then
    echo "FATAL: discovered ${#SCRIPTS[@]} test(s), expected $EXPECT_COUNT." >&2
    echo "       A test was added, removed, or renamed out of the verify-*.test.sh glob." >&2
    echo "       Run --list to see what was found, then update --expect-count deliberately." >&2
    exit 2
  fi
fi

# --- health check ----------------------------------------------------------
if [ "$HEALTH_CHECK" -eq 1 ]; then
  # `|| echo 000` used to APPEND to curl's own "000" on a connection failure, so
  # $code ended up as two lines of zeros, never equalled "000", and an unreachable
  # app passed the check and started a full run against nothing. Let the
  # assignment's exit status decide instead, and treat any non-numeric or empty
  # result as unreachable.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL/" 2>/dev/null)" || code=""
  case "$code" in ''|*[!0-9]*) code="000" ;; esac
  if [ "$code" = "000" ]; then
    echo "FATAL: app not reachable at $BASE_URL (use --skip-health-check to override)" >&2
    exit 2
  fi
  echo "app reachable at $BASE_URL (HTTP $code)"
fi

# --- shared browser session ------------------------------------------------
# The scripts assume a session is already open and that state (login, cookies)
# carries from one script to the next. Open once here, close on exit.
# Prefer a locally-installed playwright-cli over a global one. `npm ci` puts it in
# node_modules/.bin, which is NOT on PATH for a plain CI `run:` step — locally it
# happens to work only because the host has it installed globally. Exporting PATH
# here also covers the test scripts, which invoke `playwright-cli` directly as
# child processes of this runner.
if [ -x "$HERE/node_modules/.bin/playwright-cli" ]; then
  PATH="$HERE/node_modules/.bin:$PATH"
  export PATH
fi

command -v playwright-cli >/dev/null 2>&1 || {
  echo "FATAL: playwright-cli not found — run 'npm ci' in $HERE" >&2; exit 2; }

cleanup() { playwright-cli close >/dev/null 2>&1 || true; }
on_signal() {
  echo >&2
  echo "interrupted — closing the shared browser session and stopping." >&2
  cleanup
  trap - EXIT
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

playwright-cli open "$BASE_URL/" >/dev/null 2>&1 \
  || { echo "FATAL: could not open browser session" >&2; exit 2; }

# --- timeout wrapper -------------------------------------------------------
TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"

# script_timeout <script> — the budget for ONE script.
#
# A test may declare its own with a line of the form
#     # tt-timeout: 8m
# in its first 40 lines. A handful of steps are legitimately long — verify-tt654-a3
# drives five logins, a rejection hunt across HR tabs and a resubmit, and takes
# ~280s on cloud dev — and raising the GLOBAL cap to suit them would mean every
# genuinely stuck test burns that budget before the suite moves on. Declaring it
# per test keeps the default tight and puts the cost where it is understood.
#
# An explicit --timeout on the command line always wins, so a run can still be
# capped uniformly when that is what is wanted.
script_timeout() {
  local declared
  [ -n "$TIMEOUT_EXPLICIT" ] && { printf '%s' "$TIMEOUT"; return; }
  declared="$(sed -n '1,40p' "$1" | grep -m1 -oE '^#[[:space:]]*tt-timeout:[[:space:]]*[0-9]+[smh]?' | grep -oE '[0-9]+[smh]?$')"
  printf '%s' "${declared:-$TIMEOUT}"
}

run_one() {   # run_one <script> ; echoes output, returns exit code
  if [ -n "$TIMEOUT_BIN" ]; then
    $TIMEOUT_BIN "$(script_timeout "$1")" bash "$1" 2>&1
  else
    bash "$1" 2>&1
  fi
}

# --- run -------------------------------------------------------------------
xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

PASSED=0; FAILED=0; SKIPPED=0
CASES_FILE="$(mktemp)"
RUN_START=$(date +%s)

for script in "${SCRIPTS[@]}"; do
  name="$(basename "$script" .test.sh)"
  base="$(basename "$script")"

  if [ -n "${SKIP[$base]:-}" ]; then
    echo "SKIP  $name"
    SKIPPED=$((SKIPPED+1))
    { echo "    <testcase name=\"$(printf '%s' "$name" | xml_escape)\" time=\"0\">"
      echo "      <skipped message=\"listed in skip file\"/>"
      echo "    </testcase>"; } >> "$CASES_FILE"
    continue
  fi

  t0=$(date +%s)
  out="$(run_one "$script")"; rc=$?
  t1=$(date +%s); dur=$((t1-t0))

  if [ "$rc" -eq 0 ]; then
    echo "PASS  $name  (${dur}s)"
    PASSED=$((PASSED+1))
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out" | sed 's/^/      /'
    { echo "    <testcase name=\"$(printf '%s' "$name" | xml_escape)\" time=\"$dur\"/>"; } >> "$CASES_FILE"
  else
    if [ "$rc" -eq 124 ]; then
      echo "FAIL  $name  (TIMEOUT after $(script_timeout "$script"))"
    else
      echo "FAIL  $name  (exit $rc, ${dur}s)"
    fi
    FAILED=$((FAILED+1))
    printf '%s\n' "$out" | sed 's/^/      /'
    playwright-cli screenshot "$HERE/${name}-failure.png" >/dev/null 2>&1 || true
    { echo "    <testcase name=\"$(printf '%s' "$name" | xml_escape)\" time=\"$dur\">"
      echo "      <failure message=\"exit $rc\"><![CDATA["
      printf '%s\n' "$out" | sed 's/]]>/]]]]><![CDATA[>/g'
      echo "      ]]></failure>"
      echo "    </testcase>"; } >> "$CASES_FILE"
  fi
done

RUN_END=$(date +%s); TOTAL_TIME=$((RUN_END-RUN_START))
TOTAL=$((PASSED+FAILED+SKIPPED))

# --- junit -----------------------------------------------------------------
if [ -n "$JUNIT" ]; then
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuites>"
    echo "  <testsuite name=\"titan-time-e2e\" tests=\"$TOTAL\" failures=\"$FAILED\" skipped=\"$SKIPPED\" time=\"$TOTAL_TIME\">"
    cat "$CASES_FILE"
    echo "  </testsuite>"
    echo "</testsuites>"; } > "$JUNIT"
  echo "JUnit written to $JUNIT"
fi
rm -f "$CASES_FILE"

echo "----------------------------------------------------------------"
echo "$TOTAL tests: $PASSED passed, $FAILED failed, $SKIPPED skipped  (${TOTAL_TIME}s)"

[ "$FAILED" -eq 0 ]
