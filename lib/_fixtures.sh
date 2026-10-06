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
#   Entries    verify + create, but NOT from fx_ensure_all — see fx_ensure_entries
#              near the bottom of this file. It needs a CONSULTANT session and a
#              materialised week, while everything else here runs as the Titan
#              Manager, so it is called from its own step
#              (suites/00-setup/verify-002-seed-isolation-control.test.sh).
#
# EVERYTHING IN THIS FILE NOW RUNS AFTER THE CLEAR. Before 2026-09-06 the clear
# preserved projects and assignments, so the structural half deliberately ran
# ahead of it. The bookends now drive the deep per-consultant control, which
# deletes assignments and their projects too, so nothing survives it and this
# file's caller (verify-001-fixtures) was renamed to sort behind
# verify-000-testdata-clear-before. Creating the projects fresh every run is the
# upside: the FX_PROJECTS table below becomes the only source of their approval
# flags, and a rebuilt project cannot drift the way E2E Sandbox did.
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
#
# FIELDS: name|approvalFromManager|approvalFromCustomer|needsLineItems[|approverEmail]
#
# The fifth field is OPTIONAL and every row below omits it, so each project gets
# FX_APPROVER_EMAIL as it always has. It is there because that shared address has a
# cost the suite pays every run: the approval token is minted PER APPROVER EMAIL
# and the remind gate keys on it, so (lib/_login_core.sh) "the FIRST spec in a run
# to press Remind gates every already-pending client entry for the rest of the run,
# across all projects" - which then surfaces as "reminder email not received" in
# whichever spec ran second.
#
# 'E2E Dual Approval' carries its own address for exactly that reason. Only it and
# 'E2E Customer Approval' mint customer tokens, so splitting the two is what makes
# an approver scope smaller than "everything". Dual Approval was chosen over
# Customer Approval because it is named by five specs rather than ten, and because
# of what verify-customer-token-approve already had to do about the shared address:
# it carries a defensive "confirm the project before the irreversible click" step,
# written because one token listed BOTH projects' rows for the same consultant and
# week, so consultant+week no longer identified an entry uniquely. With the
# addresses split, that ambiguity is gone rather than worked around.
#
# CHANGING AN ADDRESS HERE DOES NOT REPOINT AN EXISTING PROJECT. fx_ensure_projects
# only creates projects that are ABSENT; a project already on the environment is
# counted present and left alone. The environment has to be changed by hand too
# (TM dashboard -> Projects -> Client Approver Email). fx_reconcile_collect reports
# it when the two disagree, which is the only thing standing between a table edit
# and tokens minted against an approver the tests never remind.
FX_PROJECTS=(
  "E2E Manager Approval|Yes|No|No"
  "E2E Customer Approval|No|Yes|No"
  "E2E Dual Approval|Yes|Yes|No|jnorris+tt2@titanconsulting.net"
  "E2E Line Items|No|No|Yes"
  "E2E Sandbox|Yes|No|No"
)

# Consultant/user display names the suite depends on.
#
# 'E2E Consultant Three' is here for the CLEAR, not for any test. The seeders
# (seed-regression-ladder.sh, seed-shakedown.sh, seed-toprocess-entries.sh) all
# write timesheets for e2e_consultant3, and TT_E2E_CONSULTANTS in
# lib/_testdata.sh now clears it so those rows stop surviving both bookends.
# The clear fails when an account in that list has no Clear control, so this
# entry makes a missing account surface HERE -- named, at the preflight -- rather
# than as a confusing failure of the setup and teardown steps. No test drives
# this consultant directly, which is why it has no FX_ASSIGNMENTS row.
FX_CONSULTANTS=(
  "E2E Consultant"
  "E2E Consultant Two"
  "E2E Consultant Three"
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
# 'E2E Consultant Two -> E2E Manager Approval' is the SECOND consultant on a project
# that already has one, and it is there so two things can be tested that could not be
# before:
#   * the duplicate-assignment guard (SUB_AssignmentValidation) with a real pair of
#     consultants rather than one consultant asked for twice;
#   * anything that needs a project to hold more than one person's hours.
# Keep Two's rows CONTIGUOUS: fx_ensure_assignments caches one consultant-popup read
# and re-reads it whenever the name changes, so interleaving is correct but slower.
#
# Note the documented cascade in lib/_testdata.sh cuts across this: the deep clear
# deletes E2E Consultant's assignments AND the projects they were on, so clearing
# that consultant takes Two's Manager Approval row with it. Both are rebuilt here
# every run, so it is self-healing - but it does mean Two's row can vanish for a
# reason that has nothing to do with Two.
FX_ASSIGNMENTS=(
  "E2E Consultant|E2E Manager Approval|40"
  "E2E Consultant|E2E Customer Approval|40"
  "E2E Consultant|E2E Dual Approval|40"
  "E2E Consultant|E2E Line Items|40"
  "E2E Consultant Two|E2E Sandbox|40"
  "E2E Consultant Two|E2E Manager Approval|40"
)

# Matches the window every existing E2E assignment uses (07/01/2026 - 12/31/2027).
# The window must cover the weeks the tests drive, or the assignment exists but
# renders zero rows — the failure mode seed-shakedown.sh was written to catch.
#
# FORMAT IS LOAD-BEARING: the date picker parses typed input with its own custom
# date format, which TT-721 changed from "MMM dd, yyyy" to "MM/dd/yyyy". A value in
# the wrong shape is accepted into the DOM and then rejected by the widget with
# "Invalid date", so the save fails while the field looks correctly filled. If
# dpStartDate/dpEndDate are ever reformatted again, these two must follow.
FX_START_DATE="${FX_START_DATE:-07/01/2026}"
FX_END_DATE="${FX_END_DATE:-12/31/2027}"
FX_BUDGET_HOURS="${FX_BUDGET_HOURS:-400}"

# Matches the sibling E2E projects already on dev, so a created project is
# indistinguishable from a hand-made one.
FX_PROJECT_MANAGER="${FX_PROJECT_MANAGER:-E2E ProjectManger}"
FX_APPROVER_NAME="${FX_APPROVER_NAME:-Approver E2E}"
FX_APPROVER_EMAIL="${FX_APPROVER_EMAIL:-jnorris+tt@titanconsulting.net}"
FX_CUSTOMER="${FX_CUSTOMER:-Costco}"

FX_CREATED=0
FX_PRESENT=0
declare -A FX_CUSTOMER_OF=()
FX_MISSING=""
FX_DRIFT=""
# "|name|" for each FX_CONSULTANTS entry the dashboard gallery could not find, so
# fx_ensure_assignments reports their rows instead of failing on the picker.
FX_NO_CONSULTANT=""

# Every line carries the seconds since fx_ensure_all started (FX_T0), so a slow
# step shows WHERE its time went. Before 2026-09-29 the only number anyone had was
# the step total (1021s on dev against a 1200s budget), which cannot tell eleven
# slow objects from one retry loop.
FX_T0=""
fx_log() {
  if [ -n "$FX_T0" ]; then echo "  [fixtures] +$(( SECONDS - FX_T0 ))s $*"
  else echo "  [fixtures] $*"; fi
}

# ---------------------------------------------------------------- navigation
#
# The Titan Manager dashboard is three cards (cardCustomers / cardProjects /
# cardConsultants); clicking one switches the list below it. Verified live.

# fx_close_modals — dismiss any open Mendix popup and PROVE it is gone.
#
# DELEGATES to the shared dialog machinery in lib/_login.sh (TT_DIALOG_SEL and
# _tt_dialog_js) rather than carrying a selector of its own.
#
# WHY, IN DETAIL - THIS HELPER CAUSED A REGRESSION. The first version, added
# 2026-09-06, matched only '.modal-content' and then took m[m.length-1], "the
# last match". The comment above TT_DIALOG_SEL documents precisely why that is
# wrong: a loose modal match also hits the header/body/footer CHILDREN, so "the
# last match" can select a modal-footer whose only button is OK. It also missed
# popups carrying .mx-window-content or .mx-dialog-content without
# .modal-content, and fell back to clicking "the last visible button" - which in
# a form popup can be Save or Delete.
#
# A dialog left standing swallows every click that follows it. That is what
# produced, on the 2026-09-07 nightly:
#
#   [combobox] 'Costco' not selectable in .mx-name-cbCustomer after 6 attempts (last: NOMATCH:0)
#
# Zero options, retries useless - because the click never reached the combobox.
# The assignment form itself was verified healthy at the same time: one visible
# cbCustomer, seven options, Costco first.
#
# ONLY EVER PRESSES A DISMISS CONTROL (close / cancel / x) or Escape. It must
# never click an affirmative button: this runs before READING a list, not to
# advance a confirmation, and clicking Yes or Save on a popup it did not open
# would write data. tt_clear_dialogs is the helper for advancing a chain, and it
# is deliberately not reused here for that reason.
fx_close_modals() {
  local i present d
  d="$(_tt_dialog_js)"
  for i in $(seq 1 12); do
    present="$(playwright-cli eval "() => String($d ? 1 : 0)" 2>/dev/null | _tt_eval_str)"
    case "$present" in
      0)           return 0 ;;
      ''|*[!0-9]*) return 0 ;;   # unreadable: let the caller report the real problem
    esac
    playwright-cli eval "() => { const d=$d; if(!d) return 'none'; const btns=[...d.querySelectorAll('button')].filter(b=>b.offsetParent!==null); const b=btns.find(x=>/^(close|cancel|dismiss|x|×)$/i.test((x.innerText||'').trim())) || d.querySelector('.close, button.close, .mx-window-close, .mx-dialog-close, [aria-label=Close]'); if(b){ b.click(); return 'closed'; } return 'stuck'; }" >/dev/null 2>&1
    [ $((i % 3)) -eq 0 ] && playwright-cli press "Escape" >/dev/null 2>&1
    sleep 1
  done
  return 1
}

