#!/usr/bin/env bash
# Regression test for TT-667 — HR dashboard "Sent" screen consultant dropdown not sorting.
#
# Logs in as HR, switches to the Sent tab, opens the Sent-tab consultant filter and
# asserts its options are in ascending order. Read-only.
#
# The HR dashboard renders only the active tab, and the tab-switch controls were not
# part of the widget-naming pass, so the tab is selected by clicking its text ("SENT").
# The dropdown itself is the named cbSentConsultant — it was cbTabWeekConsultant, shared
# across all four tabs, until the TT-724 phase 4 fold gave each tab its own copy.
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

tt_login "e2e_hr" "WEEKLY TO PROCESS"

# Switch to the Sent tab (auto-named control -> click by text).
tt_click_text "SENT" "HR Sent tab"
tt_wait_for ".mx-name-cbSentConsultant" "Sent tab consultant dropdown"

# Open the consultant dropdown and assert ascending order.
playwright-cli click ".mx-name-cbSentConsultant" >/dev/null 2>&1
sleep 1
playwright-cli eval "() => { const o=[...document.querySelectorAll('[role=option]')].map(e=>e.innerText.trim()).filter(Boolean); const sorted=o.every((n,i)=>i===0||o[i-1].toLowerCase().localeCompare(n.toLowerCase())<=0); return String(o.length>=2 && sorted); }" 2>/dev/null | grep -qiw true \
  || tt_fail "TT-667: Sent-tab consultant dropdown is not sorted ascending (or <2 options)"

echo "PASS: verify-hr-sent-consultant-sorted (TT-667) — Sent tab consultant dropdown sorted ascending"
