#!/usr/bin/env bash
# Proves the mail catcher works, with NO app involved.
#
# Hands a message straight to the catcher over SMTP, then reads it back through
# the same helpers the tests use. If this passes but a mail test fails, the
# fault is in the app or its email configuration — not in the plumbing.
#
# Run it after standing up a catcher, and again whenever a mail test starts
# failing for reasons nobody can explain.
#
# This is a probe, not a test: it is deliberately NOT named verify-*.test.sh, so
# run-tests.sh never picks it up and the suite's run order is untouched.
#
#   TT_MAILPIT_URL   the catcher's API              (required)
#   TT_MAILPIT_SMTP  its SMTP host:port to send to  (required)
#   TT_MAILPIT_USER / TT_MAILPIT_PASS   API basic auth, if protected
#   TT_MAILPIT_SMTP_USER / TT_MAILPIT_SMTP_PASS   SMTP auth, if required

set -uo pipefail
cd "$(dirname "$0")/.."
source lib/_login.sh

[ -n "${TT_MAILPIT_URL:-}" ]  || tt_fail "set TT_MAILPIT_URL to the catcher's API"
[ -n "${TT_MAILPIT_SMTP:-}" ] || tt_fail "set TT_MAILPIT_SMTP to the catcher's SMTP host:port"

tt_mail_prepare          # reachable? then empty the inbox

TAG="selfcheck"
RECIP="$(tt_mail_address "$TAG")"
NONCE="tt-selfcheck-$$-$(date +%s)"
TS=$(date +%s%3N)

# curl speaks SMTP, so the probe needs no extra tooling.
SMTP_AUTH=()
[ -n "${TT_MAILPIT_SMTP_USER:-}" ] && SMTP_AUTH=(--user "${TT_MAILPIT_SMTP_USER}:${TT_MAILPIT_SMTP_PASS:-}")

printf 'From: probe@e2e.local\r\nTo: %s\r\nSubject: Timesheet reminder %s\r\n\r\nThis is a submission reminder probe. Link: https://example.invalid/customer-approval?token=%s\r\n' \
  "$RECIP" "$NONCE" "$NONCE" \
  | curl -s --max-time 15 --url "smtp://${TT_MAILPIT_SMTP}" "${SMTP_AUTH[@]}" \
      --mail-from "probe@e2e.local" --mail-rcpt "$RECIP" --upload-file - \
  || tt_fail "could not hand a message to the catcher's SMTP port at ${TT_MAILPIT_SMTP}"

echo "sent a probe message to $RECIP via ${TT_MAILPIT_SMTP}"

MSG=$(tt_mail_message "$TS" "$TAG" 30) \
  || tt_fail "the probe message was not readable back from ${TT_MAILPIT_URL} within 30s"

printf '%s' "$MSG" | grep -q "$NONCE" \
  || tt_fail "read a message back, but not the one just sent (nonce $NONCE missing)"

LINK=$(tt_mail_token "$TS" "customer-approval" "$TAG" 30) \
  || tt_fail "link extraction failed on a message known to contain one"

case "$LINK" in
  *customer-approval*"$NONCE") ;;
  *) tt_fail "extracted the wrong link: $LINK" ;;
esac

echo "read it back, and pulled the token link out of it"
echo "PASS: mail catcher self-check (send -> store -> read -> extract link)"
