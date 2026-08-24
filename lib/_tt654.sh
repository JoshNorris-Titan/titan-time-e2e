#!/usr/bin/env bash
# TT-654 (MCP server) test-data helpers.
# Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_tt654.sh"
#
# TT-654 exposes Titan Time as an MCP server. Its tools (ListMyAssignments,
# GetMyWeek, SetWeekHours, SubmitWeek) operate on the SAME AssignmentEntry rows
# the timesheet page uses, and SubmitWeek calls the same server-side flow the
# page's Submit button now calls (Main.SUB_AssignmentEntry_Submit). So the data
# seeded here serves both the Playwright tests and MCP calls against the app.
#
# These helpers leave entries in DRAFT (Save Draft, never Submit). That matters:
# a submitted entry is no longer editable, so any seeded week that gets submitted
# is consumed and the seeder must be re-run for the next pass.
#
# Env:
#   TT654_PROJECT_CUSTOMER   default "E2E Customer Approval"  (ApprovalFromCustomer)
#   TT654_PROJECT_MANAGER    default "E2E Manager Approval"   (ApprovalFromManager)
#   TT654_PROJECT_LINEITEMS  default "E2E Line Items"         (NeedsLineItems)
#   TT654_CONSULTANT         default "e2e_consultant"
#   TT654_HOURS              default 8   (per weekday, Mon-Fri)
#
# The defaults are the dev/acceptance E2E fixtures. A local F5 database seeded
# from production-ish data will not have them — override the three project names
# to whatever that database actually contains.

TT654_PROJECT_CUSTOMER="${TT654_PROJECT_CUSTOMER:-E2E Customer Approval}"
TT654_PROJECT_MANAGER="${TT654_PROJECT_MANAGER:-E2E Manager Approval}"
TT654_PROJECT_LINEITEMS="${TT654_PROJECT_LINEITEMS:-E2E Line Items}"
TT654_CONSULTANT="${TT654_CONSULTANT:-e2e_consultant}"
TT654_HOURS="${TT654_HOURS:-8}"

TT654_ROWS=".mx-name-galAssignmentRows"

# Set by tt654_find_editable_row.
TT654_ORD=""
TT654_WEEK=""
TT654_WEEK_START=""

# tt654_dismiss_dialog — click the affirmative on any open Mendix popup.
# Mendix renders these as .mx-dialog / .mx-window, not [role=dialog]. Never
# clicks the close 'x' — on the submit chain that cancels the submit.
tt654_dismiss_dialog() {
  # Delegates to tt_clear_dialogs, which targets the LAST VISIBLE dialog. The
  # old body used document.querySelector and could click a stale hidden dialog,
  # stalling the submit chain silently. It also matched "close", which CANCELS
  # a blocking warning instead of confirming it.
  tt_clear_dialogs 8
}

