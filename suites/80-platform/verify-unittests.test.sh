#!/usr/bin/env bash
# verify-unittests.test.sh
#
# Runs the Mendix UnitTesting suite headlessly through the module's remote API and
# reports each failure with its ReportStep text.
#
# Why ReportStep matters: UnitTest.ResultMessage only ever holds one of five canned
# strings, so the AssertUsingExpression FailureMessage never reaches this output. The
# last ReportStep is the only free-form text the API returns - hence the convention of
# calling ReportStep immediately before every assertion.
#
# Prerequisites in the RUNNING app's configuration:
#   UnitTesting.RemoteApiEnabled  = true
#   UnitTesting.RemoteApiPassword = <non-blank>      -> export as TT_UNITTEST_PASS
#   Core.ASU_OnStartup must call UnitTesting.Startup
#   The app must have been restarted after changing any of the above.
#
# SECURITY: this endpoint is a raw request handler with no Mendix session - password
# only. Keep RemoteApiEnabled true ONLY in local configurations. Never enable it in a
# cloud environment.
#
# Env:
#   TT_BASE_URL         default http://localhost:8080
#   TT_UNITTEST_PASS    required, must match UnitTesting.RemoteApiPassword
#   TT_UNITTEST_TIMEOUT default 180 (seconds)

set -uo pipefail

BASE="${TT_BASE_URL:-http://localhost:8080}"
PASS="${TT_UNITTEST_PASS:-}"
TIMEOUT="${TT_UNITTEST_TIMEOUT:-180}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$PASS" ]; then
  echo "FAIL: TT_UNITTEST_PASS is not set. It must match UnitTesting.RemoteApiPassword."
  exit 2
fi

BODY="$(printf '{"password":"%s"}' "$PASS")"

post() { # post <path> <outfile>  -> echoes the HTTP status code
  curl -s -o "$2" -w '%{http_code}' -X POST "$BASE/unittests/$1" \
       -H 'Content-Type: application/json' -d "$BODY"
}

code="$(post start "$WORK/start.out")"
case "$code" in
  204) ;;
  400) echo "FAIL: HTTP 400 from /unittests/start."
       echo "      Most often this means a run is already in progress (the runner is a"
       echo "      singleton and allows only one at a time). Wait and retry."
       cat "$WORK/start.out"; exit 1 ;;
  401) echo "FAIL: HTTP 401 - TT_UNITTEST_PASS does not match UnitTesting.RemoteApiPassword."
       exit 1 ;;
  404) echo "FAIL: HTTP 404 - the remote API is not registered. Check that:"
       echo "        * UnitTesting.RemoteApiEnabled  = true"
       echo "        * UnitTesting.RemoteApiPassword is non-blank"
       echo "        * Core.ASU_OnStartup calls UnitTesting.Startup"
       echo "        * the app was restarted after those changes"
       exit 1 ;;
  000) echo "FAIL: could not reach $BASE - is the app running?"
       exit 1 ;;
  *)   echo "FAIL: unexpected HTTP $code from /unittests/start"
       cat "$WORK/start.out"; exit 1 ;;
esac

echo "Run started. Polling ${BASE}/unittests/status (timeout ${TIMEOUT}s)..."

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  code="$(post status "$WORK/status.json")"
  if [ "$code" != "200" ]; then
    echo "FAIL: HTTP $code from /unittests/status"
    cat "$WORK/status.json"; exit 1
  fi
  # Plain grep on purpose: this runs under git-bash where $WORK is a POSIX path
  # (/tmp/...) that a Windows python cannot open. Keep file paths out of python.
  if grep -q '"completed"[[:space:]]*:[[:space:]]*true' "$WORK/status.json"; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL: timed out after ${TIMEOUT}s waiting for the run to complete."
    cat "$WORK/status.json"; exit 1
  fi
  sleep 2
done

# Three git-bash-on-Windows workarounds, all needed because the python on PATH is a
# native Windows build:
#   1. The report runs from a file, not `python -c` - a multi-line -c argument gets
#      mangled by the Windows command-line layer.
#   2. Both paths go through cygpath - Windows python cannot resolve git-bash's
#      /tmp mount.
#   3. The JSON is passed by path, not on stdin - redirecting a file into a native
#      Windows binary from git-bash delivered empty stdin here.
cat > "$WORK/report.py" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    d = json.load(fh)
tests    = d.get("tests", 0)
failures = d.get("failures", 0)
runtime  = d.get("runtime")

print("")
print("{} test(s) run, {} failure(s), {} ms".format(tests, failures, runtime))
print("")

for f in (d.get("failed_tests") or []):
    print("  FAILED  {}".format(f.get("name")))
    print("          error: {}".format(f.get("error")))
    print("          step : {}".format(f.get("step")))
    print("")

sys.exit(1 if failures else 0)
PY

if command -v cygpath >/dev/null 2>&1; then
  REPORT_PY="$(cygpath -w "$WORK/report.py")"
  STATUS_JSON="$(cygpath -w "$WORK/status.json")"
else
  REPORT_PY="$WORK/report.py"
  STATUS_JSON="$WORK/status.json"
fi

python "$REPORT_PY" "$STATUS_JSON"
rc=$?

if [ "$rc" -gt 1 ]; then
  echo "FAIL: could not parse the status response. Raw body:"
  cat "$WORK/status.json"
  exit 1
fi

if [ "$rc" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit "$rc"
