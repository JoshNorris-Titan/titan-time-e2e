#!/usr/bin/env bash
# Local mail catcher for the E2E suite.
#
# Mailpit is a fake SMTP server: it accepts mail on port 1025 and, instead of
# delivering it anywhere, keeps it in memory where the tests can read it over an
# HTTP API on port 8025. Nothing ever leaves this machine.
#
#   tools/mailpit.sh start     launch it (idempotent — safe to call twice)
#   tools/mailpit.sh stop      shut it down
#   tools/mailpit.sh status    is it up? prints the version
#   tools/mailpit.sh clear     empty the inbox
#   tools/mailpit.sh count     how many messages are held
#   tools/mailpit.sh url       print the web UI address
#
# Why no password: an earlier attempt at this ran mailpit with --smtp-auth-file
# and a plaintext password, which mailpit rejected outright ("535 Authentication
# credentials invalid" — it wants a bcrypt hash). Since the listener is bound to
# 127.0.0.1 and holds only test mail, --smtp-auth-accept-any is both simpler and
# safer: there is no credential to store, leak, or commit.
#
# Storage is deliberately in-memory (no -d flag), so `stop` is also a full reset.

set -uo pipefail

MP_URL="${TT_MAILPIT_URL:-http://127.0.0.1:8025}"
MP_SMTP="${TT_MAILPIT_SMTP:-127.0.0.1:1025}"
RUNDIR="$(cd "$(dirname "$0")/.." && pwd)/.mailpit"
PIDFILE="$RUNDIR/mailpit.pid"
LOGFILE="$RUNDIR/mailpit.log"

_api_up() { curl -fsS --max-time 3 "$MP_URL/api/v1/info" >/dev/null 2>&1; }

case "${1:-}" in
  start)
    if _api_up; then echo "mailpit already running at $MP_URL"; exit 0; fi
    command -v mailpit >/dev/null 2>&1 || {
      echo "FAIL: mailpit not on PATH. Install from https://mailpit.axllent.org (a single binary)." >&2
      exit 1; }
    mkdir -p "$RUNDIR"
    # --smtp-auth-allow-insecure pairs with accept-any: the app connects without
    # TLS, which mailpit otherwise refuses to accept credentials over.
    nohup mailpit \
      --listen "${MP_URL#http://}" \
      --smtp "$MP_SMTP" \
      --smtp-auth-accept-any \
      --smtp-auth-allow-insecure \
      --quiet \
      >"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 1 30); do
      if _api_up; then
        echo "mailpit up — SMTP $MP_SMTP, API/UI $MP_URL"
        exit 0
      fi
      sleep 0.5
    done
    echo "FAIL: mailpit did not answer on $MP_URL within 15s. Log:" >&2
    tail -5 "$LOGFILE" >&2
    exit 1
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi
    # Fall back to a name match: a mailpit started by hand has no pidfile here.
    _api_up && { taskkill //IM mailpit.exe //F >/dev/null 2>&1 || pkill -f mailpit; }
    echo "mailpit stopped"
    ;;
  status)
    if _api_up; then
      echo "up: $(curl -fsS --max-time 3 "$MP_URL/api/v1/info" | jq -r '"mailpit " + .Version')  SMTP $MP_SMTP"
    else
      echo "down"; exit 1
    fi
    ;;
  clear)
    _api_up || { echo "FAIL: mailpit is not running" >&2; exit 1; }
    curl -fsS -X DELETE --max-time 5 "$MP_URL/api/v1/messages" >/dev/null \
      || { echo "FAIL: could not empty the inbox" >&2; exit 1; }
    echo "inbox emptied"
    ;;
  count)
    _api_up || { echo "FAIL: mailpit is not running" >&2; exit 1; }
    curl -fsS --max-time 5 "$MP_URL/api/v1/messages?limit=1" | jq -r '.total'
    ;;
  url) echo "$MP_URL" ;;
  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