# tt654_row_ordinal <project-substring>
# 1-based ordinal of the EDITABLE assignment row for <project-substring> on the
# week currently shown, or 0. Walks up from each Monday cell and stops as soon as
# the ancestor contains more than one day cell — that means we have left the row,
# so a project name belonging to a sibling row can never match.
#
# NeedsLineItems rows need a different editability test. On such a project the
# aggregate day cells are READ-ONLY by design — hours are entered on the task
# rows and rolled up — so the plain "is Monday editable?" check below can never
# match, and verify-tt654-a0/a3/a7 all failed with "no editable week ... found
# within 12 weeks" against a project the consultant is very much assigned to
# (verify-consultant-line-items passes on it). Worse, the task section is
# normally COLLAPSED, so it renders no inputs and no Add Task button at all
# until expanded. Hence: fast path first, then expand and look for Add Task,
# which the snippet gates on $galAssignmentRows/_IsEditable.
tt654_row_ordinal() {
  local proj="$1" ord

  # Fast path — a normal project row with an editable aggregate Monday cell.
  ord=$(playwright-cli eval "() => { const mons=[...document.querySelectorAll('$TT654_ROWS .mx-name-txtDayMon')]; const isTarget=(mon)=>{ let el=mon; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) return false; if(el.querySelectorAll('.mx-name-txtDayMon').length!==1) return false; if((el.innerText||'').indexOf('$proj')>=0) return true; } return false; }; for(let n=0;n<mons.length;n++){ const inp=mons[n].querySelector('input'); if(isTarget(mons[n]) && inp && !inp.disabled && !inp.readOnly) return String(n+1); } return '0'; }" 2>/dev/null | sed -n '2p')
  ord="${ord%\"}"; ord="${ord#\"}"
  if [ -n "$ord" ] && [ "$ord" != "0" ]; then echo "$ord"; return 0; fi

  # Slow path — a line-items row. Locate it whether or not it is editable.
  ord=$(playwright-cli eval "() => { const mons=[...document.querySelectorAll('$TT654_ROWS .mx-name-txtDayMon')]; for(let n=0;n<mons.length;n++){ let el=mons[n], row=null; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('.mx-name-txtDayMon').length!==1) break; row=el; } if(!row) continue; if((row.innerText||'').indexOf('$proj')<0) continue; if(row.querySelector('.mx-name-btnLineItemsExpand, .mx-name-btnLineItemsCollapse, .mx-name-btnAddTask')) return String(n+1); } return '0'; }" 2>/dev/null | sed -n '2p')
  ord="${ord%\"}"; ord="${ord#\"}"
  if [ -z "$ord" ] || [ "$ord" = "0" ]; then echo "0"; return 0; fi

  # Expand the task section if it is collapsed, then decide on Add Task.
  local i
  for i in 1 2 3; do
    if playwright-cli eval "() => { const mons=[...document.querySelectorAll('$TT654_ROWS .mx-name-txtDayMon')]; const mon=mons[$ord - 1]; if(!mon) return 'nf'; let el=mon, row=null; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('.mx-name-txtDayMon').length!==1) break; row=el; } if(!row) return 'nf'; return String(!!row.querySelector('.mx-name-btnAddTask')); }" 2>/dev/null | grep -qiw true; then
      echo "$ord"; return 0
    fi
    playwright-cli eval "() => { const mons=[...document.querySelectorAll('$TT654_ROWS .mx-name-txtDayMon')]; const mon=mons[$ord - 1]; if(!mon) return 'nf'; let el=mon, row=null; for(let k=0;k<12;k++){ el=el.parentElement; if(!el) break; if(el.querySelectorAll('.mx-name-txtDayMon').length!==1) break; row=el; } if(!row) return 'nf'; const t=row.querySelector('.mx-name-btnLineItemsCollapse, .mx-name-btnLineItemsExpand'); if(t){ t.click(); return 'toggled'; } return 'notoggle'; }" >/dev/null 2>&1
    sleep 2
  done

  # Toggled open and still no Add Task -> the row is not editable (submitted).
  echo "0"
}

