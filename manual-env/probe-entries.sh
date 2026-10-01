#!/usr/bin/env bash
# READ-ONLY: per-week entry statuses for one Manual consultant. Usage: probe-entries.sh <user> "<Full Name>"
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$TT_ROOT/lib/_login.sh"
u="$1"; n="$2"
playwright-cli close >/dev/null 2>&1; playwright-cli open "$TT_BASE_URL/" >/dev/null 2>&1
tt_login "$u" "My Timesheets"; sleep 2
playwright-cli eval "() => new Promise(res => { const g=(x)=>new Promise(r=>mx.data.get({xpath:x,filter:{amount:2000},callback:r,error:e=>r([])})); Promise.all([g(\"//Main.Timesheet[Main.AssignmentEntry_Timesheet/Main.AssignmentEntry/Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName='$n']\"), g(\"//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName='$n']\"), g(\"//Main.Project[Main.Assignment_Project/Main.Assignment/ConsultantName='$n']\"), g(\"//Main.Assignment[ConsultantName='$n']\")]).then(([ts,es,ps,as])=>{ const d={}; ts.forEach(t=>d[t.getGuid()]=new Date(t.get('StartDate')).toISOString().slice(0,10)); const pn={}; ps.forEach(p=>pn[p.getGuid()]=p.get('Name').replace('Manual ','')); const ap={}; as.forEach(a=>ap[a.getGuid()]=pn[a.get('Main.Assignment_Project')]||'?'); const w={}; es.forEach(e=>{ const k=d[e.get('Main.AssignmentEntry_Timesheet')]||'?'; (w[k]=w[k]||[]).push(ap[e.get('Main.AssignmentEntry_Assignment')]+'='+e.get('Status')+'('+e.get('TotalHours')+')'); }); res(Object.keys(w).sort().map(k=>k+'  '+w[k].sort().join('  ')).join('\n')); }); })" 2>/dev/null | _tt_eval_str
playwright-cli close >/dev/null 2>&1
