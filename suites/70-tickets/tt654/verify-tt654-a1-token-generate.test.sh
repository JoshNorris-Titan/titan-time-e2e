#!/usr/bin/env bash
# TT-654 A1 — the consultant can mint an MCP token from the dashboard.
#
# Core.ACT_MCPToken_Generate creates a Core.MCPToken for the signed-in account
# and shows the RAW token once in a message. The stored value is a SHA-256 hash,
# so this message is the only place the token is ever readable — if this button
# breaks there is no other way to connect an MCP client.
#
# Asserts:
#   - the Connect my LLM button is present on the consultant dashboard
#   - generating inside that modal yields a token in the copy-ready snippet
#
# The UI moved: this was one dashboard button that popped a message containing the
# token. It is now a modal with a per-client tab whose text area holds a ready-to-
# paste `claude mcp add ... --header "Authorization: Bearer <token>"` command.
#
# Deliberately does NOT assert the token's exact format beyond "long hex-ish
# string with dashes" — it comes from CommunityCommons.RandomHash, and pinning
# the format would break if that implementation changes.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# Drive the SHARED helper rather than repeating the click sequence here. This test
# and lib/_tt654.sh previously each hard-coded the old dashboard button, so when
# the UI became the "Connect my LLM" modal both broke and had to be found twice.
# One implementation, one place to fix.
TOKEN="$(tt654_mint_token)"

[ -n "$TOKEN" ] || tt_fail "no token in the Connect my LLM snippet after clicking Generate token"

# Only ever print a prefix — the whole point of hashing at rest is that this
# value is a live credential for the account that generated it.
echo "token issued: ${TOKEN:0:8}… (${#TOKEN} chars)"

echo "PASS: consultant can mint an MCP token via Connect my LLM"
