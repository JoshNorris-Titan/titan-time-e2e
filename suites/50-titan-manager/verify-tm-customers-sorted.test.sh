#!/usr/bin/env bash
# Regression test for TT-674 (Titan Manager dashboard lists not sorted).
#
# Logs in as the TitanManager role and asserts the Customers list on the Titan
# Manager dashboard renders in ascending (alphabetical) order.
#
# Targets the stable `.mx-name-galCustomers` gallery (post widget-naming pass) and
# parses the "<name> N projects" card text.
#
# Environment:
#   TT_BASE_URL   app origin (no trailing slash)
#   TT_ROLE_PASS  password for the e2e_* role accounts (default E2ETest123!)
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

fail() { echo "FAIL: $*"; exit 1; }

# --- Log in as the TitanManager role account ---
# tt_login handles both the legacy /login.html form and the current custom
# Core.Login page, and logs out any prior session first.
tt_login "e2e_tm" "Add Customer"

# --- Assert the Customers list is sorted ascending ---
# Parse "<CustomerName> N projects" cards from the customers gallery, then check
# each name is <= the next (case-insensitive locale compare).
playwright-cli eval "() => {
  const t = (document.querySelector('.mx-name-galCustomers') || {}).innerText || '';
  const names = (t.match(/([A-Za-z0-9][\\w .&-]*?)\\s+\\d+\\s+projects?/g) || [])
    .map(s => s.replace(/\\s+\\d+\\s+projects?\$/, '').trim());
  const sorted = names.every((n, i) => i === 0 || names[i-1].toLowerCase().localeCompare(n.toLowerCase()) <= 0);
  return String(names.length >= 2 && sorted);
}" 2>/dev/null | grep -qiw true || fail "Titan Manager customers list is NOT sorted ascending (TT-674)"

echo "PASS: verify-tm-customers-sorted (TT-674) — customers list renders in ascending order"
