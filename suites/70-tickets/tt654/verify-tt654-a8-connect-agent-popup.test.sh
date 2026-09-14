#!/usr/bin/env bash
# TT-654 A8 — the "Connect my agent" popup offers Claude Code and Other only,
# walks a consultant through setting up a timesheet folder, and hands Claude a
# prompt that writes a .mcp.json for that folder.
#
# The popup used to be "Connect my LLM", with four client tabs (Claude Code,
# ChatGPT / Codex, Cursor, Other), and the Claude Code tab held a one-line
# `claude mcp add ...` command to run in a terminal. It now has two tabs, and the
# Claude Code tab has five numbered steps (make a folder, open the Claude app's
# Code tab, point the session at the folder, generate + copy + paste, start a new
# session) above a prompt that tells Claude to write .mcp.json and CLAUDE.md.
#
# Asserts:
#   1. the dashboard button reads "Connect my agent"
#   2. the popup has exactly two client tabs, captioned Claude Code and Other
#   3. the Claude Code tab carries the five numbered steps, in order
#   4. after Generate my token, the Claude Code text is the .mcp.json prompt:
#        - a server entry of type http
#        - whose url is this app's /titan-time/mcp endpoint
#        - carrying the freshly minted token, not the placeholder, as
#          "Authorization": "Bearer <token>"
#        - with "Bearer" named exactly once (tt654_mint_token takes the first
#          match, so a second one would feed every MCP spec the wrong value)
#        - and the CLAUDE.md step
#
# Mints a token on the e2e consultant, as a1 does. Reads the popup in place
# rather than through tt654_mint_token, which closes the popup before returning.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"

tt_login "$TT654_CONSULTANT" "My Timesheets"

# ── 1. the button caption ────────────────────────────────────────────────────
# The widget kept its old name, actionButtonConnectMyLLM; only the caption moved.
tt_wait_for ".mx-name-actionButtonConnectMyLLM" "Connect my agent button on the consultant dashboard"
CAPTION="$(playwright-cli eval "() => { const b=document.querySelector('.mx-name-actionButtonConnectMyLLM'); return b ? b.textContent.trim() : ''; }" 2>/dev/null | _tt_eval_str)"
[ "$CAPTION" = "Connect my agent" ] || tt_fail "dashboard button reads '$CAPTION', expected 'Connect my agent'"

playwright-cli click ".mx-name-actionButtonConnectMyLLM" >/dev/null 2>&1
tt_wait_for ".mx-name-actionButtonGenerateToken2" "Generate token button inside the Connect my agent modal"

# ── 2. exactly two client tabs ───────────────────────────────────────────────
TABS="$(playwright-cli eval "() => [...document.querySelectorAll('.mx-name-tabContainerClients .mx-tabcontainer-tabs > li')].map(l => l.textContent.trim()).join('|')" 2>/dev/null | _tt_eval_str)"
[ "$TABS" = "Claude Code|Other" ] || tt_fail "client tabs are '$TABS', expected exactly 'Claude Code|Other'"

# ── 3. the five numbered steps, in order ─────────────────────────────────────
# Claude Code is the first tab, so it is the one showing when the popup opens.
STEPS="$(playwright-cli eval "() => [1,2,3,4,5].map(i => { const e=document.querySelector('.mx-name-textClaudeStep'+i); return (e && e.offsetParent!==null) ? e.textContent.trim().slice(0,2) : '-'; }).join('')" 2>/dev/null | _tt_eval_str)"
[ "$STEPS" = "1.2.3.4.5." ] || tt_fail "Claude Code steps read '$STEPS', expected '1.2.3.4.5.' (a '-' is a missing or hidden step)"

# ── 4. the prompt, after a real token is minted ──────────────────────────────
playwright-cli click ".mx-name-actionButtonGenerateToken2" >/dev/null 2>&1
sleep 3

# Every check runs in-page and comes back as one comma-separated verdict, so a
# failure names exactly which part of the prompt is wrong.
VERDICT="$(playwright-cli eval "() => {
  const ta = document.querySelector('.mx-name-textAreaClaudeCode textarea');
  const v = ta ? ta.value : '';
  const m = v.match(/\"Authorization\": \"Bearer ([A-Za-z0-9-]{20,})\"/);
  return [
    v.includes('\"type\": \"http\"') ? 'http' : 'NO-HTTP-ENTRY',
    v.includes('\"url\": \"' + location.origin + '/titan-time/mcp\"') ? 'url' : 'NO-URL:' + location.origin,
    (m && m[1] !== 'CLICK-GENERATE-MY-TOKEN-FIRST') ? 'token' : 'NO-MINTED-TOKEN',
    (v.match(/Bearer/g) || []).length === 1 ? 'bearer1' : 'BEARER-COUNT-' + (v.match(/Bearer/g) || []).length,
    v.includes('CLAUDE.md') ? 'claudemd' : 'NO-CLAUDE-MD'
  ].join(',');
}" 2>/dev/null | _tt_eval_str)"

tt654_close_connect_modal

[ "$VERDICT" = "http,url,token,bearer1,claudemd" ] \
  || tt_fail "Claude Code prompt is wrong: $VERDICT (expected http,url,token,bearer1,claudemd)"

echo "PASS: Connect my agent popup shows Claude Code + Other, five steps, and a .mcp.json prompt with the minted token"