# fx_view <card> <gallery> — switch the dashboard to one of the three lists.
#
# RE-CLICKS ON EVERY ATTEMPT, deliberately. The original clicked once and then
# only polled, so a click that never landed could not be recovered: the loop
# waited 8s for a view change that nothing was still asking for, then blamed the
# page with "the Titan Manager dashboard layout has changed".
#
# That is exactly what happened on CI run 34044379324, where the layout was
# fine. fx_project_customer runs immediately after fx_consultant_assignments,
# which opens the consultant detail popup; the popup was still up, the card
# click hit its backdrop, and two assignments were reported as unbuildable. It
# had gone unnoticed because until the clear started deleting structure, the
# assignments were nearly always already present and this path almost never ran.
#
# Clicking a dashboard card is idempotent -- it just re-selects that view -- so
# retrying the click costs nothing and fixes the swallowed-click case.
fx_view() {
  local card="$1" gal="$2" i blocked

  fx_close_modals || fx_log "note    a popup is still open before switching to '$card'"

  # Already on that view? Then there is nothing to click. The gallery is only in
  # the DOM while its card's view is showing (the success check below relies on
  # exactly that), so this reads the same signal BEFORE clicking instead of only
  # after. Saves a click, an eval and a settle-sleep on every call that did not
  # need to move - most of fx_create_assignment's calls.
  if [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-$gal') && !$(_tt_dialog_js))" 2>/dev/null | _tt_eval_str)" = "true" ]; then
    return 0
  fi

  for i in $(seq 1 12); do
    playwright-cli click ".mx-name-$card" >/dev/null 2>&1
    if [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-$gal'))" 2>/dev/null | _tt_eval_str)" = "true" ]; then
      sleep 1; return 0
    fi
    sleep 1
  done

  # Say WHICH of the two it was, so the next reader does not re-investigate the
  # dashboard layout the way this failure made us.
  blocked="$(playwright-cli eval "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'(no text)').replace(/\\s+/g,' ').slice(0,120) : ''; }" 2>/dev/null | _tt_eval_str)"
  case "$blocked" in
    "") tt_fail "fixtures: '$card' did not reveal '$gal' after 12 clicks — the Titan Manager dashboard layout has changed" ;;
    *)  tt_fail "fixtures: '$card' did not reveal '$gal' — a popup is still open over the dashboard so the card click never landed, reading: $blocked" ;;
  esac
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

