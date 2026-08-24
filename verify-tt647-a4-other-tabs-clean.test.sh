#!/usr/bin/env bash
# TT-647 angle 4 — the approver lines appear ONLY on the To Process tab.
#
# All four HR tabs render the same snippet (Main.SNIP_HRDashboardTab); the rows are
# separated purely by visibility expressions on $HRDashboardTab/Status. The TT-647
# texts live in the row gated to ToProcess, so they must not leak onto Manager
# Approval, Client Approval or Sent.
#
# This is the regression guard for the shared-snippet risk: TT-648/649 also edit
# this snippet and the neighbouring "Approver:" / "APPROVER" widgets, so a careless
# change there is most likely to show up as bleed across tabs.
#
# Read-only — submits nothing and approves nothing. Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
source "$(dirname "$0")/lib/_login.sh"
source "$(dirname "$0")/lib/_tt647.sh"

CONSULTANTS="E2E Consultant"

# approver_widget_count — how many TT-647 texts are rendered on the current tab.
approver_widget_count() {
  playwright-cli eval "() => String(document.querySelectorAll('.mx-name-galTabEntries .mx-name-textApprovedBy1, .mx-name-galTabEntries .mx-name-textApprovedBy2').length)" 2>/dev/null | sed -n '2p' | tr -d '\"'
}

# 1) Establish the widgets exist at all, on the tab that should have them.
# Without this the rest of the test would pass trivially on an unwired snippet.
tt647_hr_open_tab "$TT647_TAB_TOPROCESS"
if tt647_select_week_with "$CONSULTANTS" >/dev/null; then
  tt647_require_widgets "To Process tab"
  echo "To Process tab renders $(approver_widget_count) approver text widget(s) — baseline OK"
else
  tt_fail "To Process tab has no '$CONSULTANTS' entry to establish a baseline — run the other TT-647 scenarios first, or seed an approved entry"
fi

# 2) Every other tab must render none of them, on any week that has entries.
for TAB in "$TT647_TAB_MANAGER" "$TT647_TAB_CLIENT" "SENT"; do
  tt647_hr_open_tab "$TAB"
  if ! tt647_select_week_with "$CONSULTANTS" >/dev/null; then
    echo "  [$TAB] no '$CONSULTANTS' entries in any week — nothing to check on this tab"
    continue
  fi
  N="$(approver_widget_count)"
  echo "  [$TAB] approver text widgets rendered: $N"
  [ "$N" = "0" ] \
    || tt_fail "'$TAB' tab renders $N TT-647 approver text widget(s) — the ToProcess-only row is bleeding into other tabs"
done

echo "PASS: verify-tt647-a4-other-tabs-clean — approver lines render on To Process only"
