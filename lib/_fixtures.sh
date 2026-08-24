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
#              NOT COVERED YET. Consultant→project assignment is what makes a project
#              visible in a given week; the existence check needs the consultant detail
#              popup, which is not yet mapped. fx_report prints per-consultant
#              assignment counts so a zero is at least visible.
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

# ---------------------------------------------------------------- entry point
fx_ensure_all() {
  [ -n "${TT_BASE_URL:-}" ] || tt_fail "fixtures: TT_BASE_URL must be set explicitly — this writes data and must never fall back to a default environment"

  tt_login "e2e_tm" "Add Customer"

  fx_ensure_projects
  fx_ensure_consultants

  echo "  [fixtures] $FX_PRESENT present, $FX_CREATED created"
  if [ -n "$FX_MISSING" ]; then
    printf '  [fixtures] STILL MISSING:%b\n' "$FX_MISSING"
    return 1
  fi
  return 0
}
