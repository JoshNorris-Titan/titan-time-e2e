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
#   ./run-tests.sh --no-fail-fast           run the whole suite even after a failure
#
# Fail-fast is ON by default: the first FAIL stops the run, and the only thing that
# still executes is the teardown (suites/99-teardown/, i.e. verify-zzz-*), so the
# environment is left clean and the browser session is closed. Everything after the
# failure is reported as "not run", never as passed.
#
# Env:
#   TT_BASE_URL    app origin, no trailing slash. REQUIRED — there is no default.
#                  Pass --base-url instead if you prefer. See the note below.
#   TT_ADMIN_USER / TT_ADMIN_PASS / TT_ROLE_PASS   see lib/_login.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NO DEFAULT, DELIBERATELY.
#
# This used to be `${TT_BASE_URL:-http://localhost:8080}`, and a few lines below the
# result is exported as TT_BASE_URL for every test. That export SATISFIED the guard in
# lib/_fixtures.sh (fx_ensure_all):
#
#   "fixtures: TT_BASE_URL must be set explicitly - this writes data and must never
#    silently fall back to a default environment"
#
# so the guard could never fire, and `./run-tests.sh` with no env quietly ran the whole
# suite -- including the write-capable fixture provisioning -- against whatever app
# happened to be listening on 8080.
#
# That is not hypothetical. On 2026-08-27 a run intended for dev went to a local F5 app
# whose database holds the demo users (Warren/Sam/Blake) and only part of the E2E
# fixtures. It reported two consultants MISSING and aborted on an unreadable project
# customer, which read exactly like dev data drift; dev was in fact clean (14 present,
# 0 created). The whole investigation was chasing a phantom.
#
# Running locally stays fully supported -- it just has to be said out loud:
#   TT_BASE_URL=http://localhost:8080 ./run-tests.sh
#   ./run-tests.sh --base-url http://localhost:8080
BASE_URL="${TT_BASE_URL:-}"
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
# Stop at the first failure and go straight to teardown. On by default.
#
# The suite shares one browser session and one database, and the steps are ordered
# on purpose (00-setup seeds and clears, 99-teardown clears again). Once a step
# fails, everything after it runs against a state nobody designed: a half-written
# timesheet, a week the failing step claimed but never released, a login that never
# happened. Those downstream failures are noise that reads like signal, and the real
# one scrolls off the top. Worse, a run that keeps going keeps WRITING.
#
# Teardown is deliberately exempt -- skipping it would leak the seeded rows into the
# next run, which is the failure mode lib/_testdata.sh was written to stop.
FAIL_FAST=1
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
    --no-fail-fast|--keep-going) FAIL_FAST=0; shift ;;
    --fail-fast)        FAIL_FAST=1; shift ;;
    --color)            shift ;;   # accepted for compatibility, no-op
    -h|--help)          usage ;;
    -*)                 echo "unknown flag: $1" >&2; exit 2 ;;
    *)                  TARGETS+=("$1"); shift ;;
  esac
done

# --list only enumerates files on disk, so it needs no environment.
if [ -z "$BASE_URL" ] && [ "$LIST_ONLY" -eq 0 ]; then
  cat >&2 <<'EOF'
FATAL: no target environment. Set TT_BASE_URL or pass --base-url.

  This suite WRITES data (lib/_fixtures.sh provisions projects and assignments, and
  the 00-setup bookends clear timesheets), so it will not guess where to run.

    TT_BASE_URL=https://titantime100-development.mendixcloud.com ./run-tests.sh
    ./run-tests.sh --base-url http://localhost:8080        # local F5 run
EOF
  exit 2
fi

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

# script_header <script> — the comment block at the top of a test.
#
# Every line from the first, for as long as they are blank or start with '#'. The
# header ends at the first line of code, which in every spec here is `set -uo
# pipefail`. Directives are read from THIS, not from a line count, so a header can
# grow without a directive silently falling off the end of the window — see
# script_timeout.
script_header() {
  awk '/^[[:space:]]*(#|$)/ { print; next } { exit }' "$1"
}

# script_timeout <script> — the budget for ONE script.
#
# A test may declare its own with a line of the form
#     # tt-timeout: 8m
# anywhere in its header comment. A handful of steps are legitimately long —
# verify-tt654-a3 drives five logins, a rejection hunt across HR tabs and a
# resubmit, and takes ~280s on cloud dev — and raising the GLOBAL cap to suit them
# would mean every genuinely stuck test burns that budget before the suite moves
# on. Declaring it per test keeps the default tight and puts the cost where it is
# understood.
#
# THE WINDOW USED TO BE THE FIRST 40 LINES, and that is how a declared budget came
# to be ignored without a word. verify-email-templates-present grew its header to
# explain what it had learned, which pushed `# tt-timeout: 15m` to line 78; the
# scan never reached it, the 4m default applied instead, and the step was killed
# six types into twelve and reported as a TIMEOUT. Nothing in the output said the
# declaration had been missed, so the file looked like it was asking for 15m and
# being given 4m for some reason of its own. Reading the whole header removes the
# cliff; check_timeout_directive below catches a declaration that falls outside it
# anyway.
#
# An explicit --timeout on the command line always wins, so a run can still be
# capped uniformly when that is what is wanted.
script_timeout() {
  local declared
  [ -n "$TIMEOUT_EXPLICIT" ] && { printf '%s' "$TIMEOUT"; return; }
  declared="$(script_header "$1" | grep -m1 -oE '^#[[:space:]]*tt-timeout:[[:space:]]*[0-9]+[smh]?' | grep -oE '[0-9]+[smh]?$')"
  printf '%s' "${declared:-$TIMEOUT}"
}

