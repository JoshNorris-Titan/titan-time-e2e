#!/usr/bin/env bash
# Proves the mail catcher works, with NO app involved.
#
# Sends a message straight to mailpit over SMTP, then reads it back through the
# same helpers the tests use. If this passes but a mail test fails, the fault is
# in the app or its email configuration — not in the plumbing.
#
# This is a probe, not a test: it is deliberately NOT named verify-*.test.sh, so
# run-tests.sh never picks it up and the suite's run order is untouched.
#
#   tools/mail-selfcheck.sh

set -uo pipefail
cd "$(dirname "$0")/.."
source lib/_login.sh

MP_SMTP="${TT_MAILPIT_SMTP:-127.0.0.1:1025}"

./tools/mailpit.sh start >/dev/null || tt_fail "could not start mailpit"

export TT_MAIL_BACKEND=mailpit
tt_mail_prepare

TAG="selfcheck"
RECIP="$(tt_mail_address "$TAG")"
NONCE="tt-selfcheck-$$-$(date +%s)"

# Empty the inbox first, so nothing older can satisfy the read below.
tt_mail_reset

TS=$(date +%s%3N)

# curl speaks SMTP, so the probe needs no extra tooling.
printf 'From: probe@e2e.local\r\nTo: %s\r\nSubject: Timesheet reminder %s\r\n\r\nThis is a submission reminder probe. Link: https://example.invalid/customer-approval?token=%s\r\n' \
  "$RECIP" "$NONCE" "$NONCE" \
  | curl -s --max-time 10 --url "smtp://${MP_SMTP}" \
      --mail-from "probe@e2e.local" --mail-rcpt "$RECIP" --upload-file - \
  || tt_fail "could not hand a message to mailpit on ${MP_SMTP}"

echo "sent a probe message to $RECIP"

MSG=$(tt_mail_message "$TS" "$TAG" 20) \
  || tt_fail "the probe message was not readable back within 20s"

printf '%s' "$MSG" | grep -q "$NONCE" \
  || tt_fail "read a message back, but not the one just sent (nonce $NONCE missing)"

LINK=$(tt_mail_token "$TS" "customer-approval" "$TAG") \
  || tt_fail "link extraction failed on a message known to contain one"

case "$LINK" in
  *customer-approval*"$NONCE") ;;
  *) tt_fail "extracted the wrong link: $LINK" ;;
esac

echo "read it back, and pulled the token link out of it"
echo "PASS: mail catcher self-check (send -> store -> read -> extract link)"