# ------------------------------------------------------- one-call form drivers
#
# WHY THE FORMS ARE FILLED IN ONE playwright-cli CALL
# ---------------------------------------------------
# Every playwright-cli invocation is a fresh node process: ~2.2-2.6s before it
# does anything. Filling a form a field at a time (tt_fill = fill + blur,
# tt_combobox_select_text = count + click + pick + a fixed 2s, a date = four
# calls) cost ~15 calls per project and ~22 per assignment - measured on dev
# 2026-09-29, ~50s per project and ~66s per assignment, most of it node startup
# and fixed sleeps rather than the app.
#
# _FX_FORM_JS is a Playwright snippet run by `playwright-cli run-code`, so a whole
# form is one process. It is not a shortcut around the checks the per-call
# helpers made - it keeps each of them and adds two:
#   * fill() is Playwright's own, which waits for the input to be visible,
#     ENABLED and editable. That is the readiness signal the 2026-09-29 flake
#     (txtProjectName still disabled) lacked, applied to every field.
#   * a combobox pick waits for the wanted option to render rather than sleeping,
#     retries the open only while no options show (the same rule as
#     tt_combobox_select_text: clicking an open combobox toggles it shut), and
#   * AFTER everything is filled, every field is read back and compared with what
#     was asked for before Save is pressed. A cascade that reset a dependent
#     combobox (customer gates project) or a date the picker rejected is caught
#     here, by name, instead of surfacing as a saved row with the wrong values.
# Each step's failure is returned as "ERR:<step>: <reason>", never thrown past
# the caller, so the fixture log says which field it was.
#
# The spec is a list of steps: ["fill", sel, value] | ["combo", sel, text] |
# ["radio", groupName, Yes|No] | ["date", sel, value, blurSel] |
# ["check-validation"] | ["click", sel].
_FX_FORM_JS='async page => {
  const T = 15000;
  const S = __SPEC__;
  const short = e => String((e && e.message) || e).split("\n")[0].slice(0, 200);
  const optJs = w => [...document.querySelectorAll("[role=option]")].find(e => (e.innerText || "").trim().indexOf(w) === 0);
  const val = async (sel, wide) => page.evaluate(([s, wide]) => { const el = document.querySelector(s); if (!el) return null; const i = el.matches("input") ? el : el.querySelector("input"); const v = i ? (i.value || "") : ""; return wide ? (v + " " + (el.innerText || "")).trim() : v; }, [sel, wide]);
  const combo = async (cb, want) => {
    for (let i = 0; i < 6; i++) {
      if (await page.locator("[role=option]").count() === 0) await page.locator(cb).click({ timeout: T });
      try {
        await page.waitForFunction(w => [...document.querySelectorAll("[role=option]")].some(e => (e.innerText || "").trim().indexOf(w) === 0), want, { timeout: 4000 });
      } catch (e) { continue; }
      const picked = await page.evaluate(w => { const o = [...document.querySelectorAll("[role=option]")].find(e => (e.innerText || "").trim().indexOf(w) === 0); if (o) { o.click(); return true; } return false; }, want);
      if (!picked) continue;
      await page.waitForFunction(([s, w]) => { const el = document.querySelector(s); const i = el && el.querySelector("input"); const v = (i ? (i.value || "") : "") + " " + ((el && el.innerText) || ""); return v.indexOf(w) >= 0 && !document.querySelector("[role=option]"); }, [cb, want], { timeout: T });
      return;
    }
    const n = await page.locator("[role=option]").count();
    throw new Error("\x27" + want + "\x27 never offered (options showing: " + n + ")");
  };
  const radio = async (rb, want) => {
    const r = await page.evaluate(([rb, w]) => { const g = document.querySelector(".mx-name-" + rb); if (!g) return "NOGROUP"; const ls = [...g.querySelectorAll("label")]; const l = ls.find(x => (x.innerText || "").trim().toLowerCase() === w.toLowerCase()); if (!l) return "NOOPT:" + ls.map(x => (x.innerText || "").trim()).join(","); l.click(); return "OK"; }, [rb, want]);
    if (r !== "OK") throw new Error(r);
    await page.waitForFunction(([rb, w]) => { const g = document.querySelector(".mx-name-" + rb); const c = g && g.querySelector("input:checked"); if (!c) return false; const l = c.closest("label") || (c.id && g.querySelector("label[for=\x27" + c.id + "\x27]")) || c.parentElement; return !!l && (l.innerText || "").trim().toLowerCase() === w.toLowerCase(); }, [rb, want], { timeout: 5000 });
  };
  const checks = [];
  for (const st of S) {
    const [kind, a, b, c] = st;
    try {
      if (kind === "fill") { const l = page.locator(a); await l.fill(b, { timeout: T }); await l.evaluate(e => e.blur()); checks.push([a, b, false]); }
      else if (kind === "combo") { await combo(a, b); checks.push([a, b, true]); }
      else if (kind === "radio") { await radio(a, b); }
      else if (kind === "date") { const l = page.locator(a); await l.fill("", { timeout: T }); await l.click({ timeout: T }); await l.pressSequentially(b); await page.locator(c).click({ timeout: T }); checks.push([a, b, false]); }
      else if (kind === "check-validation") {
        const bad = await page.evaluate(() => [...document.querySelectorAll(".mx-validation-message")].filter(e => e.offsetParent !== null).map(e => (e.innerText || "").trim()).filter(Boolean).join(" ~ "));
        if (bad) return "ERR:validation: the form rejected the input before save: " + bad;
        for (const [sel, want, wide] of checks) { const got = await val(sel, wide); if (got === null || got.indexOf(want) < 0) return "ERR:readback: " + sel + " holds \x27" + got + "\x27, expected \x27" + want + "\x27"; }
      }
      else if (kind === "click") { await page.locator(a).click({ timeout: T }); }
      else return "ERR:spec: unknown step " + kind;
    } catch (e) { return "ERR:" + kind + " " + a + ": " + short(e); }
  }
  return "OK";
}'

# _fx_js_str <text> -- a JS double-quoted string literal. Fixture values are
# plain names, dates and e-mail addresses; anything that would need escaping is
# refused rather than escaped, because a mangled value would be typed into a form.
_fx_js_str() {
  case "$1" in *[\"\\\'\`\$]*) tt_fail "fixtures: value [$1] contains a quote, backslash or \$ - not supported by the form driver" ;; esac
  printf '"%s"' "$1"
}

# fx_run_form <step> [<step> ...] -- each step is "kind|a|b|c". Echoes OK or
# ERR:<step>: <reason>.
fx_run_form() {
  local spec="" st kind a b c
  for st in "$@"; do
    IFS='|' read -r kind a b c <<< "$st"
    spec="$spec[$(_fx_js_str "$kind"),$(_fx_js_str "$a"),$(_fx_js_str "$b"),$(_fx_js_str "$c")],"
  done
  # Split rather than ${var/pat/rep}: bash 5.2 expands & in a replacement.
  playwright-cli run-code "${_FX_FORM_JS%%__SPEC__*}[$spec]${_FX_FORM_JS#*__SPEC__}" 2>&1 | _tt_eval_str
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

# fx_create_project <name> <approvalFromManager> <approvalFromCustomer> <needsLineItems> [approverEmail]
#
# The fifth argument is optional and defaults to FX_APPROVER_EMAIL, so the five
# existing FX_PROJECTS rows behave exactly as before. It exists because every
# customer-approval project currently shares ONE approver address, and
# lib/_login_core.sh records what that costs: the approval token is minted per
# approver email and the remind gate keys on it, so "the FIRST spec in a run to
# press Remind gates every already-pending client entry for the rest of the run,
# across all projects". Giving one project its own address is the fix, and is now
# a one-field edit to the table rather than a change to this function.
fx_create_project() {
  local name="$1" mgr="$2" cust="$3" li="$4" email="${5:-$FX_APPROVER_EMAIL}" i ok=""

  fx_log "creating project '$name' (manager=$mgr customer=$cust lineItems=$li approver=$email)"

  # btnAddProject IS NO LONGER UNIQUE. Since the model's "New Project from the
  # assignment popup" work (Assignment_NewEdit renamed its New Project button to
  # btnAddProject), the same name exists on the dashboard AND inside the assignment
  # popup, which opens a different form (Assignment_NewProject) that also has a
  # txtProjectName. So a bare `playwright-cli click .mx-name-btnAddProject` with any
  # popup up is a strict-mode miss ("Add Project popup did not open"), and a
  # txtProjectName check alone cannot tell the two forms apart. Hence: close
  # popups, click the button that is NOT inside a dialog, and require the
  # dashboard's form - Project_NewEdit, whose save is btnSave, where
  # Assignment_NewProject's is btnNewProjectSave. Re-clicks while the form is
  # absent, the same swallowed-click lesson as fx_view.
  #
  # OPEN IS NOT READY. The popup renders its inputs before the form's object has
  # arrived, and until then Mendix draws them DISABLED. On dev 2026-09-29 the fill
  # landed in that window while creating 'E2E Line Items':
  #   fill('.mx-name-txtProjectName input') failed: ... locator resolved to
  #   <input mask="" disabled value="" type="text" ...
  # So the form only counts as open once txtProjectName's input exists AND is
  # enabled. A present-but-disabled input reads DISABLED: it is polled, never
  # re-clicked (the form is already up), and named as such if it never clears.
  fx_close_modals || fx_log "note    a popup is still open before Add Project"
  local d r
  d="$(_tt_dialog_js)"
  for i in $(seq 1 12); do
    r="$(playwright-cli eval "() => { if (document.querySelector('.mx-name-btnNewProjectSave')) return 'WRONGFORM'; const f=document.querySelector('.mx-name-txtProjectName'); if (f) { const inp=f.querySelector('input'); if (!inp) return 'NOINPUT'; return (inp.disabled || inp.readOnly) ? 'DISABLED' : 'OPEN'; } if ($d) return 'DIALOG'; const b=[...document.querySelectorAll('.mx-name-btnAddProject')].find(e=>!e.closest('.modal-dialog, .mx-window, .modal-content, [role=dialog]')); if (!b) return 'NOBUTTON'; b.click(); return 'CLICKED'; }" 2>/dev/null | _tt_eval_str)"
    [ "$r" = "OPEN" ] && { ok=1; break; }
    sleep 1
  done
  if [ -z "$ok" ]; then
    case "$r" in
      DISABLED) tt_fail "fixtures: the Add Project form opened but txtProjectName stayed disabled for ~40s - the form's object never arrived" ;;
      *)        tt_fail "fixtures: Add Project popup did not open (Project_NewEdit's txtProjectName never appeared; last: ${r:-unreadable})" ;;
    esac
  fi
  [ "$i" -gt 3 ] && fx_log "note    the project form took $i polls to become editable (last: $r)"

  # The whole form, read back field by field, then Save - one process. See
  # _FX_FORM_JS for what each step waits for and checks.
  r="$(fx_run_form \
    "fill|.mx-name-txtProjectName input|$name" \
    "combo|.mx-name-cbCustomer|$FX_CUSTOMER" \
    "combo|.mx-name-cbProjectManager|$FX_PROJECT_MANAGER" \
    "fill|.mx-name-txtApproverName input|$FX_APPROVER_NAME" \
    "fill|.mx-name-txtApproverEmail input|$email" \
    "radio|rbApprovalManager|$mgr" \
    "radio|rbApprovalCustomer|$cust" \
    "radio|rbNeedsLineItems|$li" \
    "check-validation" \
    "click|.mx-name-btnSave")"
  case "$r" in
    OK) ;;
    "ERR:combo .mx-name-cbCustomer:"*)        tt_fail "fixtures: customer '$FX_CUSTOMER' not selectable on the project form — set FX_CUSTOMER to one that exists (${r#ERR:})" ;;
    "ERR:combo .mx-name-cbProjectManager:"*)  tt_fail "fixtures: project manager '$FX_PROJECT_MANAGER' not selectable — that account may be missing (${r#ERR:})" ;;
    *)                                        tt_fail "fixtures: could not fill the project form for '$name': ${r:-no answer from the form driver}" ;;
  esac

  # Prove it landed rather than trusting the click - by retrieving the saved row.
  # This used to be a fixed `sleep 3`, then fx_view back to the projects list and
  # a search-as-you-type for the name: eight playwright-cli calls and ~25s per
  # project, to learn that a card with that text rendered. The retrieve proves the
  # object is committed and returns its CustomerName, which is cached below from
  # what was SAVED rather than from what this function meant to pick. Its flags
  # are compared with FX_PROJECTS by fx_reconcile_collect once everything is built.
  fx_await_saved "PROJECT|$name" \
    || tt_fail "fixtures: saved project '$name' but it cannot be read back — the save was rejected${TT_DIALOG_BLOCKED:+ (the form still reads: $TT_DIALOG_BLOCKED)}"
  local cust_saved
  cust_saved="$(printf '%s' "$FX_AWAITED" | cut -d'|' -f8)"
  [ -n "$cust_saved" ] || tt_fail "fixtures: project '$name' was saved with no customer (read back: $FX_AWAITED)"
  FX_CUSTOMER_OF[$name]="$cust_saved"
  fx_log "created '$name'"
}

