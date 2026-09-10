#!/usr/bin/env bash
# Manual review environment — the single source of truth for the "Manual *" data set.
#
# WHAT THIS IS FOR
# ----------------
# The e2e suite owns the `E2E *` accounts, projects, assignments and timesheets, and
# both of its bookends DELETE them: a finished nightly leaves the environment with no
# E2E structure at all (see suites/99-teardown and lib/_testdata.sh). That makes the
# e2e data useless to a human who wants to open dev and look at something — by the time
# they log in, the run that built it has already thrown it away.
#
# This directory provisions a PARALLEL, human-owned copy of the same shape, prefixed
# `Manual ` instead of `E2E `, for Rishika's dev review. Nothing in suites/ touches it,
# nothing here touches the E2E data, and the two sets never share a project or an
# assignment — which is what keeps the two deep clears from reaching into each other.
#
# HOW THE TWO SETS STAY APART, precisely
# --------------------------------------
# The clear is driven per consultant (TT_E2E_CONSULTANTS) and, at depth=deep, deletes
# that consultant's assignments AND the projects those assignments were on. So the
# isolation rule is exactly one sentence:
#
#     A Manual consultant must never be assigned to an E2E project, and an E2E
#     consultant must never be assigned to a Manual project.
#
# Keep MANUAL_ASSIGNMENTS below pointing only at MANUAL_PROJECTS and that holds. If it
# is ever broken, the nightly e2e teardown will silently delete a Manual project (and
# vice versa), and the symptom will be a Manual environment that empties itself
# overnight for no visible reason.
#
# The CUSTOMER is deliberately shared with the E2E set (Costco by default). Customers
# are never deleted by either clear, so sharing one is safe, and Assignment_NewEdit
# constrains the project list by customer — using the customer the environment already
# has avoids inventing structure nobody asked for.
#
# HOW TO SOURCE IT
#   source "$TT_ROOT/lib/_login.sh"
#   source "$TT_ROOT/lib/_fixtures.sh"          # only if you need the fixture builders
#   source "$TT_ROOT/manual-env/manual.env.sh"
#   manual_apply_fixture_overrides              # only after _fixtures.sh is sourced
#
# Env:
#   TT_BASE_URL          REQUIRED by every caller — this whole directory WRITES data.
#   TT_MANUAL_PASS       password for the manual_* accounts. Defaults to TT_ROLE_PASS,
#                        i.e. the same password the e2e_* accounts use. Set it only if
#                        the Manual accounts were given a different one.
#   MANUAL_CUSTOMER      owning customer for the Manual projects (default Costco)
#   MANUAL_APPROVER_EMAIL  where customer-approval mail for Manual projects goes

# ---------------------------------------------------------------- accounts
#
# username|FullName|userRole|employmentStatus|landing text after login
#
# The role and employment-status columns are the literal option texts on
# Core.Account_New, read off dev on 2026-09-09 — the role picker offers exactly
# Administrator / Anonymous / Consultant / HR / ProjectManager / TitanManager, and
# employment status offers FullTime / Contract. Each Manual account carries ONE role,
# and every e2e_* account was verified to be FullTime, so these mirror them exactly.
#
# EMPLOYMENT STATUS IS NOT COSMETIC. Full-time consultants are warned when they log
# under 40 hours in a week; contract staff never get that warning (the hint text on the
# form says so). Mirroring FullTime is what makes a Manual week behave like an E2E one.
#
# The landing text is what tt_login waits for, so it is also the cheapest proof that an
# account came out with the right role: an account created as a plain Consultant by
# mistake authenticates perfectly and never renders "WEEKLY TO PROCESS", and
# verify-100-manual-accounts names it instead of failing later as a confusing seeding
# error.
#
# These are provisioned ONCE by manual-env/provision-accounts.sh and are never created
# or deleted by either workflow. Both are built on the promise that the accounts OUTLIVE
# them — the teardown deletes data and structure and leaves every account standing.
MANUAL_ACCOUNTS=(
  "manual_consultant|Manual Consultant|Consultant|FullTime|My Timesheets"
  "manual_consultant2|Manual Consultant Two|Consultant|FullTime|My Timesheets"
  "manual_consultant3|Manual Consultant Three|Consultant|FullTime|My Timesheets"
  "manual_pm|Manual ProjectManager|ProjectManager|FullTime|Project Manager Dashboard"
  "manual_pm2|Manual ProjectManager Two|ProjectManager|FullTime|Project Manager Dashboard"
  "manual_hr|Manual HR|HR|FullTime|WEEKLY TO PROCESS"
  "manual_tm|Manual TitanManager|TitanManager|FullTime|Add Customer"
)

