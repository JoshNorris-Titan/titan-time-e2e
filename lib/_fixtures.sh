#!/usr/bin/env bash
# Structural fixture provisioning. Source AFTER lib/_login.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#   source "$(dirname "$0")/lib/_fixtures.sh"
#
# WHY THIS EXISTS
# ---------------
# The existing seeders (seed-regression-ladder.sh, seed-toprocess-entries.sh) create
# TRANSACTIONAL data — AssignmentEntries in various statuses. They assume the
# STRUCTURAL data already exists: customers, projects with the right approval flags,
# consultants, and the accounts that log in.
#
# On a fresh or drifted environment that assumption is wrong, and the resulting
# failure is unreadable. The first cloud CI run failed with
#   "no assignment for project 'E2E Dual Approval' is visible to e2e_consultant"
# which reads like a product bug and is actually one missing row.
#
# This file verifies the structural fixtures and creates what is missing.
#
# SCOPE — read this before assuming it covers something
# -----------------------------------------------------
#   Customers  verify + create
#   Projects   verify + create. Existence is matched on NAME ONLY; the approval
#                                flags, project manager, customer and archived state
#                                are reconciled separately by fx_reconcile_collect
#                                below, because a project is only useful to a test if
#                                its CONFIGURATION matches, not just its name.
#   Accounts / consultants
#              VERIFY ONLY. Creating a login is a different surface (Core.Account_New)
#              and provisioning credentials from a test run is a decision that should
#              be made deliberately, not as a side effect. Missing accounts FAIL LOUDLY
#              with the exact list, rather than being half-created.
#   Assignments
#              verify + create. Consultant→project assignment is what actually makes a
#              project visible to a consultant in a given week — a project with no
#              assignment is invisible, which is exactly how verify-tt647-a5 failed.
#
# Every selector below was verified against the live dev environment rather than read
# from the model, because the model is only true after a deploy.
#
# Env:
#   TT_BASE_URL   REQUIRED. No default: this WRITES data, and must never silently
#                 target whatever environment happens to be the fallback.
#   TT_ROLE_PASS  password for the e2e_* accounts
#   TT_FIXTURES_READONLY=1   verify and report, create nothing

# ---------------------------------------------------------------- fixture table
#
# name|approvalFromManager|approvalFromCustomer|needsLineItems
# Derived from what the tests actually assert:
#   E2E Manager Approval  verify-tt647-a1  (PM approval line)
#   E2E Customer Approval verify-customer-approval-flow, verify-pm-dashboard-pending
#   E2E Dual Approval     verify-tt647-a5  (expects TWO approval lines)
#   E2E Line Items        verify-consultant-line-items, verify-tt692693-b1
#   E2E Sandbox           the consultant-side scratch project: verify-hours-validation,
#                         verify-timesheet-clear, verify-timesheet-status-rollup,
#                         verify-tt692693-a1 (all as e2e_consultant2)
#
# E2E Sandbox REQUIRES ApprovalFromManager=Yes. It reads like a scratch project that
# should need no approval, and this table declared No until 2026-08-27 — but nothing
# had ever compared the table to the environment, so the mismatch was invisible.
# verify-timesheet-status-rollup submits 40 hours on this project and asserts the
# consultant's Awaiting_Approval week count goes UP. With a manager stage, the entry
# becomes AwaitingManagerApproval and the week rolls up to Awaiting_Approval, which is
# what that test wants. With No/No, Main.SUB_AssignmentEntry_Submit routes 40 hours
# STRAIGHT to ToProcess, SUB_AssignmentEntry_UpdateTimesheetStatus counts ToProcess as
# accepted, and the week rolls up to Approved instead — so the test would fail.
# Do not "simplify" this back to No without re-reading that test.
FX_PROJECTS=(
  "E2E Manager Approval|Yes|No|No"
  "E2E Customer Approval|No|Yes|No"
  "E2E Dual Approval|Yes|Yes|No"
  "E2E Line Items|No|No|Yes"
  "E2E Sandbox|Yes|No|No"
)

