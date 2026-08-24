#!/usr/bin/env bash
# Report what is actually sitting on the HR dashboard's WEEKLY TO PROCESS tab.
#
# Independent of the seeder's own tallies: it counts CARDS on the tab rather than
# trusting how many submits/approvals were reported. Prints the dashboard KPI
# (every consultant) plus a per-week count of cards owned by the e2e consultants.
#
# Not named *.test.sh -- it asserts nothing, it just reports.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib/_login.sh

pw() { playwright-cli eval "$1" 2>/dev/null | sed -n '2p' | sed -e 's/^"//' -e 's/"$//'; }

NAMES="E2E Consultant Three|E2E Consultant Two|E2E Consultant"
owned_js() {
  local n out="" OLD="$IFS"; IFS='|'
  for n in $NAMES; do [ -n "$n" ] || continue; out="$out || f==='$n'"; done
  IFS="$OLD"; echo "(false${out})"
}
CARD="(b => { let p=b; for(let i=0;i<12;i++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||'').trim(); if(!t) continue; const f=t.split('\n')[0].trim(); if($(owned_js)) return p; } return null; })"

tt_login "e2e_hr" "WEEKLY TO PROCESS"
sleep 3

echo "KPI counts (ALL consultants):"
for c in Pending:cardKpiPending Manager:cardKpiManager Client:cardKpiCustomer Process:cardKpiProcess Invoice:cardKpiInvoice Sent:cardKpiSent; do
  printf '  %-9s %s\n' "${c%%:*}" "$(pw "() => { const e=document.querySelector('.mx-name-${c##*:}'); if(!e) return 'NA'; const m=(e.innerText||'').trim().match(/(\d+)\s*$/); return m?m[1]:'NA'; }")"
done

pw "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='WEEKLY TO PROCESS' && getComputedStyle(e).cursor==='pointer'); if(el){el.click(); return 'Y';} return 'N'; }" >/dev/null
sleep 3

WEEKS="$(pw "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const s=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - /.test(t)))]; return s.join('|'); }")"

echo
echo "WEEKLY TO PROCESS, per week (cards owned by e2e consultants):"
TOTAL=0
OLD="$IFS"; IFS='|'
for w in $WEEKS; do
  IFS="$OLD"
  [ -n "$w" ] || continue
  pw "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return 'N'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$w')===0); if(el){el.click(); return 'Y';} return 'N'; }" >/dev/null
  sleep 3
  N="$(pw "() => { const card=$CARD; const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return '0'; let n=0; for(const b of [...g.querySelectorAll('.mx-name-btnProcess')]){ if(card(b)) n++; } return String(n); }")"
  case "$N" in ''|*[!0-9]*) N=0 ;; esac
  printf '  %-26s %s\n' "$w" "$N"
  TOTAL=$((TOTAL + N))
  IFS='|'
done
IFS="$OLD"
echo
echo "TOTAL owned cards in WEEKLY TO PROCESS: $TOTAL"
