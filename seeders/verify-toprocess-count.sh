#!/usr/bin/env bash
# Report what is actually sitting on the HR dashboard's WEEKLY TO PROCESS tab.
#
# Independent of the seeder's own tallies: it counts CARDS on the tab rather than
# trusting how many submits/approvals were reported. Prints the dashboard KPI
# (every consultant) plus a per-week count of rows owned by the e2e consultants.
#
# Not named *.test.sh -- it asserts nothing, it just reports.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
cd "$(dirname "$0")/../.."   # seeders/ -> tests/ -> project root
source tests/lib/_login.sh

pw() { playwright-cli eval "$1" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//'; }

NAMES="E2E Consultant Three|E2E Consultant Two|E2E Consultant"
owned_js() {
  local n out="" OLD="$IFS"; IFS='|'
  for n in $NAMES; do [ -n "$n" ] || continue; out="$out || f==='$n'"; done
  IFS="$OLD"; echo "(false${out})"
}

tt_login "e2e_hr" "$TT_HR_READY"
sleep 3

echo "KPI counts (ALL consultants):"
for c in Pending:cardKpiPending Manager:cardKpiManager Client:cardKpiCustomer Process:cardKpiProcess Invoice:cardKpiInvoice Sent:cardKpiSent; do
  printf '  %-9s %s\n' "${c%%:*}" "$(pw "() => { const e=document.querySelector('.mx-name-${c##*:}'); if(!e) return 'NA'; const m=(e.innerText||'').trim().match(/(\d+)\s*$/); return m?m[1]:'NA'; }")"
done

tt_hr_try_click_tab "Weekly to process" >/dev/null
sleep 3

# Weekly to process is a list of week GROUPS since 2026-09-28 (model b2202878 /
# 771be886), each group's rows rendered only while it is expanded. Open them all,
# then count owned rows per group by their consultant cell.
tt_hr_expand_all >/dev/null 2>&1

echo
echo "Weekly to process, per week (rows owned by e2e consultants):"
PER="$(playwright-cli eval "() => { $(_tt_hr_grp_js) return HG.groups().map(x => { let c=0; for (const r of HG.rows(x.g)) { const f=((r.querySelector('.mx-name-txtProcessConsultant')||{}).innerText||'').trim(); if ($(owned_js)) c++; } return x.label + '~~' + c; }).join('\n'); }" 2>/dev/null | _tt_eval_str | grep -v '^null$' | grep .)"
TOTAL=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  N="${line##*~~}"; case "$N" in ''|*[!0-9]*) N=0 ;; esac
  printf '  %-44s %s\n' "${line%~~*}" "$N"
  TOTAL=$((TOTAL + N))
done <<EOF2
$PER
EOF2
echo
echo "TOTAL owned rows in Weekly to process: $TOTAL"
