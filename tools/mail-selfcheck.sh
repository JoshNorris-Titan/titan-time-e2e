#!/usr/bin/env bash
# mail-selfcheck.sh — can the suite read mail at all?
#
# Run this BEFORE debugging a failing email test. It checks the READER, not the
# app's sending: it logs in as the administrator, opens the Emails Sent page, and
# reports what it can see. If this passes and an email test still fails, the
# problem is the app not raising the mail — not the suite being unable to read it.
#
# There is no mail catcher any more. Mail is read from the app's own admin page
# (Core.EmailsSent_Overview), so there is nothing to install, expose or configure
# beyond an administrator login that already exists on every environment.
#
#   tools/mail-selfcheck.sh
#
# Env:
#   TT_BASE_URL                    app origin (default http://localhost:8080)
#   TT_ADMIN_USER / TT_ADMIN_PASS  administrator account
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$TT_ROOT/lib/_login.sh"

BASE="${TT_BASE_URL:-http://localhost:8080}"

command -v playwright-cli >/dev/null 2>&1 \
  || { echo "FAIL: playwright-cli not found — run 'npm ci' in $TT_ROOT"; exit 1; }

# Open a session if one is not already up; harmless when it is.
playwright-cli open "$BASE/" >/dev/null 2>&1 || true

echo "checking the mail reader against $BASE"

# tt_mail_prepare tt_fail's with a pointed message if the page cannot be opened.
tt_mail_prepare

rows="$(_tt_mail_rows)"
count="$(printf '%s\n' "$rows" | grep -c . || true)"

echo "  Emails Sent page opened as ${TT_ADMIN_USER:-MxAdmin}"
echo "  rows visible on the first page: $count"

if [ "$count" -gt 0 ]; then
  echo "  newest row: $(printf '%s\n' "$rows" | head -1 | cut -c1-160)"
else
  echo "  note: the page is readable but empty. That is a valid state on a fresh"
  echo "        environment; it only means this check cannot show you a sample."
fi

# The sort matters: the grid pages at 20, and without a newest-first order a fresh
# message can land on a page no read would ever look at.
sorted="$(_tt_mail_sort_newest)"
case "$sorted" in
  desc) echo "  sorted newest-first: yes" ;;
  nocol) echo "  WARNING: no 'Sent Date' column found — new mail may not be on page one" ;;
  *)     echo "  WARNING: could not sort newest-first (state: $sorted) — new mail may not be on page one" ;;
esac

echo "PASS: the suite can read mail from the Emails Sent admin page"