# tt654_week_start_iso — the Sunday of the week on screen, as yyyy-MM-dd.
# The MCP tools take WeekStartDate in exactly that format, so seeding and MCP
# calls can be pointed at the same week. Best-effort: returns "" if the week
# range caption cannot be parsed, and callers report that rather than guessing.
#
# Two caption shapes are handled. The original only understood a caption
# carrying an explicit year; dev renders the range WITHOUT one — e.g.
# "E2E Aug 09 - Aug 15" — so the parse returned "" and verify-tt654-a4 aborted
# with "could not parse a yyyy-MM-dd week start". For the year-less shape the
# FIRST date in the range is the week start, and the year is chosen as whichever
# of last/this/next year puts that date nearest today. That is unambiguous for
# any week within ~6 months, which is the only range these tests navigate.
tt654_week_start_iso() {
  local iso
  iso=$(playwright-cli eval "() => {
    const t=((document.querySelector('.mx-name-txtWeekRange')||{}).innerText)||'';
    const p=n=>String(n).padStart(2,'0');
    const iso=d=>{ d.setDate(d.getDate()-d.getDay()); return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate()); };
    let m=t.match(/([A-Za-z]{3,9}\\s+\\d{1,2},?\\s+\\d{4})|(\\d{1,2}[\\/-]\\d{1,2}[\\/-]\\d{2,4})/);
    if(m){ const d=new Date(m[0]); if(!isNaN(d.getTime())) return iso(d); }
    m=t.match(/([A-Za-z]{3,9})\\s+(\\d{1,2})/);
    if(!m) return '';
    const now=new Date();
    const cands=[];
    for(const y of [now.getFullYear()-1, now.getFullYear(), now.getFullYear()+1]){
      const d=new Date(m[1]+' '+m[2]+', '+y);
      if(!isNaN(d.getTime())) cands.push(d);
    }
    if(!cands.length) return '';
    // Titan weeks start on Sunday, so the year that makes the first date a
    // Sunday is the right one. Nearest-to-today alone is not enough: 'Jan 04'
    // is ~5 months away in 2027 and ~7 in 2026, but only 2026 is a Sunday.
    const sundays=cands.filter(d=>d.getDay()===0);
    const pool=sundays.length?sundays:cands;
    pool.sort((a,b)=>Math.abs(a.getTime()-now.getTime())-Math.abs(b.getTime()-now.getTime()));
    return iso(pool[0]);
  }" 2>/dev/null | sed -n '2p')
  iso="${iso%\"}"; iso="${iso#\"}"
  echo "$iso"
}

# tt654_find_editable_row <project-substring> [max-weeks]
# Steps forward from the current week until <project-substring> has an editable
# row. Sets TT654_ORD, TT654_WEEK, TT654_WEEK_START. Fails if none is found.
tt654_find_editable_row() {
  local proj="$1" max="${2:-12}" i ord
  for i in $(seq 1 "$max"); do
    ord="$(tt654_row_ordinal "$proj")"
    # A row can report itself editable on a week whose TIMESHEET has already
    # been submitted — dev shows exactly that on "E2E Jul 26 - Aug 01"
    # (Manager row editable, but saveDraft/submit both absent). Seeding there
    # fails later at tt654_save_draft with "no Save Draft button on this week",
    # so require the week to still be open before accepting the row. Same guard
    # tt_consultant_submit_project_row uses.
    if [ -n "$ord" ] && [ "$ord" != "0" ] \
       && ! playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSaveDraft'))" 2>/dev/null | grep -qiw true; then
      ord="0"
    fi
    if [ -n "$ord" ] && [ "$ord" != "0" ]; then
      TT654_ORD="$ord"
      TT654_WEEK=$(playwright-cli eval "() => String((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'')" 2>/dev/null | sed -n '2p')
      TT654_WEEK_START="$(tt654_week_start_iso)"
      return 0
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  tt_fail "no editable week with a '$proj' row found within $max weeks (is $TT654_CONSULTANT assigned to it, and are earlier weeks already submitted?)"
}

# tt654_fill_row <ordinal> [hours]
# Fills Mon-Fri on one row. Mendix decimal inputs only commit on a real focus
# change, so this clicks two other cells in the SAME row afterwards.
tt654_fill_row() {
  local ord="$1" hrs="${2:-$TT654_HOURS}" d
  for d in Mon Tues Wed Thurs Fri; do
    playwright-cli fill ":nth-match($TT654_ROWS .mx-name-txtDay${d} input, ${ord})" "$hrs" >/dev/null 2>&1
  done
  playwright-cli click ":nth-match($TT654_ROWS .mx-name-txtDaySat input, ${ord})" >/dev/null 2>&1
  playwright-cli click ":nth-match($TT654_ROWS .mx-name-txtDayMon input, ${ord})" >/dev/null 2>&1
  sleep 1
}

