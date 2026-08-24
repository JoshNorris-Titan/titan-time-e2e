#!/usr/bin/env bash
# Regression test for TT-682 — Titan Manager search should filter as you type
# (not require pressing Enter).
#
# Logs in as TitanManager, types a partial customer name into the customer search
# box, and asserts the customers list narrows on keystroke (no Enter) and shows the
# match. Read-only: typing into a client-side search filter, nothing saved.
#
# Requires the widget-naming pass deployed (txtCustomerSearch, galCustomers).
# Env: TT_BASE_URL, TT_ROLE_PASS.
set -euo pipefail
source "$(dirname "$0")/lib/_login.sh"

# Count customer cards ("<name> N projects") currently rendered in the customers gallery.
card_count() {
  playwright-cli eval "() => { const t=(document.querySelector('.mx-name-galCustomers')||{}).innerText||''; return (t.match(/\\d+\\s+projects?/g)||[]).length; }" 2>/dev/null | sed -n '2p' | tr -dc '0-9'
}

tt_login "e2e_tm" "Add Customer"

initial="$(card_count)"
{ [ -n "$initial" ] && [ "$initial" -ge 2 ]; } || tt_fail "TT-682: need >=2 customers to test filtering (got '$initial')"

# Type a partial customer name WITHOUT pressing Enter.
playwright-cli click ".mx-name-txtCustomerSearch input" >/dev/null 2>&1
playwright-cli type "Tit" >/dev/null 2>&1
sleep 3

after="$(card_count)"
[ -n "$after" ] || tt_fail "TT-682: could not read customer list after typing"
[ "$after" -lt "$initial" ] || tt_fail "TT-682: list did not narrow on keystroke ($initial -> $after) — search-as-you-type not working"

playwright-cli eval "() => String(/Titan/i.test((document.querySelector('.mx-name-galCustomers')||{}).innerText||''))" 2>/dev/null | grep -qiw true \
  || tt_fail "TT-682: filtered list does not contain the typed match 'Titan'"

echo "PASS: verify-tm-search-as-you-type (TT-682) — customer search narrows on keystroke ($initial -> $after), no Enter"