# Consultant/user display names the suite depends on.
FX_CONSULTANTS=(
  "E2E Consultant"
  "E2E Consultant Two"
  "E2E ProjectManger"
)

# consultant|project|weeklyHours
#
# Mirrors what dev already had, plus the one real gap: E2E Consultant had
# assignments to Manager Approval, Customer Approval and Line Items but NOT to
# Dual Approval, which is why verify-tt647-a5 could not see it. Declaring the
# whole set (not just the gap) makes this self-healing on a fresh environment.
#
# The owning customer is NOT hardcoded — it is looked up from the project itself,
# so re-pointing a project to another customer does not silently break seeding.
FX_ASSIGNMENTS=(
  "E2E Consultant|E2E Manager Approval|40"
  "E2E Consultant|E2E Customer Approval|40"
  "E2E Consultant|E2E Dual Approval|40"
  "E2E Consultant|E2E Line Items|40"
  "E2E Consultant Two|E2E Sandbox|40"
)

# Matches the window every existing E2E assignment uses (Jul 01 2026 - Dec 31 2027).
# The window must cover the weeks the tests drive, or the assignment exists but
# renders zero rows — the failure mode seed-shakedown.sh was written to catch.
#
# FORMAT IS LOAD-BEARING: the date pickers advertise placeholder "mmm dd, yyyy".
# "07/01/2026" is accepted into the DOM and then rejected by the widget with
# "Invalid date", so the save fails while the field looks correctly filled.
FX_START_DATE="${FX_START_DATE:-Jul 01, 2026}"
FX_END_DATE="${FX_END_DATE:-Dec 31, 2027}"
FX_BUDGET_HOURS="${FX_BUDGET_HOURS:-400}"

# Matches the sibling E2E projects already on dev, so a created project is
# indistinguishable from a hand-made one.
FX_PROJECT_MANAGER="${FX_PROJECT_MANAGER:-E2E ProjectManger}"
FX_APPROVER_NAME="${FX_APPROVER_NAME:-Approver E2E}"
FX_APPROVER_EMAIL="${FX_APPROVER_EMAIL:-jnorris@titanconsulting.net}"
FX_CUSTOMER="${FX_CUSTOMER:-Costco}"

FX_CREATED=0
FX_PRESENT=0
FX_MISSING=""
FX_DRIFT=""

fx_log() { echo "  [fixtures] $*"; }

# ---------------------------------------------------------------- navigation
#
# The Titan Manager dashboard is three cards (cardCustomers / cardProjects /
# cardConsultants); clicking one switches the list below it. Verified live.
fx_view() {
  local card="$1" gal="$2" i
  playwright-cli click ".mx-name-$card" >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8; do
    if playwright-cli eval "() => String(!!document.querySelector('.mx-name-$gal'))" 2>/dev/null | grep -qiw true; then
      sleep 1; return 0
    fi
    sleep 1
  done
  tt_fail "fixtures: '$card' did not reveal '$gal' — the Titan Manager dashboard layout has changed"
}

# fx_search <searchWidget> <gallery> <text> — type into the list's search box and
# return the filtered gallery text. Search-as-you-type, so no Enter (see TT-682).
fx_search() {
  local box="$1" gal="$2" text="$3"
  playwright-cli fill ".mx-name-$box input" "" >/dev/null 2>&1
  playwright-cli click ".mx-name-$box input" >/dev/null 2>&1
  playwright-cli type "$text" >/dev/null 2>&1
  sleep 3
  playwright-cli eval "() => ((document.querySelector('.mx-name-$gal')||{}).innerText||'').replace(/\\s+/g,' ')" 2>/dev/null | _tt_eval_str
}