# manual_account_email <username> — the address the account is created with.
#
# ONE UNIQUE PLUS-ADDRESS PER ACCOUNT, which is deliberately different from the e2e set:
# all seven e2e_* accounts share jnorris+tt@titanconsulting.net. That is fine for them
# and wrong here, because provisioning has to read each new account's TEMPORARY PASSWORD
# out of the Emails Sent page, and one shared recipient makes the rows indistinguishable
# by address. (The welcome mail also names the username in its body, so pairing is
# double-checked — but a filterable recipient is what keeps that lookup cheap.)
#
# Everything still lands in Josh's mailbox; the plus-suffix is routing, not a new inbox.
MANUAL_ACCOUNT_EMAIL_TEMPLATE="${MANUAL_ACCOUNT_EMAIL_TEMPLATE:-jnorris+%s@titanconsulting.net}"
manual_account_email() {
  # shellcheck disable=SC2059  # the template is a format string on purpose
  printf "$MANUAL_ACCOUNT_EMAIL_TEMPLATE" "$1"
}

# ---------------------------------------------------------------- projects
#
# name|approvalFromManager|approvalFromCustomer|needsLineItems
#
# A one-for-one mirror of FX_PROJECTS in lib/_fixtures.sh, so a reviewer sees every
# approval shape the product supports:
#
#   Manual Manager Approval   PM approves, customer does not
#   Manual Customer Approval  customer approves, PM does not
#   Manual Dual Approval      both — two approval lines on the entry
#   Manual Line Items         no approval, line-item tasks required
#   Manual Sandbox            manager approval; the scratch project for consultant 2
#
# Manual Sandbox keeps ApprovalFromManager=Yes for the reason spelled out above
# FX_PROJECTS: with No/No a submitted week routes straight to ToProcess and rolls up as
# Approved, so the week never appears on the Manager Approval tab at all. Mirroring the
# E2E table exactly is the whole point — a Manual set that behaves differently is worse
# than no Manual set, because a reviewer would report the difference as a bug.
MANUAL_PROJECTS=(
  "Manual Manager Approval|Yes|No|No"
  "Manual Customer Approval|No|Yes|No"
  "Manual Dual Approval|Yes|Yes|No"
  "Manual Line Items|No|No|Yes"
  "Manual Sandbox|Yes|No|No"
)

# Display names that must exist as accounts before structure can be built. The same
# consultants as MANUAL_ACCOUNTS, plus the project manager — a project cannot be saved
# without picking one, so a missing PM has to surface at the preflight rather than as a
# combobox that quietly offers nothing.
MANUAL_CONSULTANTS=(
  "Manual Consultant"
  "Manual Consultant Two"
  "Manual Consultant Three"
  "Manual ProjectManager"
)

# consultant|project|weeklyHours
#
# Mirrors FX_ASSIGNMENTS with ONE DELIBERATE DIFFERENCE: 'Manual Consultant Three' has an
# assignment here, where 'E2E Consultant Three' has none.
#
# In the e2e set that third consultant exists only so the clear has a row to name — no
# test drives them — and a consultant with no assignment renders zero rows in every week,
# so the timesheet seeder finds nothing to fill and says so. That is fine for a suite and
# wrong for a review environment: it would leave Rishika with two consultants carrying
# data and a third that looks broken. Josh's call, 2026-09-09.
#
# Manual Manager Approval is shared with Manual Consultant, which is realistic (two people
# on one project) and costs nothing: every Manual project is deleted by the teardown
# anyway, because every Manual consultant is assigned only to Manual projects.
MANUAL_ASSIGNMENTS=(
  "Manual Consultant|Manual Manager Approval|40"
  "Manual Consultant|Manual Customer Approval|40"
  "Manual Consultant|Manual Dual Approval|40"
  "Manual Consultant|Manual Line Items|40"
  "Manual Consultant Two|Manual Sandbox|40"
  "Manual Consultant Three|Manual Manager Approval|40"
)