# tt654_save_draft — persist without submitting, so the entry stays Draft.
tt654_save_draft() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSaveDraft'))" 2>/dev/null | grep -qiw true \
    || tt_fail "no Save Draft button on this week — cannot seed without submitting"
  playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
  sleep 3
  tt654_dismiss_dialog
}

# tt654_seed_draft <project-substring> [hours]
# Find an editable week for the project, fill Mon-Fri, Save Draft. Leaves the
# entry in Draft so both the page Submit button and the MCP SubmitWeek tool can
# still act on it. Echoes "<week-start-iso>|<week-caption>".
tt654_seed_draft() {
  local proj="$1" hrs="${2:-$TT654_HOURS}"
  tt654_find_editable_row "$proj"
  tt654_fill_row "$TT654_ORD" "$hrs"
  tt654_save_draft
  echo "${TT654_WEEK_START}|${TT654_WEEK}"
}

# tt654_add_task <row-ordinal> <task-name> [hours]
# Expands the tasks section and adds one line item with Mon-Fri hours. Only
# meaningful on a NeedsLineItems project. Editing a cell commits the LineItem.
tt654_add_task() {
  local ord="$1" name="$2" hrs="${3:-$TT654_HOURS}" i d idx
  for i in 1 2 3; do
    playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnAddTask'); return String(!!b && b.offsetParent!==null); }" 2>/dev/null | grep -qiw true && break
    local tgl
    tgl=$(playwright-cli eval "() => { for (const s of ['btnLineItemsCollapse','btnLineItemsExpand']){ const t=document.querySelector('.mx-name-'+s); if (t && t.offsetParent!==null) return s; } return ''; }" 2>/dev/null | sed -n '2p' | tr -d '"')
    [ -n "$tgl" ] && playwright-cli click ".mx-name-$tgl" >/dev/null 2>&1
    sleep 2
  done
  tt_wait_for ".mx-name-btnAddTask" "Add Task button (is '$TT654_PROJECT_LINEITEMS' really a NeedsLineItems project?)"

  playwright-cli click ".mx-name-btnAddTask" >/dev/null 2>&1
  sleep 2; tt654_dismiss_dialog

  idx=$(playwright-cli eval "() => String(document.querySelectorAll('$TT654_ROWS .mx-name-txtLineItemName input').length)" 2>/dev/null | sed -n '2p' | tr -d '"')
  [ -n "$idx" ] && [ "$idx" != "0" ] || tt_fail "Add Task did not create a task row"

  playwright-cli fill ":nth-match($TT654_ROWS .mx-name-txtLineItemName input, $idx)" "$name" >/dev/null 2>&1
  for d in Mon Tues Wed Thurs Fri; do
    playwright-cli fill ":nth-match($TT654_ROWS .mx-name-txtLine${d} input, $idx)" "$hrs" >/dev/null 2>&1
  done
  playwright-cli click ":nth-match($TT654_ROWS .mx-name-txtLineItemName input, $idx)" >/dev/null 2>&1
  sleep 2; tt654_dismiss_dialog
  echo "$idx"
}

# tt654_submit_row <ordinal>
# Submits the week via the page's Submit button and clicks through the confirm
# chain ("Are you sure? yes", then possibly "Submit Anyway" for a current/future
# week or under 40h). Returns 0 if the row became non-editable.
#
# This is the Gate-3 regression for the TT-654 refactor: the button now calls
# Main.SUB_AssignmentEntry_Submit rather than holding the logic inline, so this
# proves the page path still submits end to end.
tt654_submit_row() {
  local ord="$1"
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | grep -qiw true \
    || tt_fail "no Submit button on this week"
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  tt654_dismiss_dialog
  sleep 2
  playwright-cli eval "() => { const i=document.querySelectorAll('$TT654_ROWS .mx-name-txtDayMon input')[$ord - 1]; return String(i ? (i.disabled||i.readOnly) : false); }" 2>/dev/null | grep -qiw true
}