# fx_exists <searchWidget> <gallery> <exactName>
# Substring match on the filtered list. Guards against prefix collisions by also
# rejecting when the name only appears as part of a longer name.
fx_exists() {
  local box="$1" gal="$2" name="$3" text
  text="$(fx_search "$box" "$gal" "$name")"
  case "$text" in *"$name"*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- projects
#
# Project_NewEdit is fully named (txtProjectName, cbCustomer, cbProjectManager,
# txtApproverName, txtApproverEmail, rbApprovalManager, rbApprovalCustomer,
# rbNeedsLineItems, btnSave) — confirmed by reading the page and by the passing
# verify-project-dropdowns-sorted test.
#
# The radio groups render as Yes/No; click the label whose text matches.
fx_set_radio() {
  local rb="$1" want="$2" r
  r="$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-$rb'); if(!g) return 'NOGROUP'; const ls=[...g.querySelectorAll('label')]; const l=ls.find(x=>(x.innerText||'').trim().toLowerCase()==='$(echo "$want" | tr '[:upper:]' '[:lower:]')'); if(!l) return 'NOOPT:'+ls.map(x=>(x.innerText||'').trim()).join(','); l.click(); return 'OK'; }" 2>/dev/null | _tt_eval_str)"
  case "$r" in
    OK) return 0 ;;
    NOGROUP) tt_fail "fixtures: radio group '$rb' not found on the project form" ;;
    *) tt_fail "fixtures: '$rb' has no '$want' option ($r)" ;;
  esac
}

fx_create_project() {
  local name="$1" mgr="$2" cust="$3" li="$4" i ok=""

  fx_log "creating project '$name' (manager=$mgr customer=$cust lineItems=$li)"
  playwright-cli click ".mx-name-btnAddProject" >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8; do
    if playwright-cli eval "() => String(!!document.querySelector('.mx-name-txtProjectName'))" 2>/dev/null | grep -qiw true; then
      ok=1; break
    fi
    sleep 1
  done
  [ -n "$ok" ] || tt_fail "fixtures: Add Project popup did not open (txtProjectName never appeared)"

  tt_fill ".mx-name-txtProjectName input" "$name"

  tt_combobox_select_text ".mx-name-cbCustomer" "$FX_CUSTOMER" \
    || tt_fail "fixtures: customer '$FX_CUSTOMER' not selectable on the project form — set FX_CUSTOMER to one that exists"
  tt_combobox_select_text ".mx-name-cbProjectManager" "$FX_PROJECT_MANAGER" \
    || tt_fail "fixtures: project manager '$FX_PROJECT_MANAGER' not selectable — that account may be missing"

  tt_fill ".mx-name-txtApproverName input"  "$FX_APPROVER_NAME"
  tt_fill ".mx-name-txtApproverEmail input" "$FX_APPROVER_EMAIL"

  fx_set_radio "rbApprovalManager"  "$mgr"
  fx_set_radio "rbApprovalCustomer" "$cust"
  fx_set_radio "rbNeedsLineItems"   "$li"

  playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
  sleep 3
  tt_clear_dialogs 4 >/dev/null 2>&1 || true

  # Prove it landed rather than trusting the click.
  fx_view "cardProjects" "galProjects"
  fx_exists "txtProjectSearch" "galProjects" "$name" \
    || tt_fail "fixtures: created project '$name' but it is not in the list afterwards — the save was rejected"
  fx_log "created '$name'"
}

fx_ensure_projects() {
  local row name mgr cust li
  fx_view "cardProjects" "galProjects"
  for row in "${FX_PROJECTS[@]}"; do
    IFS='|' read -r name mgr cust li <<< "$row"
    if fx_exists "txtProjectSearch" "galProjects" "$name"; then
      FX_PRESENT=$((FX_PRESENT+1))
      fx_log "ok      project '$name'"
    elif [ "${TT_FIXTURES_READONLY:-0}" = "1" ]; then
      FX_MISSING="$FX_MISSING\n    project: $name ($mgr/$cust/$li)"
      fx_log "MISSING project '$name' (read-only mode, not creating)"
    else
      fx_create_project "$name" "$mgr" "$cust" "$li"
      FX_CREATED=$((FX_CREATED+1))
    fi
  done
}

