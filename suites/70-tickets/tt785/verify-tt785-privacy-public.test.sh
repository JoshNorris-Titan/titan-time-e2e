#!/usr/bin/env bash
# TT-785 — the privacy policy is public: a signed-out visitor opening /p/privacy
# sees Core.PrivacyPolicy, not the sign-in page.
#
# WHY THIS EXISTS. LinkedIn checks this address before it approves the developer
# app behind the TT-728 news card. The page is reachable only because it is
# granted to Core.Anonymous and carries the page URL "privacy"; drop either and a
# visitor is sent to sign in (or gets nothing), which LinkedIn reads as "no
# privacy policy". Nothing else in the suite opens this page.
#
# What it asserts, as an anonymous visitor (cookies cleared):
#   1. the policy heading (.mx-name-txtPolicyTitle) and the contact paragraph
#      (.mx-name-txtPolicyContactBody) render;
#   2. the address is still /p/privacy — not bounced to the login page;
#   3. the contact paragraph names rachael@titanconsulting.net, so the page is
#      the real policy rather than an empty shell.
#
# Read-only: no login, no data written. Selects on .mx-name-* only. The eval
# result is read from line 2 of the output, never grepped (line 1 echoes the
# source, so a grep is a silent false pass).
#
# Environment:
#   TT_BASE_URL   app origin (no trailing slash)
set -euo pipefail

TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

BASE="${TT_BASE_URL:-http://localhost:8080}"
fail() { tt_fail "$*"; }

playwright-cli cookie-clear >/dev/null 2>&1
playwright-cli goto "$BASE/p/privacy" >/dev/null 2>&1

# Poll for the rendered page (Mendix long-polls, so never wait on network idle).
got=""
for _ in $(seq 1 20); do
  got="$(playwright-cli eval "() => { const q=n=>document.querySelector('.mx-name-'+n); const t=q('txtPolicyTitle'), c=q('txtPolicyContactBody'); if(!t || !c) return 'WAIT'; return [location.pathname, (c.innerText||'').replace(/\s+/g,' ').trim()].join('|'); }" 2>/dev/null | sed -n '2p' | tr -d '"')"
  [ -n "$got" ] && [ "$got" != "WAIT" ] && break
  sleep 2
done

[ -n "$got" ] && [ "$got" != "WAIT" ] \
  || fail "/p/privacy did not render Core.PrivacyPolicy for an anonymous visitor (no .mx-name-txtPolicyTitle / txtPolicyContactBody) - is the page still granted to Core.Anonymous with URL 'privacy'?"

path="${got%%|*}"
contact="${got#*|}"
case "$path" in
  */p/privacy) ;;
  *) fail "expected to stay on /p/privacy, ended on $path" ;;
esac
case "$contact" in
  *rachael@titanconsulting.net*) ;;
  *) fail "contact paragraph does not name rachael@titanconsulting.net: $contact" ;;
esac

echo "PASS: verify-tt785-privacy-public — /p/privacy renders the policy for a signed-out visitor"
