#!/usr/bin/env bash
# TT-647 angle 4 — the approver lines appear ONLY on the To Process tab.
#
# All four HR tabs USED TO render the same snippet (Main.SNIP_HRDashboardTab), with
# the rows separated purely by visibility expressions on $HRDashboardTab/Status. The
# TT-647 texts lived in the row gated to ToProcess, so the risk this guards was bleed
# onto Manager Approval, Client Approval or Sent.
#
# TT-724 phase 4 inlined that snippet into Main.HRDashboard and split it into four
# independent per-tab copies, so the approver texts now exist only in the To Process
# copy (txtProcessManagerApprover / txtProcessClientApprover) and the other three
# tabs cannot render them by accident. That makes step 2 a weaker assertion than it
# was — it now catches someone PASTING the widgets into another tab rather than
# loosening a visibility expression.
#
# It is kept rather than deleted because step 1 still earns its keep: it proves the
# To Process copy renders the texts at all, which is the half that a mis-fold or a
# TT-648/649 edit to the neighbouring "Approver:" / "APPROVER" widgets would break.
#
# Read-only — submits nothing and approves nothing. Env: TT_BASE_URL, TT_ROLE_PASS.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt647.sh"

CONSULTANTS="E2E Consultant"

# approver_widget_count — how many TT-647 texts are rendered on the current tab.
#
# Pages the gallery in first. This step asserts a count of ZERO on the other tabs,
# and the entries gallery only renders four cards until its content box is scrolled —
# so without this the assertion passes for the wrong reason the moment a tab holds
# more than four entries, which is the one case it exists to catch.
#
# The gallery is looked up first and the approver texts are then queried INSIDE it,
# rather than as one 'gallery approver' descendant selector. TT_HR_GAL_ENTRIES is a
# comma-joined list of the four per-tab gallery names, and in CSS a descendant
# combinator binds only to the last item in such a list — 'a, b c' means "every a"
# plus "every c inside b". Written that way this would have counted the approver
# texts on one tab and every gallery on the other three, which is silently wrong.
approver_widget_count() {
  tt647_load_cards >/dev/null 2>&1 || true
  playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_ENTRIES'); return String(g ? g.querySelectorAll('$TT_HR_TXT_APPROVER1, $TT_HR_TXT_APPROVER2').length : 0); }" 2>/dev/null | sed -n '2p' | tr -d '\"'
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