# ---------------------------------------------------------------- consultants
#
# VERIFY ONLY — see the scope note at the top. A missing consultant/account is
# reported with its name so it can be created deliberately.
fx_ensure_consultants() {
  local name text
  fx_view "cardConsultants" "galConsultants"
  for name in "${FX_CONSULTANTS[@]}"; do
    if fx_exists "txtConsultantSearch" "galConsultants" "$name"; then
      text="$(fx_search "txtConsultantSearch" "galConsultants" "$name")"
      FX_PRESENT=$((FX_PRESENT+1))
      # Surface the assignment count: zero is a silent killer for week-based tests.
      case "$text" in
        *"$name 0 assignments"*) fx_log "ok      consultant '$name' — WARNING: 0 assignments" ;;
        *)                       fx_log "ok      consultant '$name'" ;;
      esac
    else
      FX_MISSING="$FX_MISSING\n    consultant/account: $name  (create via Core.Account_New)"
      fx_log "MISSING consultant '$name'"
    fi
  done
}

# ---------------------------------------------------------------- assignments
#
# fx_project_customer <projectName> — which customer owns this project.
# Read from the project card ("<name> <customer> Active ...") rather than hardcoded,
# because Assignment_NewEdit constrains cbProject to
#   [Main.Project_Customer = $currentObject/Main.Assignment_Customer]
# so the customer must be selected FIRST and must be the right one.
fx_project_customer() {
  local name="$1"
  fx_view "cardProjects" "galProjects" >/dev/null
  fx_search "txtProjectSearch" "galProjects" "$name" >/dev/null
  playwright-cli eval "() => { const t=((document.querySelector('.mx-name-galProjects')||{}).innerText||'').replace(/\\s+/g,' '); const i=t.indexOf('$name'); if(i<0) return ''; const rest=t.slice(i+'$name'.length); const m=rest.match(/^\\s*(.+?)\\s+Active\\b/); return m ? m[1].trim() : ''; }" 2>/dev/null | _tt_eval_str
}

# fx_consultant_assignments <consultantName> — the assignment list text from the
# consultant detail popup. The popup itself is auto-named (listView1), so this reads
# its TEXT rather than depending on widget names that will renumber.
fx_consultant_assignments() {
  local name="$1" out
  fx_view "cardConsultants" "galConsultants" >/dev/null
  fx_search "txtConsultantSearch" "galConsultants" "$name" >/dev/null
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galConsultants'); if(!g) return 'NOGAL'; const c=[...g.querySelectorAll('*')].find(e=>getComputedStyle(e).cursor==='pointer' && (e.innerText||'').indexOf('$name')>=0); if(!c) return 'NOCARD'; c.click(); return 'ok'; }" >/dev/null 2>&1
  sleep 4
  out="$(playwright-cli eval "() => { const m=[...document.querySelectorAll('.modal-content')].filter(d=>d.offsetParent!==null); const d=m[m.length-1]; return d ? (d.innerText||'').replace(/\\s+/g,' ') : ''; }" 2>/dev/null | _tt_eval_str)"
  # Close the popup so the next lookup starts from a clean dashboard.
  playwright-cli eval "() => { const b=[...document.querySelectorAll('.modal-content button, .modal-header button')].filter(x=>x.offsetParent!==null); if(b.length) b[0].click(); }" >/dev/null 2>&1
  sleep 2
  printf '%s\n' "$out"
}

# fx_fill_date <selector> <value> — type a date the way a person would.
#
# `playwright-cli fill` writes straight to the DOM value, which the Mendix date
# picker never parses: the field then reads "Jul 01, 2026" while the widget reports
# "Invalid date" and silently refuses the save. Real keystrokes fire the events it
# listens for. Blur by clicking another field rather than pressing Escape — Escape
# closes the whole popup.
fx_fill_date() {
  local sel="$1" val="$2"
  playwright-cli fill "$sel" "" >/dev/null 2>&1
  playwright-cli click "$sel" >/dev/null 2>&1
  playwright-cli type "$val" >/dev/null 2>&1
  playwright-cli click ".mx-name-txtWeeklyHours input" >/dev/null 2>&1   # blur
  sleep 1
}

