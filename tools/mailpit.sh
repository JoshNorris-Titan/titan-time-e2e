#!/usr/bin/env bash
# The mail catcher.
#
# Mailpit is a fake SMTP server: it accepts every message handed to it, delivers
# none of them, and exposes what it caught over an HTTP API. The app under test
# is configured to send through it, and the suite reads back what arrived.
#
#   tools/mailpit.sh start     run the catcher HERE (idempotent)
#   tools/mailpit.sh stop      shut down the one started here
#   tools/mailpit.sh status    is the configured catcher up? prints the version
#   tools/mailpit.sh clear     empty its inbox
#   tools/mailpit.sh count     how many messages it holds
#   tools/mailpit.sh url       print its address
#
# start/stop act on a catcher running on THIS machine. status/clear/count/url
# act on whatever TT_MAILPIT_URL points at, local or remote.
#
#   TT_MAILPIT_URL        API base URL           (default http://127.0.0.1:8025)
#   TT_MAILPIT_USER/PASS  basic auth for the API, if it is protected
#   TT_MAILPIT_BIND       what the UI/API listens on   (default 127.0.0.1:8025)
#   TT_MAILPIT_SMTP_BIND  what the SMTP port listens on (default 127.0.0.1:1025)
#
# Running it on a shared host: set the two BIND values to 0.0.0.0:<port> so the
# app can reach it, and protect BOTH listeners — see tools/README.md. An open
# SMTP port on the public internet is an abuse magnet, so do not skip that.

set -uo pipefail

MP_URL="${TT_MAILPIT_URL:-http://127.0.0.1:8025}"
MP_BIND="${TT_MAILPIT_BIND:-127.0.0.1:8025}"
MP_SMTP_BIND="${TT_MAILPIT_SMTP_BIND:-127.0.0.1:1025}"
RUNDIR="$(cd "$(dirname "$0")/.." && pwd)/.mailpit"
PIDFILE="$RUNDIR/mailpit.pid"
LOGFILE="$RUNDIR/mailpit.log"

# _curl <method> <path> — the API may be behind basic auth.
_curl() {
  if [ -n "${TT_MAILPIT_USER:-}" ]; then
    curl -fsS -X "$1" --max-time 6 -u "${TT_MAILPIT_USER}:${TT_MAILPIT_PASS:-}" "${MP_URL}${2}" 2>/dev/null
  else
    curl -fsS -X "$1" --max-time 6 "${MP_URL}${2}" 2>/dev/null
  fi
}
_api_up() { _curl GET "/api/v1/info" >/dev/null; }

case "${1:-}" in
  start)
    if _api_up; then echo "catcher already answering at $MP_URL"; exit 0; fi
    command -v mailpit >/dev/null 2>&1 || {
      echo "FAIL: mailpit not on PATH. It is a single binary — https://mailpit.axllent.org" >&2
      exit 1; }
    mkdir -p "$RUNDIR"
    # --smtp-auth-accept-any: no credential to store, leak, or commit. Safe on a
    # loopback bind; on a shared host use --smtp-auth-file with a bcrypt hash
    # instead (a plaintext password is rejected with "535 credentials invalid").
    nohup mailpit \
      --listen "$MP_BIND" \
      --smtp "$MP_SMTP_BIND" \
      --smtp-auth-accept-any \
      --smtp-auth-allow-insecure \
      --quiet \
      >"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 1 30); do
      if _api_up; then echo "catcher up — SMTP $MP_SMTP_BIND, API/UI $MP_URL"; exit 0; fi
      sleep 0.5
    done
    echo "FAIL: no answer on $MP_URL within 15s. Log:" >&2
    tail -5 "$LOGFILE" >&2
    exit 1
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi
    taskkill //IM mailpit.exe //F >/dev/null 2>&1 || pkill -f mailpit >/dev/null 2>&1
    echo "catcher stopped"
    ;;
  status)
    if _api_up; then
      echo "up: $(_curl GET /api/v1/info | jq -r '"mailpit " + .Version')  at $MP_URL"
    else
      echo "down (or unreachable): $MP_URL"; exit 1
    fi
    ;;
  clear)
    _api_up || { echo "FAIL: no catcher at $MP_URL" >&2; exit 1; }
    _curl DELETE "/api/v1/messages" >/dev/null || { echo "FAIL: could not empty the inbox" >&2; exit 1; }
    echo "inbox emptied"
    ;;
  count)
    _api_up || { echo "FAIL: no catcher at $MP_URL" >&2; exit 1; }
    _curl GET "/api/v1/messages?limit=1" | jq -r '.total'
    ;;
  url) echo "$MP_URL" ;;
  *)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
