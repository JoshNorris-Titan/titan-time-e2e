#!/usr/bin/env bash
# TT-654 A1 — the consultant can mint an MCP token from the dashboard.
#
# Core.ACT_MCPToken_Generate creates a Core.MCPToken for the signed-in account
# and shows the RAW token once in a message. The stored value is a SHA-256 hash,
# so this message is the only place the token is ever readable — if this button
# breaks there is no other way to connect an MCP client.
#
# Asserts:
#   - the Generate MCP token button is present on the consultant dashboard
#   - clicking it shows a message containing a token-shaped value
#
# Deliberately does NOT assert the token's exact format beyond "long hex-ish
# string with dashes" — it comes from CommunityCommons.RandomHash, and pinning
# the format would break if that implementation changes.

set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt654.sh"

BTN=".mx-name-actionButtonGenerateMCPToken"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# The button lives on the consultant dashboard. tt_login lands on the timesheet
# view, so go home first if the button is not already on screen.
if ! playwright-cli eval "() => String(!!document.querySelector('$BTN'))" 2>/dev/null | grep -qiw true; then
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  sleep 3
fi

tt_wait_for "$BTN" "Generate MCP token button on the consultant dashboard"

playwright-cli click "$BTN" >/dev/null 2>&1
sleep 3

# The token is shown in a Mendix Information popup. Read the dialog text (falling
# back to the page body) and look for a token-shaped run of characters.
TOKEN=$(playwright-cli eval "() => { const d=document.querySelector('.mx-dialog,.mx-window,[role=dialog],[class*=modal]'); const t=(d ? d.innerText : document.body.innerText) || ''; const m=t.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32,}/i); return m ? m[0] : ''; }" 2>/dev/null | sed -n '2p' | tr -d '"')

[ -n "$TOKEN" ] || tt_fail "no token-shaped value in the message after clicking Generate MCP token"

# Only ever print a prefix — the whole point of hashing at rest is that this
# value is a live credential for the account that generated it.
echo "token issued: ${TOKEN:0:8}… (${#TOKEN} chars)"

tt654_dismiss_dialog

echo "PASS: consultant can mint an MCP token from the dashboard"