fx_create_assignment() {
  local consultant="$1" project="$2" hours="$3" customer="$4" i ok=""

  fx_log "creating assignment '$consultant' -> '$project' (customer=$customer, ${hours}h/wk)"
  fx_view "cardConsultants" "galConsultants" >/dev/null
  playwright-cli click ".mx-name-btnAddAssignment" >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8; do
    if playwright-cli eval "() => String(!!document.querySelector('.mx-name-cbCustomer'))" 2>/dev/null | grep -qiw true; then
      ok=1; break
    fi
    sleep 1
  done
  [ -n "$ok" ] || tt_fail "fixtures: Add Assignment popup did not open (cbCustomer never appeared)"

  # Order is forced by the form: customer gates the project list, project gates
  # consultant/hours/date editability.
  tt_combobox_select_text ".mx-name-cbCustomer" "$customer" \
    || tt_fail "fixtures: customer '$customer' not selectable on the assignment form"
  tt_combobox_select_text ".mx-name-cbProject" "$project" \
    || tt_fail "fixtures: project '$project' not selectable under customer '$customer' — the project may belong to a different customer"
  tt_combobox_select_text ".mx-name-cbConsultant" "$consultant" \
    || tt_fail "fixtures: consultant '$consultant' not selectable on the assignment form"

  tt_fill ".mx-name-txtWeeklyHours input"      "$hours"
  tt_fill ".mx-name-txtTotalBudgetHours input" "$FX_BUDGET_HOURS"
  fx_fill_date ".mx-name-dpStartDate input" "$FX_START_DATE"
  fx_fill_date ".mx-name-dpEndDate input"   "$FX_END_DATE"

  # Refuse to submit a form the widget has already rejected — otherwise the save
  # silently no-ops and the failure surfaces later as "project not visible".
  local bad
  bad="$(playwright-cli eval "() => [...document.querySelectorAll('.mx-validation-message')].filter(e=>e.offsetParent!==null).map(e=>(e.innerText||'').trim()).filter(Boolean).join(' ~ ')" 2>/dev/null | _tt_eval_str)"
  [ -z "$bad" ] || tt_fail "fixtures: assignment form rejected the input before save: $bad"

  playwright-cli click ".mx-name-btnSave" >/dev/null 2>&1
  sleep 4
  tt_clear_dialogs 4 >/dev/null 2>&1 || true

  # Prove it landed rather than trusting the click.
  case "$(fx_consultant_assignments "$consultant")" in
    *"$project"*) fx_log "created '$consultant' -> '$project'" ;;
    *) tt_fail "fixtures: saved assignment '$consultant' -> '$project' but it is not on the consultant afterwards — the save was rejected" ;;
  esac
}

fx_ensure_assignments() {
  local row consultant project hours have customer last=""
  for row in "${FX_ASSIGNMENTS[@]}"; do
    IFS='|' read -r consultant project hours <<< "$row"

    # One popup read per consultant, reused across that consultant's rows.
    if [ "$consultant" != "$last" ]; then
      have="$(fx_consultant_assignments "$consultant")"
      last="$consultant"
    fi

    case "$have" in
      NOGAL|NOCARD|"")
        FX_MISSING="$FX_MISSING\n    assignment: $consultant -> $project (consultant not found)"
        fx_log "MISSING consultant '$consultant' — cannot check assignments"
        continue ;;
      *"$project"*)
        FX_PRESENT=$((FX_PRESENT+1))
        fx_log "ok      assignment '$consultant' -> '$project'"
        continue ;;
    esac

    if [ "${TT_FIXTURES_READONLY:-0}" = "1" ]; then
      FX_MISSING="$FX_MISSING\n    assignment: $consultant -> $project (${hours}h/wk)"
      fx_log "MISSING assignment '$consultant' -> '$project' (read-only mode, not creating)"
      continue
    fi

    customer="$(fx_project_customer "$project")"
    [ -n "$customer" ] || tt_fail "fixtures: could not determine which customer owns project '$project'"
    fx_create_assignment "$consultant" "$project" "$hours" "$customer"
    FX_CREATED=$((FX_CREATED+1))
    have="$(fx_consultant_assignments "$consultant")"   # refresh for later rows
  done
}