# ------------------------------------------------------------ data-layer reads
#
# fx_config_snapshot (under reconciliation, below) reads every declared project
# and assignment in ONE playwright-cli eval - a retrieve per row, run in parallel
# inside the page. Since 2026-09-29 the ensure steps use it for existence too,
# instead of a UI search per row. The UI way cost, per row: fx_view plus
# fx_search (seven calls and a fixed 3s) for a project, and the consultant popup
# (~10 calls, ~35s) for a consultant's assignments - and again as the read-back
# after every create. Each playwright-cli call is ~2.6s of node startup, and on a
# freshly cleared environment every one of those pre-checks answers "absent".
#
# The data layer is not a weaker witness than the lists. fx_reconcile_collect has
# always required every declared row to be retrievable through it (ABSENT there
# fails the step as drift), so "e2e_tm can retrieve it" was already a hard
# requirement of this step. The gallery answers about what it managed to render,
# which is how it once reported an existing account as missing (see
# fx_ensure_consultants). When the snapshot cannot be read, each row falls back to
# the UI check it used to have: an unreadable data layer costs time, never a
# wrong answer.

# fx_snap_line <snapshot> <prefix> -- the snapshot line for "PROJECT|<name>" or
# "ASSIGN|<consultant>|<project>", or nothing. The trailing '|' stops one name
# matching a longer name it is a prefix of.
fx_snap_line() {
  printf '%s\n' "$1" | grep -F -m1 -- "$2|"
}

# fx_snap_state <line> -> present | absent | unknown
fx_snap_state() {
  case "$1" in
    "")                       echo unknown ;;
    PROJECT\|*\|ABSENT)       echo absent ;;
    PROJECT\|*\|ERROR\|*)     echo unknown ;;
    ASSIGN\|*\|*\|ABSENT)     echo absent ;;
    ASSIGN\|*\|*\|ERROR\|*)   echo unknown ;;
    PROJECT\|*|ASSIGN\|*)     echo present ;;
    *)                        echo unknown ;;
  esac
}

# fx_await_saved <prefix> -- after a Save click, wait until the saved row can be
# retrieved. Leaves the line in FX_AWAITED; returns 1 if it never appears.
#
# Walks the confirmation chain on every pass (tt_clear_dialogs), which the old
# fixed-sleep-then-clear did once, so a Yes/OK the save waits on is still
# answered. While the form itself is still up, tt_clear_dialogs finds no
# affirmative button on it and leaves the form's text in TT_DIALOG_BLOCKED - a
# validation message on a rejected save is exactly what the caller should print.
FX_AWAITED=""
fx_await_saved() {
  local prefix="$1" i snap line
  FX_AWAITED=""
  for i in 1 2 3 4 5 6; do
    tt_clear_dialogs 4 >/dev/null 2>&1
    snap="$(fx_config_snapshot "$prefix")"
    line="$(fx_snap_line "$snap" "$prefix")"
    if [ "$(fx_snap_state "$line")" = "present" ]; then
      FX_AWAITED="$line"
      # A save that succeeded can still leave an information popup behind;
      # answer it so the next step starts from a clean dashboard.
      tt_clear_dialogs 4 >/dev/null 2>&1
      return 0
    fi
    sleep 1
  done
  return 1
}

fx_ensure_projects() {
  local row name mgr cust li email snap line state owner
  snap="$(fx_config_snapshot)"
  for row in "${FX_PROJECTS[@]}"; do
    # Five fields read from a four-field row leaves email empty, which
    # fx_create_project then defaults to FX_APPROVER_EMAIL.
    IFS='|' read -r name mgr cust li email <<< "$row"
    line="$(fx_snap_line "$snap" "PROJECT|$name")"
    state="$(fx_snap_state "$line")"
    if [ "$state" = "unknown" ]; then
      # The data layer could not answer for this row: ask the list, as before.
      fx_log "note    project '$name' could not be retrieved (${line:-no snapshot}) - checking the list instead"
      fx_view "cardProjects" "galProjects"
      if fx_exists "txtProjectSearch" "galProjects" "$name"; then state=present; else state=absent; fi
      line=""
    fi
    if [ "$state" = "present" ]; then
      FX_PRESENT=$((FX_PRESENT+1))
      # Cache the owner for fx_ensure_assignments - only a live project with a
      # customer; anything else is left for fx_project_customer to discriminate.
      # Fields: PROJECT|name|mgr|cust|li|archived|managerName|customerName|email
      owner="$(printf '%s' "$line" | cut -d'|' -f8)"
      [ "$(printf '%s' "$line" | cut -d'|' -f6)" = "false" ] && [ -n "$owner" ] && FX_CUSTOMER_OF[$name]="$owner"
      fx_log "ok      project '$name'"
    elif [ "${TT_FIXTURES_READONLY:-0}" = "1" ]; then
      FX_MISSING="$FX_MISSING\n    project: $name ($mgr/$cust/$li)"
      fx_log "MISSING project '$name' (read-only mode, not creating)"
    else
      fx_create_project "$name" "$mgr" "$cust" "$li" "${email:-$FX_APPROVER_EMAIL}"
      FX_CREATED=$((FX_CREATED+1))
    fi
  done
}