# consultantName|loginUser|project|weeksBack — the transactional control rows, mirroring
# FX_ENTRIES. The timesheet seeder produces far more than this; the table is kept in
# step with the e2e one so that manual_apply_fixture_overrides leaves NO FX_* array
# still pointing at E2E data. That property is what makes the override safe to reason
# about: after it runs, nothing in lib/_fixtures.sh can reach the E2E set.
MANUAL_ENTRIES=(
  "Manual Consultant Two|manual_consultant2|Manual Sandbox|3"
)

# ---------------------------------------------------------------- knobs
#
# The date window is NOT redeclared here: FX_START_DATE / FX_END_DATE already honour the
# environment and are tuned for the weeks anything walks to, and their MM/dd/yyyy shape
# is load-bearing (see the note above FX_START_DATE in lib/_fixtures.sh). Sharing them
# with the E2E set is deliberate.
MANUAL_CUSTOMER="${MANUAL_CUSTOMER:-Costco}"
MANUAL_PROJECT_MANAGER="${MANUAL_PROJECT_MANAGER:-Manual ProjectManager}"
MANUAL_APPROVER_NAME="${MANUAL_APPROVER_NAME:-Approver Manual}"
# Customer-approval mail for these projects lands here. Defaulted to a plus-address on
# Josh's mailbox rather than guessed at a reviewer's address — override it if the mail
# should go somewhere else.
MANUAL_APPROVER_EMAIL="${MANUAL_APPROVER_EMAIL:-jnorris+ttmanual@titanconsulting.net}"

# The name prefix the teardown's leftover check scans for. Everything this directory
# creates starts with it, which is what makes "did the clear actually take the structure
# with it?" answerable in one XPath instead of five name comparisons.
MANUAL_PREFIX="${MANUAL_PREFIX:-Manual }"

# The manual_* accounts share TT_ROLE_PASS with the e2e_* ones unless told otherwise.
# Assigning TT_PASS (rather than passing a password to every tt_login) is what makes the
# shared helpers in lib/ — which log in with their own defaults, several frames down —
# use the right credentials; exporting TT_ROLE_PASS carries it into the timesheet
# seeder, which runs as a separate process.
if [ -n "${TT_MANUAL_PASS:-}" ]; then
  TT_PASS="$TT_MANUAL_PASS"
  TT_ROLE_PASS="$TT_MANUAL_PASS"
  export TT_ROLE_PASS
fi

manual_log() { echo "  [manual] $*"; }

# manual_users <field> — one column of MANUAL_ACCOUNTS, pipe-joined.
#   1 username   2 full name   3 user role   4 employment status   5 landing text
manual_users() {
  local row out="" f
  for row in "${MANUAL_ACCOUNTS[@]}"; do
    f="$(printf '%s' "$row" | cut -d'|' -f"$1")"
    out="${out:+$out|}$f"
  done
  printf '%s' "$out"
}

# manual_consultant_names — the FullNames the clear is allowed to reset, pipe-joined.
# Handed to TT_E2E_CONSULTANTS by the teardown, and derived from MANUAL_CONSULTANTS
# rather than retyped so the two can never drift apart.
#
# The project manager is EXCLUDED: Core.DS_TestData_Consultants only lists accounts in
# the Consultant role, and tt_clear_consultant_testdata fails when it cannot find a
# consultant's row — so naming a PM here would abort the teardown looking for a control
# that cannot exist.
manual_consultant_names() {
  local n out=""
  for n in "${MANUAL_CONSULTANTS[@]}"; do
    case "$n" in *ProjectManager*) continue ;; esac
    out="${out:+$out|}$n"
  done
  printf '%s' "$out"
}