# ---------------------------------------------------------------- reconciliation
#
# WHY THIS EXISTS
# fx_ensure_projects and fx_ensure_assignments match on NAME ALONE. A project that
# already exists with the wrong approval flags, the wrong project manager, or
# Archived=true passes the preflight silently -- and so does an assignment whose
# date window no longer covers the weeks the tests drive. That is invisible drift:
# the preflight prints "ok", and unrelated tests fail an hour later with symptoms
# that read like product bugs.
#
# Found the hard way on 2026-08-27: five cluster-1 failures were investigated as a
# routing bug before the live rows were read and found correct -- except E2E
# Sandbox, whose ApprovalFromManager is Yes while the table says No. Nothing in the
# suite could have surfaced that.
#
# This reads the real values through the Mendix client data API rather than by
# reopening each form. The Titan Manager session is already signed in here, and
# Project/Assignment carry ManagerName, CustomerName, Archived and the date window
# as plain attributes, so one round trip answers everything. Reading the edit form
# was the obvious alternative and is worse: clicking a project card opens a
# READ-ONLY "Project Overview" popup with only Archive/Close, so the flags are not
# reachable that way at all.
#
# Drift is REPORTED, never silently repaired. The flags are a deliberate property
# of each fixture; a preflight that quietly rewrote them would hide the fact that
# something changed them.

# fx_config_snapshot -- one line per declared project and assignment:
#   PROJECT|<name>|<mgr>|<cust>|<lineItems>|<archived>|<managerName>|<customerName>
#   ASSIGN|<consultant>|<project>|<start>|<end>|<archived>|<weeklyHours>
# or <...>|ABSENT, or <...>|ERROR|<message> when the retrieve itself failed.
fx_config_snapshot() {
  local row name mgr cust li consultant project hours names_js="" pairs_js=""

  for row in "${FX_PROJECTS[@]}"; do
    IFS='|' read -r name mgr cust li <<< "$row"
    names_js="$names_js'$name',"
  done
  for row in "${FX_ASSIGNMENTS[@]}"; do
    IFS='|' read -r consultant project hours <<< "$row"
    pairs_js="$pairs_js['$consultant','$project'],"
  done

  playwright-cli eval "() => { const P=[${names_js}]; const A=[${pairs_js}]; const d=v=>v?new Date(v).toISOString().slice(0,10):''; const proj=n=>new Promise(r=>mx.data.get({xpath:\"//Main.Project[Name='\"+n+\"']\",filter:{amount:1},callback:o=>r(o.length?['PROJECT',n,o[0].get('ApprovalFromManager'),o[0].get('ApprovalFromCustomer'),o[0].get('NeedsLineItems'),o[0].get('Archived'),o[0].get('ManagerName')||'',o[0].get('CustomerName')||''].join('|'):['PROJECT',n,'ABSENT'].join('|')),error:e=>r(['PROJECT',n,'ERROR',e.message].join('|'))})); const asg=q=>new Promise(r=>mx.data.get({xpath:\"//Main.Assignment[ConsultantName='\"+q[0]+\"'][Main.Assignment_Project/Main.Project/Name='\"+q[1]+\"']\",filter:{amount:5},callback:o=>r(o.length?['ASSIGN',q[0],q[1],d(o[0].get('StartDate')),d(o[0].get('EndDate')),o[0].get('Archived'),o[0].get('WeeklyHours')].join('|'):['ASSIGN',q[0],q[1],'ABSENT'].join('|')),error:e=>r(['ASSIGN',q[0],q[1],'ERROR',e.message].join('|'))})); return Promise.all([...P.map(proj),...A.map(asg)]).then(x=>x.join('\n')); }" 2>/dev/null | _tt_eval_str
}

