#!/usr/bin/env bash
# tt-timeout: 12m
# verify-hr-monthly-group-month-label.test.sh
#
# On HR's "Monthly to be invoiced" tab, each month group's label names the month its
# weeks belong to. Bug-reproduction spec: RED UNTIL THE MODEL FIX LANDS.
#
# THE BUG (seen on dev 2026-09-28, run log hrgroups-4a): the tab's month labels read
# one month EARLY. verify-tt683-a1's census printed
#     export census (e2e/all rows): September 2026=2e2e/2; June 2026=0e2e/6;
# where the "September 2026" group held the Oct 18 - Oct 24 week - and exporting it
# produced 2026-1031-*.pdf files whose heading reads October 2026 - and the
# "June 2026" group held a Jul 26 - Aug 01 row. The export itself is right (its
# file name is formatted with formatDateTimeUTC); only the group's label is wrong.
#
# LIKELY CAUSE (not proven here - the model is not readable from this suite). An
# entry's month is Main.MonthlyHelper.MonthStart = beginOfMonth(addDays(Timesheet/
# EndDate, -1)), and MonthlyHelper's dates are UNLOCALIZED (lib/_tt683.sh,
# tt683_is_month_end). Oct 1 00:00 UTC rendered in the session's time zone
# (America/Chicago) is Sep 30, 19:00 - "September". The label wants the UTC
# formatting the file name already uses.
#
# WHAT IT ASSERTS, per row in every month group (all groups expanded):
#   * a week wholly inside one month (Oct 18 - Oct 24) must sit under THAT month;
#   * a week spanning two months (Sep 27 - Oct 03) must sit under one of the two.
# That is the app's own rule stated without its date arithmetic, so it cannot
# disagree with the rule on which of a boundary week's two months is right. At least
# one wholly-inside row must be checked, or there is no verdict: a tab of boundary
# weeks only would pass a label that is one month early.
#
# All groups are read, including rows of consultants the suite does not own - this
# step only reads, and a wrong label is wrong for everyone. It needs at least one
# e2e row so that the verdict never depends on somebody else's data alone: when the
# tab has none it processes the suite's own To Process entries (one-way, but only
# ever the e2e consultants', see _tt683_owned_js) until one arrives.
#
# Consumes: in a full run nothing; with no e2e row on the tab, up to 4 of the suite's
# To Process entries, which it moves to AwaitingExport.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

# mgl_census — expand every month group and judge every row, one line each:
#   <verdict>|<group label>|<week>|<consultant>|<inside one month 1/0>|<e2e 1/0>
# verdict: OK (inside, same month) | EDGE (spans two months, one of them) |
#          BAD (not the month of any of its days) | NOPARSE
mgl_census() {
  tt_hr_expand_all >/dev/null
  playwright-cli eval "() => { $(_tt_hr_grp_js) if (HG.kind !== 'Invoice') return 'ERR:the Monthly tab is not open (kind=' + HG.kind + ')'; const M = ['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec']; const own = t => { $(printf 'return %s;' "$(_tt683_owned_js)") }; const out = []; for (const x of HG.groups()) { const lm = M.indexOf(((x.label.match(/[A-Za-z]{3,}/) || [''])[0]).slice(0, 3).toLowerCase()); for (const r of HG.rows(x.g)) { const cell = ((r.querySelector('.mx-name-txtInvoiceWeek') || {}).innerText || '').replace(/\s+/g, ' ').trim(); const who = ((r.querySelector('.mx-name-txtInvoiceConsultant') || {}).innerText || '').replace(/\s+/g, ' ').trim(); const k = HG.wk(cell) || HG.wk(r.innerText || ''); const m = k.match(/^([A-Z][a-z]{2}) \d\d - ([A-Z][a-z]{2}) \d\d$/); let v = 'NOPARSE', inside = 0; if (m && lm >= 0) { const a = M.indexOf(m[1].toLowerCase()), b = M.indexOf(m[2].toLowerCase()); inside = (a === b) ? 1 : 0; if (a === b) v = (lm === a) ? 'OK' : 'BAD'; else v = (lm === a || lm === b) ? 'EDGE' : 'BAD'; } out.push([v, x.label, k || cell, who, inside, own(who) ? 1 : 0].join('|')); } } return out.join('\n'); }" 2>/dev/null | _tt_eval_str | grep -v '^null$' | grep .
}

mgl_open() {
  tt_login "e2e_hr" "$TT_HR_READY"
  tt_hr_click_tab "$TT683_TAB_INVOICE" "HR Monthly to be invoiced tab"
  tt_wait_for "$TT_HR_LST_MONTHS" "the Monthly to be invoiced month list (lstInvoiceMonths)"
}

mgl_open
C="$(mgl_census)"
case "$C" in ERR:*) tt_fail "${C#ERR:}" ;; esac

if ! printf '%s\n' "$C" | grep -q '|1$'; then
  echo "no e2e row on the Monthly tab - processing the suite's To Process entries to put some there"
  ( tt683_process_all_toprocess 4 ) >/dev/null
  mgl_open
  C="$(mgl_census)"
  case "$C" in ERR:*) tt_fail "${C#ERR:}" ;; esac
  printf '%s\n' "$C" | grep -q '|1$' \
    || tt_fail "no e2e row reached the Monthly to be invoiced tab, even after processing the suite's To Process entries - no verdict. Rows seen: ${C:-none}"
fi

echo "month groups and their rows:"
printf '%s\n' "$C" | sed 's/^/  /'

np="$(printf '%s\n' "$C" | grep -c '^NOPARSE|')"
[ "$np" -eq 0 ] || tt_fail "$np row(s) have no readable week (.mx-name-txtInvoiceWeek) or group label - the rule cannot be applied: $(printf '%s\n' "$C" | grep '^NOPARSE|' | tr '\n' ';')"

inside="$(printf '%s\n' "$C" | awk -F'|' '$5 == 1' | grep -c .)"
[ "$inside" -gt 0 ] || tt_fail "every row on the tab is a week spanning two months, so a label one month off could not be told from a right one - no verdict"

badn="$(printf '%s\n' "$C" | grep -c '^BAD|')"
if [ "$badn" -gt 0 ]; then
  echo "FAIL: verify-hr-monthly-group-month-label - $badn row(s) sit under a month none of their days fall in:"
  printf '%s\n' "$C" | grep '^BAD|' | awk -F'|' '{ printf "  group \"%s\" holds week %s (%s)\n", $2, $3, $4 }'
  echo "  A group label one month early is what a UTC month start (Main.MonthlyHelper.MonthStart, unlocalized) rendered in America/Chicago looks like."
  exit 1
fi
echo "PASS: verify-hr-monthly-group-month-label - every row sits under its own month ($inside wholly inside one month, $(printf '%s\n' "$C" | grep -c '^EDGE|') spanning two)"
