#!/usr/bin/env bash
# Tier 0 smoke test (negative, anonymous) — invalid customer-approval token is rejected.
#
# The anonymous customer-approval deep link /p/customer-approval/<token> runs
# Main.NAV_Email_RecieveToken, which requires the token to be exactly 44 chars.
# An invalid-length token must be rejected and the user sent to the home/login
# page — it must NOT reach the Customer Approval page. No login required.
#
# Environment:
#   TT_BASE_URL   app origin (no trailing slash)
set -euo pipefail

BASE="${TT_BASE_URL:-http://localhost:8080}"
fail() { echo "FAIL: $*"; exit 1; }

# Ensure we are anonymous (no leftover session), then hit the deep link with a
# deliberately invalid (non-44-char) token.
playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$BASE/p/customer-approval/not-a-valid-token" >/dev/null 2>&1

# Assert the invalid token was rejected: we land on the home/login page and the
# Customer Approval page ("Customer Approve All") is NOT shown. Poll for the
# post-redirect state (Mendix long-polls, so never wait on network idle).
ok=""
for _ in $(seq 1 20); do
  if playwright-cli eval "() => String(!/Customer Approve All/.test(document.body ? document.body.innerText : '') && /Login|Sign In/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null \
       | grep -qiw true; then
    ok=1; break
  fi
  sleep 2
done

[ -n "$ok" ] || fail "invalid-length token was not rejected (reached the Customer Approval page or did not land on home/login)"

echo "PASS: verify-anon-bad-token — invalid token rejected, redirected to home/login"
