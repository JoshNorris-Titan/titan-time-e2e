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
TIMEOUT="2m"
LIST_ONLY=0
VERBOSE=0
HEALTH_CHECK=1
TARGETS=()

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)         BASE_URL="$2"; shift 2 ;;
    --junit|-j)         JUNIT="$2"; shift 2 ;;
    --skip-file)        SKIP_FILE="$2"; shift 2 ;;
    --timeout|-t)       TIMEOUT="$2"; shift 2 ;;
    --list|-l)          LIST_ONLY=1; shift ;;
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
  if [ ${#TARGETS[@]} -eq 0 ]; then TARGETS=("$HERE"); fi
  for t in "${TARGETS[@]}"; do
    if [ -d "$t" ]; then
      find "$t" -maxdepth 1 -name 'verify-*.test.sh' -type f | LC_ALL=C sort
    elif [ -f "$t" ]; then
      printf '%s\n' "$t"
    else
      echo "no such file or directory: $t" >&2; exit 2
    fi
  done
}

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
    if [ -n "${SKIP[$b]:-}" ]; then echo "$b  (skipped)"; else echo "$b"; fi
  done
  exit 0
fi

[ ${#SCRIPTS[@]} -gt 0 ] || { echo "no verify-*.test.sh scripts found" >&2; exit 2; }

# --- health check ----------------------------------------------------------
if [ "$HEALTH_CHECK" -eq 1 ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL/" 2>/dev/null || echo 000)"
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
trap cleanup EXIT INT TERM

playwright-cli open "$BASE_URL/" >/dev/null 2>&1 \
  || { echo "FATAL: could not open browser session" >&2; exit 2; }

# --- timeout wrapper -------------------------------------------------------
TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"

run_one() {   # run_one <script> ; echoes output, returns exit code
  if [ -n "$TIMEOUT_BIN" ]; then
    $TIMEOUT_BIN "$TIMEOUT" bash "$1" 2>&1
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
      echo "FAIL  $name  (TIMEOUT after $TIMEOUT)"
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