# ---------------------------------------------------------------------------
# MCP helpers
#
# The MCP tools are JSON-RPC over HTTP, not UI, so they would normally sit
# outside a Playwright suite. But the browser is already authenticated against
# the same origin the MCP server is mounted on, so it can call the endpoint
# directly with fetch() — which lets the suite cover the actual TT-654 feature
# rather than only its supporting UI.
#
# Each helper does a full handshake (initialize -> notifications/initialized ->
# call) so it is stateless and safe to call in any order. Responses come back as
# Streamable HTTP / SSE, i.e. "data: {json}", so the payload is extracted.
#
#   TT654_MCP_PATH   default "/titan-time/mcp" — the Path given to CreateMCPServer
#                    plus the "/mcp" suffix the module appends itself.
# ---------------------------------------------------------------------------

TT654_MCP_PATH="${TT654_MCP_PATH:-/titan-time/mcp}"

# KNOWN UNCOVERED — revoked tokens.
# Core.SUB_MCP_Authenticate resolves the bearer token with
#   retrieve Core.MCPToken where [Token = $TokenHash] [Revoked = false()]
# so a revoked token is supposed to stop working immediately. Nothing asserts
# that, and it cannot be asserted from here: Core.MCPToken/Revoked is only ever
# read — no page, microflow or MCP tool in the model sets it, so there is no way
# to revoke a token through the app and then prove the refusal.
#
# Do not paper over this with a test that flips nothing and passes. Either add a
# revoke control (a button on the consultant dashboard beside
# Core.ACT_MCPToken_Generate is the obvious place) and then assert here that a
# revoked token gets AUTHFAIL, or leave it documented as a known gap.

# _tt654_mcp_js <token> <rpc-method> <js-object-literal-params>
# Emits the JS for one full handshake + one RPC call. Params are a JS object
# LITERAL using single quotes (e.g. "{WeekStartDate:'2026-07-26'}") so the whole
# thing survives being embedded in a double-quoted shell string.
_tt654_mcp_js() {
  local tok="$1" method="$2" params="$3"
  cat <<JS
async () => {
  const url='$TT654_MCP_PATH', tok='$tok';
  const hdr=(sid)=>{ const h={'Content-Type':'application/json','Accept':'application/json, text/event-stream','Authorization':'Bearer '+tok}; if(sid) h['Mcp-Session-Id']=sid; return h; };
  const post=(body,sid)=>fetch(url,{method:'POST',headers:hdr(sid),body:JSON.stringify(body)});
  const init=await post({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'tt654-e2e',version:'1.0'}}});
  const sid=init.headers.get('Mcp-Session-Id');
  if(!sid) return 'NOSESSION:'+init.status;
  await post({jsonrpc:'2.0',method:'notifications/initialized'},sid);
  const r=await post({jsonrpc:'2.0',id:2,method:'$method',params:$params},sid);
  const raw=await r.text();
  if(r.status===401 || /"code"\\s*:\\s*401/.test(raw) || /Authentication failed/i.test(raw)) return 'AUTHFAIL';
  const m=raw.match(/data:\\s*(\\{[\\s\\S]*\\})/);
  let p; try { p = m ? JSON.parse(m[1]) : JSON.parse(raw); } catch(e) { return 'UNPARSED:'+raw.slice(0,200); }
  if(p && p.error) return 'RPCERROR:'+JSON.stringify(p.error).slice(0,200);
  if(p && p.result && p.result.content && p.result.content[0]) return String(p.result.content[0].text);
  if(p && p.result && p.result.tools) return p.result.tools.map(t=>t.name).join(',');
  return JSON.stringify(p && p.result ? p.result : p).slice(0,400);
}
JS
}