# ---------------------------------------------------------------- consultants
#
# VERIFY ONLY — see the scope note at the top. A missing consultant/account is
# reported with its name so it can be created deliberately.
fx_ensure_consultants() {
  local name text found
  fx_view "cardConsultants" "galConsultants"
  for name in "${FX_CONSULTANTS[@]}"; do
    # ONE search per consultant. This used to call fx_exists and then fx_search
    # again for the identical text (four playwright-cli calls and a 3s wait,
    # twice): the second was only there to read the assignment count, which the
    # first search had already returned.
    text="$(fx_search "txtConsultantSearch" "galConsultants" "$name")"
    case "$text" in *"$name"*) found=1 ;; *) found="" ;; esac
    if [ -n "$found" ]; then
      FX_PRESENT=$((FX_PRESENT+1))
      # Surface the assignment count: zero is a silent killer for week-based tests.
      case "$text" in
        *"$name 0 assignments"*) fx_log "ok      consultant '$name' — WARNING: 0 assignments" ;;
        *)                       fx_log "ok      consultant '$name'" ;;
      esac
    else
      FX_NO_CONSULTANT="$FX_NO_CONSULTANT|$name|"
      # The gallery did not find it. Ask the data layer before saying so out loud:
      # on 2026-09-17 this reported 'E2E ProjectManger' as missing and told the
      # reader to create it, while Administration.Account held it, active, the
      # whole time. A preflight that sends you to create an account you already
      # have is worse than one that simply fails.
      case "$(fx_account_exists "$name")" in
        yes)
          FX_MISSING="$FX_MISSING\n    consultant/account: $name  (EXISTS and is in Administration.Account — the dashboard gallery could not find it. A UI lookup problem; do NOT create this account again.)"
          fx_log "MISSING consultant '$name' — but the account exists; the gallery lookup failed, not the account" ;;
        no)
          FX_MISSING="$FX_MISSING\n    consultant/account: $name  (create via Core.Account_New)"
          fx_log "MISSING consultant '$name'" ;;
        *)
          FX_MISSING="$FX_MISSING\n    consultant/account: $name  (not in the gallery, and the account could not be checked either — neither answer is trustworthy)"
          fx_log "MISSING consultant '$name' — and the data-layer cross-check failed too" ;;
      esac
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
#
# Returns the customer name, or one of these DISCRIMINATED failures:
#   NOPROJECT          the name is not in the gallery at all
#   NOCUSTOMER         the card shows the project but nothing before Active/Archived
#   NOSTATUS           neither Active nor Archived found — the card layout changed
#   ARCHIVED:<cust>    found, but the project is archived
#   ""                 the gallery could not be read
#
# It used to return a bare "" for every one of those, and the caller turned that into
# tt_fail — so a preflight whose whole job is to LIST what is missing aborted on its
# first unreadable row. On 2026-08-27 that printed one cryptic line
# ("could not determine which customer owns project 'E2E Manager Approval'") and hid
# the rest of the picture. The anchor was also 'Active' alone, which cannot tell an
# archived project apart from an unreadable one.
fx_project_customer() {
  local name="$1"
  fx_view "cardProjects" "galProjects" >/dev/null
  fx_search "txtProjectSearch" "galProjects" "$name" >/dev/null
  playwright-cli eval "() => { const t=((document.querySelector('.mx-name-galProjects')||{}).innerText||'').replace(/\\s+/g,' '); const i=t.indexOf('$name'); if(i<0) return 'NOPROJECT'; const rest=t.slice(i+'$name'.length); const m=rest.match(/^\\s*(.*?)\\s*\\b(Active|Archived)\\b/); if(!m) return 'NOSTATUS'; const c=m[1].trim(); if(!c) return 'NOCUSTOMER'; return (m[2]==='Archived'?'ARCHIVED:':'')+c; }" 2>/dev/null | _tt_eval_str
}

# fx_consultant_assignments <consultantName> — the assignment list text from the
# consultant detail popup. The popup itself is auto-named (listView1), so this reads
# its TEXT rather than depending on widget names that will renumber.
# fx_account_exists <fullname> — does the ACCOUNT exist, asked of the data layer?
#
# Echoes yes | no | ERR:<why>. The dashboard gallery is the only thing that has
# ever been asked whether a consultant exists, and it answers about what it managed
# to render, not about what is there. When it is wrong it is wrong in the most
# expensive direction: "create via Core.Account_New" for an account that already
# exists and is active. This is the authoritative second opinion, and e2e_tm can
# read Administration.Account (verified against dev, 2026-09-17), so it needs no
# session change.
fx_account_exists() {
  local n
  n="$(playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"//Administration.Account[FullName='$1']\", filter:{amount:5}, callback:function(o){ clearTimeout(t); res(String((o||[]).length)); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str)"
  case "$n" in
    ERR:*)       printf '%s' "$n" ;;
    ''|*[!0-9]*) printf 'ERR:unreadable[%s]' "$n" ;;
    0)           printf 'no' ;;
    *)           printf 'yes' ;;
  esac
}

fx_consultant_assignments() {
  local name="$1" out
  # fx_view and fx_search are FATAL on failure, and this function is only ever
  # called inside $( ) — where a fatal kills the subshell and hands the caller an
  # empty string, which fx_ensure_assignments then read as "consultant not found".
  # That is how one transient navigation failure on 2026-09-17 was reported as
  # five missing consultants and an account to go and create. Contain them and say
  # NONAV, so a navigation failure can never again be reported as a missing one.
  if ! ( fx_view "cardConsultants" "galConsultants" >/dev/null 2>&1 ); then
    printf 'NONAV\n'; return 0
  fi
  if ! ( fx_search "txtConsultantSearch" "galConsultants" "$name" >/dev/null 2>&1 ); then
    printf 'NONAV\n'; return 0
  fi
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-galConsultants'); if(!g) return 'NOGAL'; const c=[...g.querySelectorAll('*')].find(e=>getComputedStyle(e).cursor==='pointer' && (e.innerText||'').indexOf('$name')>=0); if(!c) return 'NOCARD'; c.click(); return 'ok'; }" >/dev/null 2>&1
  sleep 4
  # Outermost visible dialog, via the shared machinery. This used to take
  # "the last .modal-content", which can be a modal-FOOTER rather than the
  # popup - the same mistake that made fx_close_modals leave dialogs standing.
  # Reading a footer here would return "Close" instead of the assignment list
  # and be indistinguishable from a consultant with no assignments.
  out="$(playwright-cli eval "() => { const d=$(_tt_dialog_js); return d ? (d.innerText||'').replace(/\\s+/g,' ') : ''; }" 2>/dev/null | _tt_eval_str)"
  # Close the popup so the next lookup starts from a clean dashboard. VERIFIED,
  # not fire-and-forget: this used to click whatever visible button came first in
  # the modal and sleep 2s, which is how a still-open popup reached fx_view and
  # was misreported as a dashboard layout change.
  fx_close_modals || fx_log "note    consultant popup for '$name' did not close cleanly"
  printf '%s\n' "$out"
}