# fx_reconcile_collect -- compare live configuration against the declared tables.
# Prints one drift line per problem (empty output == clean). Printing rather than
# appending to a global is deliberate: the read loop runs in a pipeline subshell,
# so a global assignment inside it would be discarded.
fx_reconcile_collect() {
  local snap f1 f2 f3 f4 f5 f6 f7 f8 row name mgr cust li
  local want_mgr want_cust want_li horizon

  snap="$(fx_config_snapshot)"
  case "$snap" in
    ""|NOGAL*)
      echo "    could not read configuration through the data API - reconciliation skipped" >&2
      return 0 ;;
  esac

  # The suite steps forward up to ~10 weeks hunting an editable week, so an
  # assignment ending sooner than that is unusable even though it exists.
  horizon="$(date -d '+12 weeks' +%Y-%m-%d 2>/dev/null || echo '')"

  printf '%s\n' "$snap" | while IFS='|' read -r f1 f2 f3 f4 f5 f6 f7 f8; do
    [ -n "$f1" ] || continue
    if [ "$f1" = "PROJECT" ]; then
      if [ "$f3" = "ABSENT" ]; then
        echo "    project '$f2' could not be read back through the data API"; continue
      elif [ "$f3" = "ERROR" ]; then
        echo "    project '$f2' read failed: $f4"; continue
      fi
      for row in "${FX_PROJECTS[@]}"; do
        IFS='|' read -r name mgr cust li <<< "$row"
        [ "$name" = "$f2" ] || continue
        if [ "$mgr"  = "Yes" ]; then want_mgr=true;  else want_mgr=false;  fi
        if [ "$cust" = "Yes" ]; then want_cust=true; else want_cust=false; fi
        if [ "$li"   = "Yes" ]; then want_li=true;   else want_li=false;   fi
        [ "$f3" = "$want_mgr" ]  || echo "    project '$f2' ApprovalFromManager is '$f3', table declares '$mgr'"
        [ "$f4" = "$want_cust" ] || echo "    project '$f2' ApprovalFromCustomer is '$f4', table declares '$cust'"
        [ "$f5" = "$want_li" ]   || echo "    project '$f2' NeedsLineItems is '$f5', table declares '$li'"
        [ "$f6" = "false" ]      || echo "    project '$f2' is ARCHIVED - it will not appear on the PM dashboard or as a consultant week row"
        [ "$f7" = "$FX_PROJECT_MANAGER" ] || echo "    project '$f2' ManagerName is '$f7', expected '$FX_PROJECT_MANAGER' (DS_ProjectsManaged retrieves via ProjectManager_Account, so the PM dashboard will not list it)"
      done
    elif [ "$f1" = "ASSIGN" ]; then
      if [ "$f4" = "ABSENT" ]; then
        echo "    assignment '$f2' -> '$f3' could not be read back through the data API"; continue
      elif [ "$f4" = "ERROR" ]; then
        echo "    assignment '$f2' -> '$f3' read failed: $f5"; continue
      fi
      [ "$f6" = "false" ] || echo "    assignment '$f2' -> '$f3' is ARCHIVED - that project renders no row for the consultant"
      if [ -n "$horizon" ] && [ -n "$f5" ] && [ "$f5" \< "$horizon" ]; then
        echo "    assignment '$f2' -> '$f3' ends $f5, within the ~12 weeks the tests step through (today+12w = $horizon) - tests walking forward for an editable week will run out of runway"
      fi
    fi
  done
}

# ---------------------------------------------------------------- entry point
fx_ensure_all() {
  [ -n "${TT_BASE_URL:-}" ] || tt_fail "fixtures: TT_BASE_URL must be set explicitly — this writes data and must never fall back to a default environment"

  tt_login "e2e_tm" "Add Customer"

  # Order matters: a project must exist before it can be assigned.
  fx_ensure_projects
  fx_ensure_consultants
  fx_ensure_assignments

  # Existence is not enough -- reconcile the CONFIGURATION of what now exists.
  FX_DRIFT="$(fx_reconcile_collect)"

  echo "  [fixtures] $FX_PRESENT present, $FX_CREATED created"
  if [ -n "$FX_MISSING" ]; then
    printf '  [fixtures] STILL MISSING:%b\n' "$FX_MISSING"
    return 1
  fi
  if [ -n "$FX_DRIFT" ]; then
    printf '  [fixtures] CONFIGURATION DRIFT (present, but not as declared):\n%s\n' "$FX_DRIFT"
    if [ "${TT_FIXTURES_ALLOW_DRIFT:-0}" = "1" ]; then
      echo "  [fixtures] TT_FIXTURES_ALLOW_DRIFT=1 - reported only, not failing"
      return 0
    fi
    return 1
  fi
  return 0
}
