#!/usr/bin/env bash
# READ-ONLY probe: how recent is the build deployed to dev?
#
# Opens the Connect my LLM popup and reads its structure. Opening it only
# creates a non-persistable helper - no database write, no token minted.
#
#   TT_BASE_URL=https://titantime100-development.mendixcloud.com \
#   mxcli playwright verify tests/verify-tt654-dev-build-probe.test.sh \
#     --base-url https://titantime100-development.mendixcloud.com --verbose

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_consultant" "My Timesheets"

echo "--- open Connect my LLM ---"
playwright-cli eval "() => { const b=document.querySelector('.mx-name-actionButtonConnectMyLLM'); if(!b) return 'BUTTON NOT FOUND'; b.click(); return 'clicked'; }" 2>/dev/null | sed -n '2p'
sleep 4

echo "--- popup tabs ---"
playwright-cli eval "() => [...document.querySelectorAll('.mx-tabcontainer-tabs > li')].map(l=>l.innerText.trim()).join(' | ') || 'NO TABS'" 2>/dev/null | sed -n '2p'

echo "--- placeholder token text (new build says CLICK-GENERATE-MY-TOKEN-FIRST) ---"
playwright-cli eval "() => { const t=[...document.querySelectorAll('textarea')].map(x=>x.value).join(' ~~ '); return t.slice(0,400) || 'NO TEXTAREAS'; }" 2>/dev/null | sed -n '2p'

echo "--- copy buttons + step headings ---"
playwright-cli eval "() => JSON.stringify({ copyBtns: document.querySelectorAll('.mcp-copy').length, generateBtn: document.querySelectorAll('.mx-name-actionButtonGenerateToken').length, headings: [...document.querySelectorAll('h4,h5,h6')].map(h=>h.innerText.trim()).filter(Boolean).slice(0,8) })" 2>/dev/null | sed -n '2p'

echo "PROBE COMPLETE"