# tt654_mcp_call <token> <tool-name> <js-object-literal-args>
# Calls one MCP tool and echoes its text result. Special values:
#   AUTHFAIL     the token was rejected
#   NOSESSION:n  the endpoint did not return a session (wrong TT654_MCP_PATH?)
#   RPCERROR:..  the tool threw
tt654_mcp_call() {
  local tok="$1" name="$2" args="${3:-{\}}"
  playwright-cli eval "$(_tt654_mcp_js "$tok" "tools/call" "{name:'$name',arguments:$args}")" 2>/dev/null | _tt_eval_str | tr -d '\r'
}

# tt654_mcp_tools <token> — comma-separated tool names, or AUTHFAIL.
tt654_mcp_tools() {
  playwright-cli eval "$(_tt654_mcp_js "$1" "tools/list" "{}")" 2>/dev/null | _tt_eval_str | tr -d '\r'
}

# tt654_mint_token — mint an MCP token via the "Connect my LLM" flow and echo the
# raw token. The stored value is hashed, so the copy-ready snippet this produces is
# the only place the token is ever readable.
#
# THE UI MOVED. This used to be one button on the dashboard
# (actionButtonGenerateMCPToken) that popped a message containing the token. That
# button no longer exists — on dev it returns a count of 0 while
# actionButtonConnectMyLLM returns 1. The flow is now:
#
#   dashboard: actionButtonConnectMyLLM
#     -> modal "Connect my LLM"
#          actionButtonGenerateToken2      mints the token
#          tabContainerClients             one tab per client
#          textAreaClaudeCode              holds a ready-to-paste command:
#            claude mcp add --transport http titan-time <base>/titan-time/mcp \
#              --header "Authorization: Bearer <token>"
#
# So the token is now parsed out of that snippet rather than read from a dialog.
# Driving the old button is what made verify-tt654-a1 time out and left a4/a5/a6
# asserting against an empty token — which surfaced as "AUTHFAIL" and
# "MCP rejected a freshly minted token", i.e. as if the server were broken. It is
# not: a token minted through this flow returns all seven tools from tools/list.
tt654_mint_token() {
  local tok
  if ! playwright-cli eval "() => String(!!document.querySelector('.mx-name-actionButtonConnectMyLLM'))" 2>/dev/null | grep -qiw true; then
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 3
  fi
  tt_wait_for ".mx-name-actionButtonConnectMyLLM" "Connect my LLM button on the consultant dashboard"
  playwright-cli click ".mx-name-actionButtonConnectMyLLM" >/dev/null 2>&1

  tt_wait_for ".mx-name-actionButtonGenerateToken2" "Generate token button inside the Connect my LLM modal"
  playwright-cli click ".mx-name-actionButtonGenerateToken2" >/dev/null 2>&1
  sleep 3

  # Match on "Bearer <token>" rather than a bare hex/UUID shape: the snippet also
  # contains the app URL, and a looser pattern can match part of that instead.
  tok="$(playwright-cli eval "() => { const ta=document.querySelector('.mx-name-textAreaClaudeCode textarea, .mx-name-textAreaClaudeCode input'); const v = ta ? (ta.value || ta.innerText || '') : ''; const m = v.match(/Bearer\\s+([A-Za-z0-9-]{20,})/); return m ? m[1] : ''; }" 2>/dev/null | _tt_eval_str)"

  tt654_close_connect_modal
  printf '%s\n' "$tok"
}

# tt654_close_connect_modal — dismiss the Connect my LLM popup.
# It is a Mendix PAGE popup, not a message dialog, so tt654_dismiss_dialog (which
# hunts for OK/Close buttons in a message box) does not apply. Never press Escape
# here: on this app that closes the popup AND can drop the surrounding context.
tt654_close_connect_modal() {
  playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; if(!d) return 'none'; const b=[...d.querySelectorAll('.modal-header button, button.close')].filter(x=>x.offsetParent!==null); if(b.length){ b[0].click(); return 'closed'; } return 'nobutton'; }" >/dev/null 2>&1
  sleep 2
}