# fx_fill_date <selector> <value> — type a date the way a person would.
#
# `playwright-cli fill` writes straight to the DOM value, which the Mendix date
# picker never parses: the field then reads "07/01/2026" while the widget reports
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
  # Dates are TYPED (the "date" step), never written with fill: the picker only
  # parses keystrokes - see fx_fill_date. check-validation refuses to submit a
  # form the widget has already rejected (otherwise the save silently no-ops and
  # the failure surfaces later as "project not visible"), and reads every field
  # back before Save. One process for the whole form - see _FX_FORM_JS.
  local r
  r="$(fx_run_form \
    "combo|.mx-name-cbCustomer|$customer" \
    "combo|.mx-name-cbProject|$project" \
    "combo|.mx-name-cbConsultant|$consultant" \
    "fill|.mx-name-txtWeeklyHours input|$hours" \
    "fill|.mx-name-txtTotalBudgetHours input|$FX_BUDGET_HOURS" \
    "date|.mx-name-dpStartDate input|$FX_START_DATE|.mx-name-txtWeeklyHours input" \
    "date|.mx-name-dpEndDate input|$FX_END_DATE|.mx-name-txtWeeklyHours input" \
    "check-validation" \
    "click|.mx-name-btnSave")"
  case "$r" in
    OK) ;;
    "ERR:combo .mx-name-cbCustomer:"*)   tt_fail "fixtures: customer '$customer' not selectable on the assignment form (${r#ERR:})" ;;
    "ERR:combo .mx-name-cbProject:"*)    tt_fail "fixtures: project '$project' not selectable under customer '$customer' — the project may belong to a different customer (${r#ERR:})" ;;
    "ERR:combo .mx-name-cbConsultant:"*) tt_fail "fixtures: consultant '$consultant' not selectable on the assignment form (${r#ERR:})" ;;
    "ERR:validation:"*)                  tt_fail "fixtures: assignment form rejected the input before save: ${r#ERR:validation: the form rejected the input before save: }" ;;
    *)                                   tt_fail "fixtures: could not fill the assignment form for '$consultant' -> '$project': ${r:-no answer from the form driver}" ;;
  esac

  # Prove it landed rather than trusting the click. This used to be a fixed
  # `sleep 4` and then the consultant detail popup, opened and read and closed
  # again: ~12 playwright-cli calls and ~35s for every assignment, and the popup
  # is auto-named (listView1) so it could only be read as text. The retrieve
  # proves the Assignment row is committed for this consultant AND this project;
  # its window and archived flag are checked by fx_reconcile_collect afterwards.
  fx_await_saved "ASSIGN|$consultant|$project" \
    || tt_fail "fixtures: saved assignment '$consultant' -> '$project' but it cannot be read back — the save was rejected${TT_DIALOG_BLOCKED:+ (the form still reads: $TT_DIALOG_BLOCKED)}"
  fx_log "created '$consultant' -> '$project'"
}

fx_ensure_assignments() {
  local row consultant project hours have customer why last="" snap line state
  snap="$(fx_config_snapshot)"
  for row in "${FX_ASSIGNMENTS[@]}"; do
    IFS='|' read -r consultant project hours <<< "$row"

    # A consultant fx_ensure_consultants could not find in the gallery is already
    # on the MISSING list with the reason; its rows cannot be built, so say so
    # rather than fail on the picker.
    case "$FX_NO_CONSULTANT" in
      *"|$consultant|"*)
        FX_MISSING="$FX_MISSING\n    assignment: $consultant -> $project (consultant not in the dashboard gallery)"
        fx_log "MISSING consultant '$consultant' — not in the gallery, cannot check assignments"
        continue ;;
    esac

    line="$(fx_snap_line "$snap" "ASSIGN|$consultant|$project")"
    state="$(fx_snap_state "$line")"
    if [ "$state" = "unknown" ]; then
      # The data layer could not answer for this row: read the consultant popup,
      # as before - one read per consultant, reused across that consultant's rows.
      fx_log "note    assignment '$consultant' -> '$project' could not be retrieved (${line:-no snapshot}) - reading the consultant popup instead"
      if [ "$consultant" != "$last" ]; then
        have="$(fx_consultant_assignments "$consultant")"
        last="$consultant"
      fi
      case "$have" in
        NOCARD)
          FX_MISSING="$FX_MISSING\n    assignment: $consultant -> $project (consultant not in the dashboard gallery)"
          fx_log "MISSING consultant '$consultant' — not in the gallery, cannot check assignments"
          continue ;;
        NOGAL|NONAV|"")
          # The dashboard never got far enough to answer. This is NOT evidence that
          # the consultant is absent, and must not be worded as if it were: an empty
          # string here is a swallowed fatal from fx_view/fx_search, which is exactly
          # what made this line claim five consultants were missing on 2026-09-17.
          FX_MISSING="$FX_MISSING\n    assignment: $consultant -> $project (COULD NOT CHECK — neither the data layer nor the consultants gallery answered; this says nothing about whether the consultant or the assignment exists)"
          fx_log "could not check assignments for '$consultant' — the gallery did not open (answer: ${have:-empty})"
          continue ;;
        *"$project"*) state=present ;;
        *)            state=absent ;;
      esac
    fi

    if [ "$state" = "present" ]; then
      FX_PRESENT=$((FX_PRESENT+1))
      fx_log "ok      assignment '$consultant' -> '$project'"
      continue
    fi

    if [ "${TT_FIXTURES_READONLY:-0}" = "1" ]; then
      FX_MISSING="$FX_MISSING\n    assignment: $consultant -> $project (${hours}h/wk)"
      fx_log "MISSING assignment '$consultant' -> '$project' (read-only mode, not creating)"
      continue
    fi

    # A customer we cannot read is a REPORTED gap, not a reason to abort the run:
    # the remaining rows still have something useful to say, and the STILL MISSING
    # list is the artefact this step exists to produce.
    # Cached per project for the run (fx_ensure_projects fills it from the
    # retrieve): FX_ASSIGNMENTS names the same project more than once, and nothing
    # in this step changes which customer owns it. Only a plain customer name is
    # cached; every discriminated failure is re-asked.
    customer="${FX_CUSTOMER_OF[$project]:-}"
    if [ -z "$customer" ]; then
      customer="$(fx_project_customer "$project")"
      case "$customer" in
        ""|NOPROJECT|NOCUSTOMER|NOSTATUS|ARCHIVED:*) ;;
        *) FX_CUSTOMER_OF[$project]="$customer" ;;
      esac
    fi
    why=""
    case "$customer" in
      NOPROJECT)  why="project '$project' is not in the projects list" ;;
      NOCUSTOMER) why="project '$project' has no customer — Assignment_NewEdit only offers a project once its customer is picked, so this assignment cannot be created until one is set" ;;
      NOSTATUS)   why="could not parse the card for project '$project' (no Active/Archived marker) — the projects gallery layout may have changed" ;;
      ARCHIVED:*) why="project '$project' is ARCHIVED (customer '${customer#ARCHIVED:}') — an archived project renders no row for the consultant" ;;
      "")         why="could not read the projects gallery while looking up the owner of '$project'" ;;
    esac
    if [ -n "$why" ]; then
      FX_MISSING="$FX_MISSING\n    assignment: $consultant -> $project ($why)"
      fx_log "MISSING assignment '$consultant' -> '$project' — $why"
      continue
    fi

    fx_create_assignment "$consultant" "$project" "$hours" "$customer"
    FX_CREATED=$((FX_CREATED+1))
    # A popup read cached for this consultant (fallback path only) predates the
    # row just created; drop it so a later fallback re-reads.
    last=""
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
#
# Extra arguments, each "PROJECT|<name>" or "ASSIGN|<consultant>|<project>", add
# rows that are NOT in the declared tables. fx_await_saved passes the row it is
# waiting for: a spec that builds its own throwaway project (fx_create_project
# "E2E TT780 Zero <epoch>" ...) is not in FX_PROJECTS, so a snapshot of the
# declared rows alone never contained it, and every such save was reported as
# "saved project ... but it cannot be read back - the save was rejected" while the
# project sat committed on dev (cleanup found and archived it). That arrived with
# the snapshot-based read-back in #140 and broke every ad-hoc caller.
fx_config_snapshot() {
  local row name mgr cust li email consultant project hours extra names_js="" pairs_js=""

  for row in "${FX_PROJECTS[@]}"; do
    IFS='|' read -r name mgr cust li email <<< "$row"
    names_js="$names_js'$name',"
  done
  for row in "${FX_ASSIGNMENTS[@]}"; do
    IFS='|' read -r consultant project hours <<< "$row"
    pairs_js="$pairs_js['$consultant','$project'],"
  done
  for extra in "$@"; do
    case "$extra" in
      PROJECT\|*) names_js="$names_js'${extra#PROJECT|}'," ;;
      ASSIGN\|*\|*)
        IFS='|' read -r _ consultant project <<< "$extra"
        pairs_js="$pairs_js['$consultant','$project']," ;;
    esac
  done

  playwright-cli eval "() => { const P=[${names_js}]; const A=[${pairs_js}]; const d=v=>v?new Date(v).toISOString().slice(0,10):''; const proj=n=>new Promise(r=>mx.data.get({xpath:\"//Main.Project[Name='\"+n+\"']\",filter:{amount:1},callback:o=>r(o.length?['PROJECT',n,o[0].get('ApprovalFromManager'),o[0].get('ApprovalFromCustomer'),o[0].get('NeedsLineItems'),o[0].get('Archived'),o[0].get('ManagerName')||'',o[0].get('CustomerName')||'',o[0].get('ContactEmail')||''].join('|'):['PROJECT',n,'ABSENT'].join('|')),error:e=>r(['PROJECT',n,'ERROR',e.message].join('|'))})); const asg=q=>new Promise(r=>mx.data.get({xpath:\"//Main.Assignment[ConsultantName='\"+q[0]+\"'][Main.Assignment_Project/Main.Project/Name='\"+q[1]+\"']\",filter:{amount:5},callback:o=>r(o.length?['ASSIGN',q[0],q[1],d(o[0].get('StartDate')),d(o[0].get('EndDate')),o[0].get('Archived'),o[0].get('WeeklyHours')].join('|'):['ASSIGN',q[0],q[1],'ABSENT'].join('|')),error:e=>r(['ASSIGN',q[0],q[1],'ERROR',e.message].join('|'))})); return Promise.all([...P.map(proj),...A.map(asg)]).then(x=>x.join('\n')); }" 2>/dev/null | _tt_eval_str
}

