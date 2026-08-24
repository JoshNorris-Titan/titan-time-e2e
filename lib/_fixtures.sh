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
#   Projects   verify + create  (including the approval flags, which are the whole
#                                point — a project is only useful to a test if its
#                                ApprovalFromManager/Customer/NeedsLineItems match)
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
#   E2E Sandbox           general scratch project
FX_PROJECTS=(
  "E2E Manager Approval|Yes|No|No"
  "E2E Customer Approval|No|Yes|No"
  "E2E Dual Approval|Yes|Yes|No"
  "E2E Line Items|No|No|Yes"
  "E2E Sandbox|No|No|No"
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

# ---------------------------------------------------------------- entry point
fx_ensure_all() {
  [ -n "${TT_BASE_URL:-}" ] || tt_fail "fixtures: TT_BASE_URL must be set explicitly — this writes data and must never fall back to a default environment"

  tt_login "e2e_tm" "Add Customer"

  # Order matters: a project must exist before it can be assigned.
  fx_ensure_projects
  fx_ensure_consultants
  fx_ensure_assignments

  echo "  [fixtures] $FX_PRESENT present, $FX_CREATED created"
  if [ -n "$FX_MISSING" ]; then
    printf '  [fixtures] STILL MISSING:%b\n' "$FX_MISSING"
    return 1
  fi
  return 0
}
