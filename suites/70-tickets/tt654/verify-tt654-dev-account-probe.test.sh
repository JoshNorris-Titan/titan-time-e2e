#!/usr/bin/env bash
# READ-ONLY probe: does e2e_consultant have what the TT-654 manual MCP test
# script needs — one ordinary project and one NeedsLineItems project?
#
# Creates nothing, edits nothing, submits nothing. It logs in, reads the
# assignment rows on the current week, and reports what it finds so the manual
# script can be pointed at the real project names.
#
# Run against dev:
#   TT_BASE_URL=https://titantime100-development.mendixcloud.com \
#   mxcli playwright verify tests/verify-tt654-dev-account-probe.test.sh --verbose

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

ROW=".mx-name-galAssignmentRows"

tt_login "e2e_consultant" "My Timesheets"

echo "--- assignment rows (raw text) ---"
playwright-cli eval "() => { const g=document.querySelector('$ROW'); return g ? g.innerText.replace(/\n+/g,' | ') : 'NO ROWS CONTAINER'; }" 2>/dev/null | sed -n '2p'

echo "--- project name cells ---"
playwright-cli eval "() => [...document.querySelectorAll('$ROW [class*=mx-name-]')].map(e=>e.className.match(/mx-name-[A-Za-z0-9_]+/)?.[0]).filter((v,i,a)=>v&&a.indexOf(v)===i).join(', ')" 2>/dev/null | sed -n '2p'

echo "--- line-item affordances present? ---"
playwright-cli eval "() => JSON.stringify({ addTask: document.querySelectorAll('.mx-name-btnAddTask').length, expand: document.querySelectorAll('.mx-name-btnLineItemsExpand').length, collapse: document.querySelectorAll('.mx-name-btnLineItemsCollapse').length, lineName: document.querySelectorAll('.mx-name-txtLineItemName').length })" 2>/dev/null | sed -n '2p'

echo "--- week label ---"
playwright-cli eval "() => { const e=[...document.querySelectorAll('h1,h2,h3,h4,h5')].map(x=>x.innerText.trim()).filter(Boolean); return e.join(' | '); }" 2>/dev/null | sed -n '2p'

echo "--- Connect my LLM button present? (tells us if the new build is deployed) ---"
playwright-cli eval "() => JSON.stringify({ connectMyLLM: document.querySelectorAll('.mx-name-actionButtonConnectMyLLM').length, oldGenerateBtn: document.querySelectorAll('.mx-name-actionButtonGenerateMCPToken').length })" 2>/dev/null | sed -n '2p'

echo "PROBE COMPLETE"