# fx_reconcile_collect -- compare live configuration against the declared tables.
# Prints one drift line per problem (empty output == clean). Printing rather than
# appending to a global is deliberate: the read loop runs in a pipeline subshell,
# so a global assignment inside it would be discarded.
fx_reconcile_collect() {
  local snap f1 f2 f3 f4 f5 f6 f7 f8 f9 row name mgr cust li email
  local want_mgr want_cust want_li want_email horizon

  snap="$(fx_config_snapshot)"
  case "$snap" in
    ""|NOGAL*)
      echo "    could not read configuration through the data API - reconciliation skipped" >&2
      return 0 ;;
  esac

  # The suite steps forward up to ~10 weeks hunting an editable week, so an
  # assignment ending sooner than that is unusable even though it exists.
  horizon="$(date -d '+12 weeks' +%Y-%m-%d 2>/dev/null || echo '')"

  printf '%s\n' "$snap" | while IFS='|' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9; do
    [ -n "$f1" ] || continue
    if [ "$f1" = "PROJECT" ]; then
      if [ "$f3" = "ABSENT" ]; then
        echo "    project '$f2' could not be read back through the data API"; continue
      elif [ "$f3" = "ERROR" ]; then
        echo "    project '$f2' read failed: $f4"; continue
      fi
      for row in "${FX_PROJECTS[@]}"; do
        IFS='|' read -r name mgr cust li email <<< "$row"
        [ "$name" = "$f2" ] || continue
        want_email="$(printf '%s' "${email:-$FX_APPROVER_EMAIL}" | tr '[:upper:]' '[:lower:]')"
        if [ "$mgr"  = "Yes" ]; then want_mgr=true;  else want_mgr=false;  fi
        if [ "$cust" = "Yes" ]; then want_cust=true; else want_cust=false; fi
        if [ "$li"   = "Yes" ]; then want_li=true;   else want_li=false;   fi
        [ "$f3" = "$want_mgr" ]  || echo "    project '$f2' ApprovalFromManager is '$f3', table declares '$mgr'"
        [ "$f4" = "$want_cust" ] || echo "    project '$f2' ApprovalFromCustomer is '$f4', table declares '$cust'"
        [ "$f5" = "$want_li" ]   || echo "    project '$f2' NeedsLineItems is '$f5', table declares '$li'"
        [ "$f6" = "false" ]      || echo "    project '$f2' is ARCHIVED - it will not appear on the PM dashboard or as a consultant week row"
        [ "$f7" = "$FX_PROJECT_MANAGER" ] || echo "    project '$f2' ManagerName is '$f7', expected '$FX_PROJECT_MANAGER' (DS_ProjectsManaged retrieves via ProjectManager_Account, so the PM dashboard will not list it)"
        # ContactEmail drift is worth reporting even though nothing here sets it by
        # hand: the approval token is minted PER APPROVER ADDRESS, so an address
        # edited on the environment splits one approver into two and the customer's
        # existing link silently stops covering the new rows. Compared lower-cased
        # because SUB_Project_ValidateForSave stores toLowerCase(trim(...)).
        if [ "$cust" = "Yes" ]; then
          [ -n "$f9" ] || echo "    project '$f2' requires customer approval but has NO ContactEmail - its entries will route to AwaitingCustomerApproval and no request will ever be sent"
          [ -z "$f9" ] || [ "$(printf '%s' "$f9" | tr '[:upper:]' '[:lower:]')" = "$want_email" ] \
            || echo "    project '$f2' ContactEmail is '$f9', table declares '${email:-$FX_APPROVER_EMAIL}' - the token is minted per address, so this project's approver is not the one the tests remind"
        fi
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

