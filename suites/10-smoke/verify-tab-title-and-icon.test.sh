#!/usr/bin/env bash
# The browser tab names the page, and shows Titan's icon.
#
# The app's start page (theme/web/index.html) strips the client's "<app title> - " prefix
# from the tab title and capitalizes every word, and replaces the stock Mendix icon with
# Titan's: a PNG set plus an SVG that switches red / white with light and dark mode.
#
#   1  e2e_pm lands on its dashboard; the tab reads "Project Manager Dashboard"
#      (before: "Mendix - Project manager dashboard")
#   2  e2e_tm lands on its dashboard; the tab reads "Titan Manager Dashboard"
#      (before: "Mendix - Project manager dashboard" -- the page was mistitled)
#   3  the page links the switching SVG icon, and the server serves it as SVG
#
# Exact-match assertions, so the old titles fail them. Reads the tab title and the
# icon link only; changes no data.
#
# Environment: TT_BASE_URL (required), TT_ROLE_PASS.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

# tab_title -- the document title, polled briefly: the client sets it as the page opens,
# and the start page rewrites it straight after.
tab_title() {
  local want="$1" got="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    got="$(playwright-cli eval "() => document.title" 2>/dev/null | _tt_eval_str)"
    [ "$got" = "$want" ] && break
    sleep 0.5
  done
  printf '%s' "$got"
}

check_tab() {
  local user="$1" ready="$2" want="$3" got
  tt_login "$user" "$ready"
  got="$(tab_title "$want")"
  [ "$got" = "$want" ] || tt_fail "$user: tab title is '$got', expected '$want'"
  echo "  PASS: $user -> tab reads '$want'"
}

check_tab "e2e_pm" "Project Manager Dashboard" "Project Manager Dashboard"
check_tab "e2e_tm" "Add Customer"              "Titan Manager Dashboard"

icon="$(playwright-cli eval "() => { const l = document.querySelector('link[rel=\"icon\"][type=\"image/svg+xml\"]'); if (!l) return 'NOLINK'; return fetch(l.href).then(r => r.status + ' ' + (r.headers.get('content-type') || '') + ' ' + l.getAttribute('href')).catch(e => 'ERR:' + e.message); }" 2>/dev/null | _tt_eval_str)"
case "$icon" in
  "200 image/svg+xml"*titan-icon.svg*) echo "  PASS: switching icon linked and served ($icon)" ;;
  *) tt_fail "tab icon: expected the titan-icon.svg link served as image/svg+xml, got '$icon'" ;;
esac

echo "PASS: verify-tab-title-and-icon — tabs name the page and carry the Titan icon"
