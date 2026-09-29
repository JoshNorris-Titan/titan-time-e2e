#!/usr/bin/env bash
# verify-hr-dashboard-summary.test.sh
#
# The HR dashboard's stage counters actually aggregate something.
#
# WHAT THIS REPLACED. The previous version logged in with "WEEKLY TO PROCESS" as
# its ready-text and then asserted that "WEEKLY TO PROCESS" was on the page, among
# three other tab captions. One of its four assertions was therefore guaranteed by
# the login that preceded it, and none of them touched the aggregation its own
# header claimed to confirm. It could not have failed for the reason it existed.
#
# WHAT IT CHECKS NOW
#   A. Each stage tile carries its own caption (all six: the login now waits on a
#      widget, so it proves none of them).
#   B. All six stage counters render, and render a number. Nothing checked this
#      before, so a renamed or dropped card was invisible.
#   C. They are not all zero. Main.DS_CalculateNumStatus derives every counter from
#      ONE retrieve, filtered five ways, so an all-zero set is the signature of
#      that single retrieve coming back empty - the one failure that takes out the
#      whole summary at once. By the time this step runs the earlier consultant and
#      approval steps have put entries into the system, so all-zero means broken
#      rather than quiet.
#
# WHAT IT STILL DOES NOT CHECK. That a counter matches the list on its own tab.
# The counters may be scoped by the dashboard's month or week selector while a tab
# gallery shows one week, in which case the two can legitimately differ - and
# asserting they match would produce a confident, wrong failure. Settling that
# needs one look at a running dashboard; until then this does not pretend to it.
#
# Read-only.
set -euo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

CARDS="cardKpiPending cardKpiManager cardKpiCustomer cardKpiProcess cardKpiInvoice cardKpiSent"

# hd_kpi <card> — the number shown on one stage card, or a marker.
# MISSING: the card is not on the page at all. NAN: it is there but shows no digits.
hd_kpi() {
  playwright-cli eval "() => { const e=document.querySelector('.mx-name-$1'); if(!e) return 'MISSING'; const m=(e.innerText||'').match(/(\\d+)\\s*\$/); return m ? m[1] : 'NAN'; }" 2>/dev/null | _tt_eval_str
}

tt_login "e2e_hr" "$TT_HR_READY"

# ------------------------------------------------------------- A. the stage captions
# Each stage tile must carry its own caption. The login waits on a WIDGET
# (TT_HR_READY) since 2026-09-28, so it proves no caption at all and all six are
# asserted here - each inside ITS OWN tile rather than anywhere on the page, which
# the old body-wide check could not tell apart ("Sent" and "Pending" appear
# elsewhere on this dashboard).
#
# The captions are sentence case since model 5124c78e (2026-09-21), which changed
# them from "WEEKLY TO PROCESS" etc. That edit is what this step exists to notice:
# the old upper-case captions are no longer on the page and the check fails on them.
# Matched case-sensitively on purpose.
HD_CAPTIONS="cardKpiPending:Pending
cardKpiManager:Manager approval
cardKpiCustomer:Client approval
cardKpiProcess:Weekly to process
cardKpiInvoice:Monthly to be invoiced
cardKpiSent:Sent"

# hd_caption <card> <caption> — OK, MISSING (no tile), or the tile's text when the
# caption is not in it.
hd_caption() {
  playwright-cli eval "() => { const e=document.querySelector('.mx-name-$1'); if(!e) return 'MISSING'; const t=(e.innerText||'').replace(/\s+/g,' ').trim(); return t.indexOf('$2') >= 0 ? 'OK' : 'TEXT:'+t; }" 2>/dev/null | _tt_eval_str
}

badcap=""
while IFS=: read -r card caption; do
  r="$(hd_caption "$card" "$caption")"
  [ "$r" = "OK" ] || badcap="$badcap
      $card should read '$caption' but: $r"
done <<< "$HD_CAPTIONS"
if [ -n "$badcap" ]; then
  echo "FAIL: verify-hr-dashboard-summary - stage caption(s) wrong or missing:$badcap"
  exit 1
fi

# ------------------------------------------------------------ B. the counters render
missing=""
nan=""
total=0
shown=""
for c in $CARDS; do
  v="$(hd_kpi "$c")"
  case "$v" in
    MISSING) missing="$missing $c" ;;
    NAN)     nan="$nan $c" ;;
    *)       total=$((total + v)); shown="$shown $c=$v" ;;
  esac
done

if [ -n "$missing" ]; then
  echo "FAIL: verify-hr-dashboard-summary - stage counter(s) not on the page:$missing"
  echo "      Either the card was renamed in Studio Pro or the summary stopped rendering."
  exit 1
fi

if [ -n "$nan" ]; then
  echo "FAIL: verify-hr-dashboard-summary - stage counter(s) showing no number:$nan"
  echo "      The card is present but its count did not render, so Main.DS_CalculateNumStatus"
  echo "      returned nothing for it."
  exit 1
fi

echo " counters:$shown"

# ------------------------------------------------------------- C. they aggregate
if [ "$total" -eq 0 ]; then
  echo "FAIL: verify-hr-dashboard-summary - every stage counter is zero."
  echo "      All six are derived from a single retrieve in Main.DS_CalculateNumStatus,"
  echo "      so all-zero is what that retrieve failing looks like. The consultant and"
  echo "      approval steps run before this one and leave entries behind, so an empty"
  echo "      summary here is a broken aggregation rather than an idle environment."
  exit 1
fi

echo "PASS: verify-hr-dashboard-summary - all six stage counters render and aggregate (total $total across stages)"