# ------------------------------------------------------- transactional entries
#
# WHY THIS IS SEPARATE FROM fx_ensure_all
# ---------------------------------------
# NOT because of the clear any more. Until 2026-09-06 the structural half of this
# file ran BEFORE the clear (verify-00-fixtures sorted ahead of
# verify-000-testdata-clear-before under `LC_ALL=C sort`, '-' 0x2D before '0'
# 0x30) because the clear preserved projects and assignments while deleting
# exactly these entry rows. The deep clear now deletes structure too, so the whole
# file moved behind it and that asymmetry is gone.
#
# What keeps this separate is the SESSION. fx_ensure_all does its work signed in
# as e2e_tm, building structure through the Titan Manager dashboard.
# fx_ensure_entries has to be the consultant — it makes rows by visiting a week
# and letting the app materialise them — and it leaves the browser logged in as
# that consultant when it finishes. Folding it into fx_ensure_all would mean one
# step that silently changes identity halfway through, and a structural failure
# would surface as a confusing inability to seed a control row.
# Its caller is suites/00-setup/verify-002-seed-isolation-control.test.sh.
#
# WHAT NEEDS THIS
# ---------------
# verify-consultant-data-isolation asks, as one consultant, for another
# consultant's entries and requires the answer to be none. A zero only means
# something if the other consultant HAS entries, so that test first proves as
# administrator that the same XPath returns rows, and ABORTS when it does not:
#   "no other consultant has entries the administrator can see ... Seed one and
#    run again - passing here would mean nothing."
# That abort is the control working. Nothing was seeding the control's data: the
# entries for 'E2E Consultant Two' are created by verify-hours-validation,
# verify-timesheet-clear and verify-timesheet-status-rollup, all of which sort
# AFTER the isolation test. On a full run the control could never find a row.
#
# HOURS ARE NOT NEEDED, ONLY ROWS
# -------------------------------
# The control's XPath filters on ConsultantName alone -- no Status, no hours.
# Visiting a week is enough to produce rows: DS_Timesheet_Get finds no Timesheet
# for the week, calls SUB_Timesheet_Create, and that builds one AssignmentEntry
# per active assignment (see seed_materialise_weeks in lib/_seed.sh). So this
# fills nothing and saves nothing -- it walks the week arrows and lets the app
# create the rows, which is also why it cannot leave a half-written timesheet.
#
# WHY IT WALKS BACKWARD
# ---------------------
# tt_goto_fresh_week (lib/_rejection.sh) claims a week by stepping FORWARD from
# the current one and taking the first blank, actionable week carrying the
# project row. Five steps draw from that pool on this same consultant/project
# pair -- verify-hours-validation, verify-timesheet-clear (which takes TWO),
# verify-timesheet-status-rollup, verify-tt692693-a1 and -b1 -- and exhausting
# it is a failure mode this suite has already hit. A PAST week is invisible to a
# forward-only allocator, so seeding backward costs that pool nothing.
#
# The current week was the other candidate and is worse: it is where a reload
# silently lands (see tt_refetch_week), and the hc_save_and_refetch comment in
# verify-timesheet-clear records a real incident where a re-read picked up
# verify-hours-validation's data because both had written to the week
# containing today.
#
# consultantName|loginUser|project|weeksBack
#
# weeksBack must keep the target week inside the assignment window
# (FX_START_DATE, 07/01/2026). Main.SUB_Assignment_FilterActive only creates
# entries for assignments whose window spans the week, so a week before the
# start renders zero rows and seeds nothing.
FX_ENTRIES=(
  "E2E Consultant Two|e2e_consultant2|E2E Sandbox|3"
)

# fx_entry_count <consultantName> - AssignmentEntries visible to the CURRENT
# session for that consultant. Echoes a number, or ERR:<reason>.
#
# Deliberately the same XPath verify-consultant-data-isolation uses as its
# control, so this measures the exact thing that test requires. Run inside the
# consultant's own session: they can always read their own rows, which keeps this
# free of any assumption about what the Titan Manager role may retrieve.
fx_entry_count() {
  local xp="//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$1']"
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t=setTimeout(()=>res('ERR:timeout'),15000); mx.data.get({ xpath: \"$xp\", filter:{amount:500}, callback: function(objs){ clearTimeout(t); res(String((objs||[]).length)); }, error: function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'retrieve-refused')); } }); } catch(e) { res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

# fx_rows_text - the assignment-row gallery text for the week on screen.
fx_rows_text() {
  playwright-cli eval "() => ((document.querySelector('.mx-name-galAssignmentRows')||{}).innerText||'').replace(/\\s+/g,' ')" 2>/dev/null | _tt_eval_str
}

# fx_step_back <n> - step back n weeks, VERIFYING each step, and echo how many
# steps actually landed.
#
# Every step is confirmed against the week caption because a click issued while
# the page is still rendering is swallowed silently -- lib/_seed.sh records an
# unverified loop of 34 prev-clicks that advanced the week only 4 times. A loop
# that cannot tell a swallowed click from a completed one seeds the wrong week
# and reports success anyway.
fx_step_back() {
  local n="$1" made=0 i j before after
  for i in $(seq 1 "$n"); do
    before="$(tt_current_week)"
    playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1
    after="$before"
    for j in 1 2 3 4 5 6 7 8; do
      sleep 2
      after="$(tt_current_week)"
      [ -n "$after" ] && [ "$after" != "$before" ] && break
    done
    [ "$after" = "$before" ] && break
    made=$((made + 1))
  done
  echo "$made"
}

# fx_ensure_entries - give every consultant in FX_ENTRIES at least one
# AssignmentEntry, so the isolation control has something real to find.
#
# Idempotent: a consultant who already has rows is left alone, which matters
# because this may be run by hand against an environment that was never cleared.
#
# Leaves the session logged in as the LAST consultant it touched, not as e2e_tm.
# Every test does its own tt_login, so that is safe -- but do not append
# tm-scoped work after a call to this.
fx_ensure_entries() {
  local row who user project back count landed rows

  for row in "${FX_ENTRIES[@]}"; do
    IFS='|' read -r who user project back <<< "$row"

    tt_login "$user" "My Timesheets"

    count="$(fx_entry_count "$who")"
    case "$count" in
      ERR:*)
        FX_MISSING="$FX_MISSING\n    entries: $who (could not read them back: $count)"
        fx_log "MISSING entries for '$who' - the data layer could not be asked ($count)"
        continue ;;
      ''|*[!0-9]*)
        FX_MISSING="$FX_MISSING\n    entries: $who (entry count was not a number: [$count])"
        fx_log "MISSING entries for '$who' - unreadable count [$count]"
        continue ;;
    esac

    if [ "$count" -gt 0 ]; then
      FX_PRESENT=$((FX_PRESENT+1))
      fx_log "ok      entries for '$who' ($count already present)"
      continue
    fi

    if [ "${TT_FIXTURES_READONLY:-0}" = "1" ]; then
      FX_MISSING="$FX_MISSING\n    entries: $who on '$project' (${back} weeks back)"
      fx_log "MISSING entries for '$who' (read-only mode, not seeding)"
      continue
    fi

    landed="$(fx_step_back "$back")"
    if [ "$landed" -lt "$back" ]; then
      fx_log "note    '$who' reached only $landed of $back weeks back (stopped at $(tt_current_week))"
    fi

    # A week that renders no row for the project produced no entry for it, and
    # the likeliest reason is an assignment window that does not span the week.
    rows="$(fx_rows_text)"
    case "$rows" in
      *"$project"*) : ;;
      *) fx_log "note    week $(tt_current_week) shows no '$project' row for '$who' - check the assignment window covers it" ;;
    esac

    count="$(fx_entry_count "$who")"
    case "$count" in
      ''|*[!0-9]*|ERR:*|0)
        FX_MISSING="$FX_MISSING\n    entries: $who on '$project' (walked $landed weeks back, still no rows: [$count])"
        fx_log "MISSING entries for '$who' - walked $landed week(s) back and none were created [$count]" ;;
      *)
        FX_CREATED=$((FX_CREATED+1))
        fx_log "made    entries for '$who' - $count row(s) after walking $landed week(s) back to $(tt_current_week)" ;;
    esac
  done
}

# ---------------------------------------------------------------- entry point
fx_ensure_all() {
  [ -n "${TT_BASE_URL:-}" ] || tt_fail "fixtures: TT_BASE_URL must be set explicitly — this writes data and must never fall back to a default environment"

  FX_T0=$SECONDS
  tt_login "e2e_tm" "Add Customer"
  fx_log "phase   signed in as e2e_tm"

  # Order matters: a project must exist before it can be assigned.
  fx_ensure_projects
  fx_log "phase   projects done"
  fx_ensure_consultants
  fx_log "phase   consultants done"
  fx_ensure_assignments
  fx_log "phase   assignments done"

  # Existence is not enough -- reconcile the CONFIGURATION of what now exists.
  FX_DRIFT="$(fx_reconcile_collect)"
  fx_log "phase   reconciled"

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
