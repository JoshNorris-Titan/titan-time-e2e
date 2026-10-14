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

tt_login "e2e_hr" "$TT_HR_READY"

# Switch to the Sent tab (auto-named control -> click by text).
tt_hr_click_tab "Sent" "HR Sent tab"
tt_wait_for ".mx-name-cbSentConsultant" "Sent tab consultant dropdown"

# Open the consultant dropdown and assert ascending order, through the shared helper:
# ascending means what the database collation means (case, spaces and punctuation
# ignored at the first level). This spec's own toLowerCase().localeCompare() kept
# punctuation significant and called dev's correctly sorted list out of order once
# accounts with underscores appeared ("Rishika_test1_Consultant" before
# "Rishika_test_consultant" is right for "rishikatest1consultant" < "rishikatestconsultant";
# run 38640101950). The helper also says which failure it is: empty list vs wrong order.
tt_combobox_sorted ".mx-name-cbSentConsultant" ".mx-name-cbSentConsultant" "TT-667 Sent-tab consultant dropdown"

echo "PASS: verify-hr-sent-consultant-sorted (TT-667) — Sent tab consultant dropdown sorted ascending"
