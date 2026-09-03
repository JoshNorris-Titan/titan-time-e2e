#!/usr/bin/env bash
# Tier 0 smoke test (negative, anonymous) — an invalid customer-approval token
# lands on the invalid-link page.
#
# The anonymous customer-approval deep link /p/customer-approval/<token> runs
# Main.NAV_Email_RecieveToken, which requires the token to be exactly 44 chars
# AND to resolve to a Main.ApprovalToken row whose TokenStatus is Active. Both
# failure branches show Main.Customer_LinkInvalid ("This approval link is no
# longer valid"). It must still NOT reach the Customer Approval page. No login
# required.
#
# THIS ASSERTS THE POST-2026-09-03 CONTRACT. The short-token branch used to end
# in a Show-home-page action, so this test previously looked for Login/Sign In
# text. That was replaced because a customer arriving here has no account — a
# login form was the wrong answer to a stale approval link.
#
# Selecting on .mx-name-textLinkInvalidHeading rather than on the copy: the
# heading text is the kind of thing that gets reworded, the widget name is not.
# The eval result is read from line 2 of the output rather than grepped — a grep
# for the expected value also matches the ECHOED SOURCE on line 1, which is a
# silent false pass.
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

# Assert the invalid token was rejected: the invalid-link page is rendered and
# the Customer Approval page ("Customer Approve All") is NOT. Poll for the
# post-navigation state (Mendix long-polls, so never wait on network idle).
ok=""
for _ in $(seq 1 20); do
  got="$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-textLinkInvalidHeading') && !/Customer Approve All/.test(document.body ? document.body.innerText : ''))" 2>/dev/null | sed -n '2p' | tr -d '"')"
  if [ "$got" = "true" ]; then
    ok=1; break
  fi
  sleep 2
done

[ -n "$ok" ] || fail "invalid-length token was not rejected (expected the Main.Customer_LinkInvalid page via .mx-name-textLinkInvalidHeading; got neither that nor a non-approval page)"

echo "PASS: verify-anon-bad-token — invalid token rejected, invalid-link page shown"