# check_timeout_directive <script> — warn when a test asks for a budget it will
# not get.
#
# A `# tt-timeout:` that sits BELOW the header (after the first line of code, or
# indented so it does not start the line) is not read, and the only symptom is a
# test killed early at the default. That is indistinguishable from the test being
# genuinely stuck, which is exactly the wrong thing to have to guess at. So say it
# out loud, once, before the test runs.
check_timeout_directive() {
  local declared_anywhere
  declared_anywhere="$(grep -m1 -oE '^[[:space:]]*#[[:space:]]*tt-timeout:[[:space:]]*[0-9]+[smh]?' "$1" || true)"
  [ -n "$declared_anywhere" ] || return 0
  [ -n "$(script_header "$1" | grep -m1 -oE '^#[[:space:]]*tt-timeout:[[:space:]]*[0-9]+[smh]?' || true)" ] && return 0
  echo "WARN  $(basename "$1" .test.sh): its 'tt-timeout' line is outside the header comment," >&2
  echo "      so it is being run at $(script_timeout "$1") instead. Move it above the first line of code." >&2
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

PASSED=0; FAILED=0; SKIPPED=0; NOTRUN=0
CASES_FILE="$(mktemp)"
RUN_START=$(date +%s)

# Set to the name of the step that tripped fail-fast, empty while the run is healthy.
ABORTED_BY=""

# is_teardown <path> — does this script still run after a fail-fast abort?
#
# Matched two ways on purpose: the folder is the real contract (suites/99-teardown/),
# and the verify-zzz- prefix is what makes it sort last under the runner's LC_ALL=C
# sort. A file that satisfies only one of the two is almost certainly a mistake, but
# treating it as teardown is the safe direction to be wrong in -- the cost is running
# one extra cleanup step, versus leaking seeded rows into the next run.
is_teardown() {
  case "$1" in
    */99-teardown/*)  return 0 ;;
  esac
  case "$(basename "$1")" in
    verify-zzz-*)     return 0 ;;
  esac
  return 1
}

for script in "${SCRIPTS[@]}"; do
  name="$(basename "$script" .test.sh)"
  base="$(basename "$script")"

  # Fail-fast: everything after the first failure is reported as "not run" rather
  # than silently dropped, so the totals still add up to the discovered count and
  # --expect-count keeps meaning something.
  if [ -n "$ABORTED_BY" ] && ! is_teardown "$script"; then
    echo "NOTRUN $name"
    NOTRUN=$((NOTRUN+1))
    { echo "    <testcase name=\"$(printf '%s' "$name" | xml_escape)\" time=\"0\">"
      echo "      <skipped message=\"not run - suite aborted after $(printf '%s' "$ABORTED_BY" | xml_escape) failed\"/>"
      echo "    </testcase>"; } >> "$CASES_FILE"
    continue
  fi

  if [ -n "${SKIP[$base]:-}" ]; then
    echo "SKIP  $name"
    SKIPPED=$((SKIPPED+1))
    { echo "    <testcase name=\"$(printf '%s' "$name" | xml_escape)\" time=\"0\">"
      echo "      <skipped message=\"listed in skip file\"/>"
      echo "    </testcase>"; } >> "$CASES_FILE"
    continue
  fi

  check_timeout_directive "$script"

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

    # Trip the abort on the FIRST failure only, and never on the teardown itself --
    # by the time teardown runs there is nothing left to skip, and blaming the abort
    # on it would misreport which step actually broke.
    if [ "$FAIL_FAST" -eq 1 ] && [ -z "$ABORTED_BY" ] && ! is_teardown "$script"; then
      ABORTED_BY="$name"
      echo "----------------------------------------------------------------"
      echo "fail-fast: stopping after '$name'. Running teardown, then reporting."
      echo "           (use --no-fail-fast to run the whole suite regardless)"
      echo "----------------------------------------------------------------"
    fi
  fi
done

RUN_END=$(date +%s); TOTAL_TIME=$((RUN_END-RUN_START))
TOTAL=$((PASSED+FAILED+SKIPPED+NOTRUN))

# --- junit -----------------------------------------------------------------
if [ -n "$JUNIT" ]; then
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuites>"
    # Both the skip-file skips and the fail-fast "not run" cases emit <skipped/>,
    # so the attribute has to count both or the XML contradicts its own elements.
    echo "  <testsuite name=\"titan-time-e2e\" tests=\"$TOTAL\" failures=\"$FAILED\" skipped=\"$((SKIPPED+NOTRUN))\" time=\"$TOTAL_TIME\">"
    cat "$CASES_FILE"
    echo "  </testsuite>"
    echo "</testsuites>"; } > "$JUNIT"
  echo "JUnit written to $JUNIT"
fi
rm -f "$CASES_FILE"

echo "----------------------------------------------------------------"
if [ "$NOTRUN" -gt 0 ]; then
  echo "$TOTAL tests: $PASSED passed, $FAILED failed, $SKIPPED skipped, $NOTRUN not run  (${TOTAL_TIME}s)"
  echo "ABORTED after '$ABORTED_BY' — $NOTRUN step(s) never ran, so this run says nothing about them."
else
  echo "$TOTAL tests: $PASSED passed, $FAILED failed, $SKIPPED skipped  (${TOTAL_TIME}s)"
fi

[ "$FAILED" -eq 0 ]