# manual_apply_fixture_overrides — point lib/_fixtures.sh at the Manual data set.
#
# Call it AFTER sourcing lib/_fixtures.sh, never before: that file assigns the FX_*
# arrays unconditionally at source time, so an override written first would simply be
# overwritten by the E2E table and the run would build E2E structure while claiming to
# build Manual structure. Nothing downstream would report that — every name it printed
# would be an E2E one, and on a shared environment those names look entirely plausible.
#
# FX_TM_USER / FX_PROJECT_MANAGER / FX_CUSTOMER / the approver fields are ordinary
# variables in _fixtures.sh with environment defaults, so assigning them here is enough;
# the builders read them at call time.
manual_apply_fixture_overrides() {
  # Fail loudly rather than silently building the E2E set if the source order is wrong.
  declare -p FX_PROJECTS >/dev/null 2>&1 \
    || tt_fail "manual_apply_fixture_overrides was called before lib/_fixtures.sh was sourced — the FX_* tables do not exist yet, so there is nothing to override"

  FX_PROJECTS=("${MANUAL_PROJECTS[@]}")
  FX_CONSULTANTS=("${MANUAL_CONSULTANTS[@]}")
  FX_ASSIGNMENTS=("${MANUAL_ASSIGNMENTS[@]}")
  FX_ENTRIES=("${MANUAL_ENTRIES[@]}")

  FX_TM_USER="manual_tm"
  FX_PROJECT_MANAGER="$MANUAL_PROJECT_MANAGER"
  FX_APPROVER_NAME="$MANUAL_APPROVER_NAME"
  FX_APPROVER_EMAIL="$MANUAL_APPROVER_EMAIL"
  FX_CUSTOMER="$MANUAL_CUSTOMER"
}

# ---------------------------------------------------------------- data API reads
#
# All three read through the Mendix client data API in the CURRENT session, the same way
# fx_entry_count and fx_config_snapshot do. They decode with _tt_eval_str rather than
# grepping raw output — playwright-cli echoes the JS source back on stdout, so a grep
# matches the question rather than the answer (the echo trap, see CLAUDE.md).
#
# Each returns ERR:<reason> rather than an empty string when the retrieve itself fails,
# so a caller can tell "none found" from "could not ask". Those two must never be
# conflated here: the teardown treats "none found" as success.

# manual_xpath_count <xpath> — how many objects the current session can retrieve.
manual_xpath_count() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"$1\", filter:{amount:1000}, callback: function(objs){ clearTimeout(t); res(String((objs||[]).length)); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# manual_names_matching <entity> <attribute> — the VALUES, joined by " | ", of every
# object whose <attribute> starts with MANUAL_PREFIX. Empty means none.
#
# Used by the teardown to NAME what survived rather than only counting it: "3 projects
# left" sends the reader hunting, "Manual Dual Approval | Manual Sandbox" does not.
manual_names_matching() {
  local ent="$1" attr="$2"
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//$ent[starts-with($attr,'$MANUAL_PREFIX')]\", filter:{amount:500}, callback: function(objs){ clearTimeout(t); res((objs||[]).map(function(o){ return o.get('$attr'); }).sort().join(' | ')); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# manual_status_spread <consultant full name> — "Draft:10 Exported:5 …" across that
# consultant's AssignmentEntries, or ERR:<reason>. Empty means no entries at all.
#
# The point of the ladder seeder is the SPREAD, not the row count: a seeding run that
# submitted every week and then failed to apply any HR stage produces plenty of rows in
# one status, and is not the environment anybody asked for. Counting by status is what
# makes that visible, and it is what verify-120 asserts on.
manual_status_spread() {
  local xp="//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$1']"
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"$xp\", filter:{amount:1000}, callback: function(objs){ clearTimeout(t); const c={}; (objs||[]).forEach(function(o){ const s=o.get('Status')||'(none)'; c[s]=(c[s]||0)+1; }); res(Object.keys(c).sort().map(function(k){ return k+':'+c[k]; }).join(' ')); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}
