#!/usr/bin/env bash
# Shared helpers for Titan Time E2E tests. Source it from a *.test.sh:
#   source "$(dirname "$0")/lib/_login.sh"
#
# Provides:
#   tt_login <username> <ready-text>   forms-login via /login.html, wait for <ready-text> on the dashboard
#   tt_assert_all <label> <text>...    fail unless ALL <text> substrings are present in document.body
#   tt_fail <msg>                      print FAIL and exit 1
#
# This file lives in tests/lib/ (not a *.test.sh) so the runner does not execute
# it as a test. Uses forms login (stable IDs) so it is portable across envs.
#
# Env:
#   TT_BASE_URL   app origin (no trailing slash; default http://localhost:8080)
#   TT_ROLE_PASS  password for the e2e_* role accounts (default E2ETest123!)

TT_BASE="${TT_BASE_URL:-http://localhost:8080}"
TT_PASS="${TT_ROLE_PASS:-E2ETest123!}"

tt_fail() { echo "FAIL: $*"; exit 1; }

# TT_DIALOG_SEL — the dialog CONTAINER, established by inspecting the live DOM:
#
#   3 <div class="modal-content mx-window-content">  buttons=3
#   4   <div class="modal-header mx-window-header">  buttons=1   (the × )
#   4   <div class="modal-body mx-window-body">      buttons=2   (yes / No)
#
# Two things this suite had wrong. First, NO element with class mx-dialog or
# mx-window, and nothing with role=dialog, is present at all — so the original
# '.mx-dialog,.mx-window,[role=dialog]' matched nothing and only the loose
# '[class*=modal]' ever hit, which matches the header/body/footer CHILDREN too.
# Picking "the last match" therefore selected a modal-footer, whose innerText is
# just "OK" — that is why the terminal dialog looked like an empty OK box and
# why tt654_mint_token read no token.
#
# Message popups use mx-dialog-* rather than mx-window-*, so both are listed;
# .modal-content covers either, and [role=dialog] is kept as a forward-compatible
# fallback. Always select the OUTERMOST visible match (see _tt_dialog_js).
TT_DIALOG_SEL='.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]'
TT_DIALOG_BLOCKED=""

# _tt_dialog_js — JS snippet evaluating to the topmost visible dialog container,
# or null. Outermost-wins so a nested .modal-content can never shadow its parent.
_tt_dialog_js() {
  printf "%s" "(() => { const vis=[...document.querySelectorAll('$TT_DIALOG_SEL')].filter(d=>d.offsetParent!==null); const outer=vis.filter(d=>!vis.some(o=>o!==d && o.contains(d))); return outer[outer.length-1]||null; })()"
}

# tt_clear_dialogs [max] — walk the confirmation chain on the LIVE dialog.
#
# Mendix leaves CLOSED dialogs in the DOM. A probe during the submit chain found
# four dialog nodes, only three visible, with the stale one FIRST — so
# document.querySelector('.mx-dialog,…') handed back a dead dialog whose buttons
# do nothing. Every dismiss helper in this suite did exactly that, so
# "Submit Anyway" was clicked on a corpse while the live warning stayed up. The
# timesheet never submitted, the entry stayed Draft, and ~15 approval/reject
# tests failed with "entry did not reach the PM pending queue" — pointing at the
# workflow when nothing had ever been submitted. Always take the LAST VISIBLE one.
#
# Returns 0 when every dialog is cleared. Returns 1 when a dialog offers no way
# forward — e.g. Main.Consultant_OverWeeklyHours, whose ONLY button is Close, so
# it CANCELS the submit rather than confirming it. Its text is left in
# TT_DIALOG_BLOCKED so callers can fail with the real reason instead of
# clicking Close and reporting a mystery. (Note the old regexes included
# "close", which is precisely how that cancel went unnoticed.)
# Second argument: an EXTRA caption to accept as confirmation, for dialogs whose
# confirm button is labelled with the action itself ("Approve", "Reject"). It is
# opt-in per call rather than added to the shared list on purpose: this helper runs
# in almost every test, and a generic clearer that clicked anything called "Reject"
# would happily reject an entry a test was trying to approve. Same reasoning as the
# note above about "close".
tt_clear_dialogs() {
  local max="${1:-8}" extra="${2:-}" i r d alts
  d="$(_tt_dialog_js)"
  alts='yes|submit anyway|confirm|continue|proceed|ok'
  # Strip regex metacharacters — the caption is interpolated into a JS literal.
  [ -n "$extra" ] && alts="$alts|$(printf '%s' "$extra" | tr -d '\^$.[]|()?*+{}/')"
  TT_DIALOG_BLOCKED=""
  for i in $(seq 1 "$max"); do
    r=$(playwright-cli eval "() => { const d=$d; if(!d) return 'NONE'; const btns=[...d.querySelectorAll('button')].filter(b=>b.offsetParent!==null); const b=btns.find(x=>new RegExp('^(' + '$alts' + ')\$','i').test((x.innerText||'').trim())); if(b){ b.click(); return 'ADVANCED'; } return 'BLOCKED:'+(d.innerText||'').replace(/\\s+/g,' ').slice(0,140); }" 2>/dev/null | _tt_eval_str)
    case "$r" in
      NONE) return 0 ;;
      BLOCKED:*) TT_DIALOG_BLOCKED="${r#BLOCKED:}"; return 1 ;;
    esac
    sleep 2
  done
  return 0
}

# tt_click_card <text> [label] — click a dashboard card by its caption.
#
# tt_click_text is not enough for these. It matches the element whose OWN text is
# the caption and whose OWN cursor is a pointer, but an Admin Hub card puts its
# caption in a child text widget while the click handler and the pointer live on
# the container above it. So the caption element matches on text and fails on
# cursor, and nothing is clicked. This walks up from the caption to the first
# ancestor that actually looks clickable.
tt_click_card() {
  local txt="$1" label="${2:-$1}" r
  r=$(playwright-cli eval "() => { const all=[...document.querySelectorAll('*')].filter(e => e.childElementCount < 3 && (e.innerText||'').trim() === '$txt'); const el = all[all.length-1]; if (!el) return 'notext'; let p = el; for (let i = 0; i < 8 && p; i++) { const cs = getComputedStyle(p); if (cs.cursor === 'pointer' || p.onclick || p.getAttribute('role') === 'button') { p.click(); return 'ok'; } p = p.parentElement; } el.click(); return 'leaf'; }" 2>/dev/null | _tt_eval_str)
  case "$r" in
    ok|leaf) sleep 3; return 0 ;;
    *) tt_fail "no clickable card captioned '$txt' ($label)" ;;
  esac
}

# tt_open_email_tester — land on Main.EmailTester, whatever it is called today.
#
# The page's widgets were auto-named (textBox2 / comboBox1 / actionButton3) and
# have been renamed to txtTesterEmail / cbTesterEmailType / btnTesterSend. Both
# names are accepted here so the suite works either side of that reaching an
# environment, and says which one it found rather than leaving it a mystery.
# Prints "old" or "new" so a caller can pick its selectors.
tt_open_email_tester() {
  local i variant
  for i in $(seq 1 3); do
    variant="$(playwright-cli eval "() => { if (document.querySelector('.mx-name-btnTesterSend')) return 'new'; if (document.querySelector('.mx-name-textBox2')) return 'old'; return ''; }" 2>/dev/null | _tt_eval_str)"
    [ -n "$variant" ] && { echo "$variant"; return 0; }
    tt_login "${TT_ADMIN_USER:-MxAdmin}" "Admin Hub" "${TT_ADMIN_PASS:-${TT_PASS:-}}" >/dev/null 2>&1 || true
    tt_click_card "Email Tester" "email tester card" 2>/dev/null || true
    sleep 3
  done
  return 1
}

# tt_fill <selector> <value> — playwright-cli fill that CANNOT fail silently.
#
# Every fill in this suite was written as `playwright-cli fill ... 2>/dev/null`,
# which hides the one failure that matters: when a selector matches more than
# one element Playwright refuses the write outright —
#   strict mode violation: locator('.mx-name-txtDayWed input') resolved to 3 elements
# — and the test sails on to assert a value it never entered. That is exactly
# how verify-consultant-timesheet-crud came to report "draft did not persist
# (wrote 7, re-fetched '0.00')": nothing was ever typed, and the product was
# fine. It only bites when the consultant has several assignment rows, so it
# hid on a cluttered environment and appeared on a freshly cleared one.
#
# Use :nth-match(<selector>, <n>) whenever a selector can match several rows.
tt_fill() {
  local sel="$1" val="$2" out
  out=$(playwright-cli fill "$sel" "$val" 2>&1)
  case "$out" in
    *"strict mode violation"*)
      tt_fail "fill('$sel') matched MULTIPLE elements, so Playwright refused the write. Target one with :nth-match('$sel', <n>). Left unfixed this silently writes nothing and the assertion later reads a stale 0.00." ;;
    *"### Error"*)
      tt_fail "fill('$sel') failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Line-item name guards
#
# "Add Task" COMMITS a Main.LineItem immediately with an EMPTY Name, and the name
# is filled afterwards. Main.LineItem.Name is a REQUIRED validation and a timesheet
# week saves as ONE unit — so a single unnamed line item makes the entire week
# unsaveable, for every project on it, not just the one that owns the task.
#
# The consequences land nowhere near the cause. An interrupted TT-654 task-add left
# one unnamed row behind, after which verify-tt654-a2 and -a5 reported "row is still
# editable after Submit" and the MCP SubmitWeek returned "The timesheet could not be
# saved" — three tests, two independent submit paths, all reading like a product or
# MCP fault that did not exist.
#
# Use tt_assert_task_named right after naming a task, and tt_assert_no_unnamed_tasks
# before any submit.

# tt_assert_task_named <rows-selector> <idx> <expected-name>
# Read the name back. The fills that set it are usually silenced with 2>/dev/null,
# which hides the one error that matters (a strict-mode violation refuses the write
# outright), so a read-back is the only proof it landed.
tt_assert_task_named() {
  local rows="$1" idx="$2" want="$3" got
  got="$(playwright-cli eval "() => { const els=document.querySelectorAll('$rows .mx-name-txtLineItemName input'); const el=els[$idx-1]; return el ? (el.value||'') : '__MISSING__'; }" 2>/dev/null | _tt_eval_str)"
  [ "$got" = "$want" ] || tt_fail "task #$idx name did not stick (wanted '$want', got '$got'). An unnamed line item makes this ENTIRE week unsaveable for every project on it — clear the week before retrying."
}

# tt_assert_no_unnamed_tasks <rows-selector>
# Refuse to proceed while any line item on this week has an empty Name.
tt_assert_no_unnamed_tasks() {
  local rows="$1" bad
  bad="$(playwright-cli eval "() => { const els=[...document.querySelectorAll('$rows .mx-name-txtLineItemName input')]; return els.map((e,i)=>[i+1,(e.value||'').trim()]).filter(p=>!p[1]).map(p=>'#'+p[0]).join(','); }" 2>/dev/null | _tt_eval_str)"
  [ -z "$bad" ] || tt_fail "unnamed line item(s) $bad on this week — Main.LineItem.Name is required, so the week cannot be saved and EVERY project on it will fail to submit. Almost certainly debris from an interrupted run; clear the week and retry."
}

# _tt_eval_str — decode a `playwright-cli eval` result read from stdin.
#
# playwright-cli prints:
#     ### Result
#     "the JSON-encoded return value"
#     ### Ran Playwright code
#     ```js …```
#
# So the WHOLE result is on line 2, JSON-encoded — embedded newlines arrive as a
# literal \n, and quotes as \". Readers that used `sed -n '2,$p'` swallowed the
# "### Ran Playwright code" trailer as if it were data (verify-tt683-a2 failed
# with '### Ran Playwright code' as a PDF filename), and readers that never
# unescaped produced \"result\":\"SUBMITTED\", which no test's substring match
# could ever hit.
#
# Single-line callers can keep using `sed -n '2p' | tr -d '"'`; this is for
# results that are multi-line or contain quotes.
_tt_eval_str() {
  local raw
  raw="$(sed -n '2p' | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g')"
  printf '%b\n' "$raw"
}

# tt_wait_for <css-selector> [label] — wait up to ~20s for the selector to appear.
tt_wait_for() {
  local sel="$1" label="${2:-$1}"
  local _
  for _ in $(seq 1 20); do
    if playwright-cli eval "() => String(!!document.querySelector('$sel'))" 2>/dev/null | grep -qiw true; then
      return 0
    fi
    sleep 1
  done
  tt_fail "timed out waiting for: $label"
}

# tt_click_text <exact-text> [label] — click the first clickable (cursor:pointer)
# element whose trimmed text equals <exact-text>. For auto-named controls (e.g. the
# HR/TM dashboard tab strips, which were not part of the widget-naming pass).
# <exact-text> must not contain a single quote.
tt_click_text() {
  local txt="$1" label="${2:-$1}"
  local r
  r=$(playwright-cli eval "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='$txt' && getComputedStyle(e).cursor==='pointer'); if (el) { el.click(); return 'ok'; } return 'none'; }" 2>/dev/null | sed -n '2p' | grep -iw ok || true)
  [ -n "$r" ] || tt_fail "clickable element with text '$txt' not found ($label)"
  sleep 2
}

# _tt_login_form_variant — which sign-in form is on screen right now:
#   'old' = the stock Mendix /login.html form (#usernameInput)
#   'new' = the custom Core.Login page (mx widgets, input.form-control)
#   ''    = neither appeared
# Budget: each pass costs two evals, so 15 tries was roughly 15-20 seconds. That is
# plenty against a warm app and not nearly enough against a cold one. The very first
# login of a CI run lands on a Mendix Cloud environment that may not have served a
# request in days, and the suite's own ordering makes verify-00-fixtures that first
# caller -- "-" sorts before "0", so it precedes the clear step. It failed with
# "login form not found" while every later login in the same run succeeded, which is
# the signature of a cold start rather than a broken account.
#
# The runner's health check does not cover this: it curls the index and gets a 200
# back long before the client has booted far enough to render a login form.
#
# Raised to 60. It costs nothing on the happy path, because it returns the moment a
# form appears; it only spends the time when the alternative is failing the run.
_tt_login_form_variant() {
  local _
  for _ in $(seq 1 60); do
    if playwright-cli eval "() => String(!!document.querySelector('#usernameInput'))" 2>/dev/null | grep -qiw true; then
      echo "old"; return 0
    fi
    if playwright-cli eval "() => String(!!document.querySelector('input.form-control[type=password]'))" 2>/dev/null | grep -qiw true; then
      echo "new"; return 0
    fi
    sleep 1
  done
  echo ""
}

# _tt_login_submit <variant> <user> <pass> <ready>
# Fill and submit the form on screen, then wait for the outcome. Exit codes:
#   0 signed in and the dashboard shows <ready>
#   1 credentials rejected ("… is incorrect")
#   2 authenticated but the app demands a password change (Core.Force_PasswordReset)
#   3 none of the above before the timeout
#
# 1 and 2 used to be one branch, reported as "incorrect password or forced
# reset". That conflation cost real debugging time: a VALID admin credential
# that the stock form refuses looks identical to a wrong one, so the obvious
# reading ("the password is wrong") is exactly the wrong conclusion. Keep them
# distinct.
_tt_login_submit() {
  local variant="$1" user="$2" pass="$3" ready="$4" _
  if [ "$variant" = "old" ]; then
    playwright-cli fill "#usernameInput" "$user" >/dev/null 2>&1
    playwright-cli fill "#passwordInput" "$pass" >/dev/null 2>&1
    playwright-cli click "#loginButton" >/dev/null 2>&1
  else
    playwright-cli fill "input.form-control[type=text]" "$user" >/dev/null 2>&1
    playwright-cli fill "input.form-control[type=password]" "$pass" >/dev/null 2>&1
    playwright-cli click ".mx-name-actionButton1" >/dev/null 2>&1
  fi

  for _ in $(seq 1 60); do
    if playwright-cli eval "() => String(location.pathname.indexOf('index.html') >= 0 && document.body.innerText.indexOf('$ready') >= 0)" 2>/dev/null | grep -qiw true; then
      return 0
    fi
    # Core.Force_PasswordReset: "In order to proceed with the Titan Timesheet
    # App, you must reset your password."
    if playwright-cli eval "() => String(/you must reset your password/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null | grep -qiw true; then
      return 2
    fi
    if playwright-cli eval "() => String(/is incorrect/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null | grep -qiw true; then
      return 1
    fi
    sleep 2
  done
  return 3
}

# tt_login <username> <ready-text> [password]
#
# Tries the stock /login.html form first, and FALLS BACK to the app's own
# Core.Login page at / if that form rejects the credentials.
#
# Why the fallback exists: on dev, MxAdmin authenticates fine against /xas/ but
# the stock /login.html form answers "The username or password you entered is
# incorrect" for the very same credentials, so every admin-dependent test was
# unrunnable there. The custom Core.Login page is the sign-in path the app
# actually ships (and the one a human uses), so when the legacy form refuses,
# the app's own page gets a turn before the test is allowed to fail.
#
# The fallback cannot mask a genuinely wrong password: it only runs after a
# rejection, and if the app's own page rejects too, the failure names both
# attempts.
# ---------------------------------------------------------------------------
# Authentication state cache
#
# Every one of the 50 scripts used to call tt_login, and tt_login always did a
# full logout + form sign-in. Against Mendix Cloud that is ~50 sequential
# round-trip logins and it dominated the run: the first CI run spent 40+ minutes
# and was still going. There are only about four distinct identities in the
# suite, so the other ~46 logins are pure overhead.
#
# tt_login now replays a saved storage state when one exists for that identity,
# and only falls back to the real form sign-in when there is no state or the
# state no longer works. Correctness rule: the fast path must PROVE it landed
# authenticated on the expected dashboard, and on any doubt it deletes the cache
# entry and lets the full sign-in run. A stale session must never look like a
# pass.
#
# Set TT_AUTH_CACHE=0 to force the full form login — verify-smoke-login does
# this, because testing the login flow is the whole point of that script.
TT_AUTH_DIR="${TT_AUTH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.auth}"

# Key on user AND base URL, so a cache written against localhost is never
# replayed against dev/acceptance.
_tt_auth_file() {
  local key
  key="$(printf '%s@%s' "$1" "$TT_BASE" | tr -c 'A-Za-z0-9._@-' '_')"
  printf '%s/%s.json\n' "$TT_AUTH_DIR" "$key"
}

_tt_auth_try() {
  local user="$1" ready="$2" f i
  [ "${TT_AUTH_CACHE:-1}" = "1" ] || return 1
  f="$(_tt_auth_file "$user")"
  [ -s "$f" ] || return 1

  playwright-cli state-load "$f" >/dev/null 2>&1 || return 1
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1 || return 1

  # Landing text alone is NOT enough. Two roles can share a landing string, and a
  # replayed cookie can belong to whoever was logged in when it was written - so a
  # cache hit could hand a test the wrong identity while looking perfectly healthy.
  # Every assertion downstream would then be describing the wrong user. Check WHO
  # the session actually belongs to as well, the same way lib/_seed.sh does.
  local r
  for i in $(seq 1 10); do
    r="$(playwright-cli eval "() => { let n=''; try { n = mx.session.userObject.jsonData.attributes.Name.value; } catch (e) {} const landed = document.body ? document.body.innerText.indexOf('$ready') >= 0 : false; if (n && n !== '$user') return 'WHO:' + n; return String(n === '$user' && landed); }" 2>/dev/null | _tt_eval_str)"
    case "$r" in
      true)   return 0 ;;
      WHO:*)  echo "  (cached session belonged to ${r#WHO:}, not $user - logging in properly)" >&2
              break ;;
    esac
    sleep 1
  done

  rm -f "$f"   # expired or wrong — drop it so we do not retry it all run
  return 1
}

_tt_auth_save() {
  local f
  [ "${TT_AUTH_CACHE:-1}" = "1" ] || return 0
  f="$(_tt_auth_file "$1")"
  mkdir -p "$TT_AUTH_DIR" 2>/dev/null || return 0
  playwright-cli state-save "$f" >/dev/null 2>&1 || true
}

# tt_login <username> <ready-text> [password]
# Replays a cached session when possible; otherwise signs in for real and caches
# the result. Same signature and same failure behaviour as before.
tt_login() {
  local user="$1" ready="$2" pass="${3:-$TT_PASS}"

  if _tt_auth_try "$user" "$ready"; then
    return 0
  fi

  _tt_login_interactive "$user" "$ready" "$pass"   # tt_fail's on failure
  _tt_auth_save "$user"
  return 0
}

# The original full sign-in: logout, find the form variant, submit, fall back to
# Core.Login. Unchanged apart from the name.
_tt_login_interactive() {
  local user="$1" ready="$2" pass="${3:-$TT_PASS}"
  local variant rc

  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$TT_BASE/login.html" >/dev/null 2>&1
  sleep 1
  # If cookie-clear didn't drop the (httpOnly) session, we get bounced into the app.
  # Force a client-side logout, then return to the login page.
  if playwright-cli eval "() => String(!document.querySelector('#usernameInput') && !document.querySelector('input.form-control[type=password]'))" 2>/dev/null | grep -qiw true; then
    playwright-cli eval "() => { if (window.mx && mx.logout) mx.logout(); }" >/dev/null 2>&1
    sleep 3
    playwright-cli goto "$TT_BASE/login.html" >/dev/null 2>&1
  fi

  variant="$(_tt_login_form_variant)"
  [ -n "$variant" ] || tt_fail "$user: login form not found at $TT_BASE/login.html"

  _tt_login_submit "$variant" "$user" "$pass" "$ready"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    2) tt_fail "$user: the credentials were accepted but the app demands a password change (Core.Force_PasswordReset). Clear the reset flag on this account, or point TT_ADMIN_USER at an admin that does not have it — a test cannot complete the reset without changing the password out from under you." ;;
  esac

  # Fallback: the app's own sign-in page.
  if [ "$variant" = "old" ]; then
    echo "  ($user: /login.html refused — retrying on the app's own Core.Login page)"
    playwright-cli cookie-clear >/dev/null 2>&1
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 2
    local variant2
    variant2="$(_tt_login_form_variant)"
    if [ "$variant2" = "new" ]; then
      _tt_login_submit "$variant2" "$user" "$pass" "$ready"
      rc=$?
      case "$rc" in
        0) return 0 ;;
        2) tt_fail "$user: the credentials were accepted but the app demands a password change (Core.Force_PasswordReset). Clear the reset flag on this account, or point TT_ADMIN_USER at an admin that does not have it." ;;
        1) tt_fail "$user: rejected by BOTH the stock /login.html form and the app's own Core.Login page — the password really is wrong for this account on $TT_BASE." ;;
        *) tt_fail "$user: signed in via Core.Login but never reached a dashboard showing '$ready'." ;;
      esac
    fi
    tt_fail "$user: /login.html rejected the credentials and no Core.Login form was found at $TT_BASE/ to retry against."
  fi

  case "$rc" in
    1) tt_fail "$user: credentials rejected by the Core.Login form on $TT_BASE." ;;
    *) tt_fail "$user: did not reach dashboard (expected text '$ready')" ;;
  esac
}

tt_assert_all() {
  local label="$1"; shift
  local s
  for s in "$@"; do
    playwright-cli eval "() => String(document.body.innerText.indexOf('$s') >= 0)" 2>/dev/null | grep -qiw true \
      || tt_fail "$label: expected text not found: '$s'"
  done
}

# tt_combobox_sorted <combobox-css> <dismiss-css> <label>
# Opens the (Mendix pluggable) combobox, asserts its rendered option list has >=2
# items in ascending (case-insensitive) order, then clicks <dismiss-css> — a neutral
# field on the same form — to close the dropdown WITHOUT closing the popup.
# (Escape closes the whole popup, so we never use it.)
tt_combobox_sorted() {
  local cb="$1" dismiss="$2" label="$3"
  playwright-cli click "$cb" >/dev/null 2>&1
  sleep 1
  if ! playwright-cli eval "() => { const o=[...document.querySelectorAll('[role=option]')].map(e=>e.innerText.trim()).filter(Boolean); const sorted=o.every((n,i)=>i===0||o[i-1].toLowerCase().localeCompare(n.toLowerCase())<=0); return String(o.length>=2 && sorted); }" 2>/dev/null | grep -qiw true; then
    playwright-cli click "$dismiss" >/dev/null 2>&1
    tt_fail "$label: dropdown options are not sorted ascending (or fewer than 2 options)"
  fi
  playwright-cli click "$dismiss" >/dev/null 2>&1
  sleep 1
}

# tt_combobox_select_first <combobox-css>
# Opens the combobox and clicks its first option (used to drive cascading forms
# where dependent dropdowns only populate after a selection). Selecting an option
# closes the dropdown, so no dismiss is needed.
tt_combobox_select_first() {
  local cb="$1"
  playwright-cli click "$cb" >/dev/null 2>&1
  sleep 1
  playwright-cli eval "() => { const o = document.querySelector('[role=option]'); if (o) { o.click(); return 'ok'; } return 'none'; }" >/dev/null 2>&1
  sleep 2
}

# tt_combobox_select_text <combobox-css> <option-text>
# Opens the combobox and clicks the option whose text starts with <option-text>.
# Returns 1 if no such option rendered.
#
# The result is read from line 2, never grepped from the whole output: the
# echoed SOURCE contains the literal 'true', so a plain grep would match the
# snippet rather than its return value and pass no matter what happened.
tt_combobox_select_text() {
  local cb="$1" want="$2"
  playwright-cli click "$cb" >/dev/null 2>&1
  sleep 1
  if playwright-cli eval "() => { const o=[...document.querySelectorAll('[role=option]')].find(e=>(e.innerText||'').trim().indexOf('$want')===0); if(o){o.click(); return 'true';} return 'false'; }" 2>/dev/null \
       | sed -n '2p' | grep -qi true; then
    sleep 2; return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Customer-approval-flow helpers (see verify-customer-approval-flow.test.sh)
# ---------------------------------------------------------------------------

# tt_hr_remind_e2e_entry <consultant-name>
# On the HR "Client Approval" tab (must already be open): scans the available-
# weeks list; for each week it selects, it looks in the entries gallery for a
# pending card mentioning <consultant-name> and clicks that card's "Remind".
# Prints the matched week label and returns 0 on success; returns 1 if no
# matching entry is found in any listed week. (Reminding does NOT consume the
# entry, so the flow stays idempotent.)
tt_hr_remind_e2e_entry() {
  local who="$1" labels lbl
  # playwright-cli wraps eval results in a JSON string, so a returned array would
  # arrive double-encoded; return a pipe-joined line instead and split in bash.
  labels=$(playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return ''; const set=[...new Set([...g.querySelectorAll('*')].filter(e=>e.childElementCount===0).map(e=>(e.innerText||'').trim()).filter(t=>/^[A-Z][a-z]{2} \\d{2} - [A-Z][a-z]{2} \\d{2}/.test(t)))]; return set.join('|'); }" 2>/dev/null | sed -n '2p')
  labels="${labels%\"}"; labels="${labels#\"}"   # strip the wrapper quotes
  local IFS='|'
  for lbl in $labels; do
    [ -n "$lbl" ] || continue
    playwright-cli eval "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$lbl')===0); if(el){el.click(); return 'ok';} return 'nf'; }" >/dev/null 2>&1
    sleep 4
    if playwright-cli eval "() => { const rs=[...document.querySelectorAll('.mx-name-btnRemind')]; for(const r of rs){ let el=r; for(let i=0;i<9;i++){ el=el.parentElement; if(el && (el.innerText||'').indexOf('$who')>=0){ r.click(); return 'true'; } } } return 'false'; }" 2>/dev/null | sed -n '2p' | grep -qiw true; then
      echo "$lbl"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Mail access
#
# The suite reads mail from the app's OWN ADMIN PAGE, not from an external mail
# catcher. Core.EmailsSent_Overview lists every Email_Connector.EmailMessage the
# app has produced, with its recipient, subject, status, error and body.
#
# Why this rather than a catcher:
#
#   * No infrastructure. Nothing to run, no host to expose, no secret to
#     configure, so the same test works unchanged on a laptop and against a
#     deployed environment. The mail tests were the only reason CI needed
#     anything beyond the app itself.
#   * The recipient is a column, so "sent to the wrong address" is DETECTABLE.
#     The catcher-based reader fell back to "the newest message, whoever it was
#     addressed to", which meant no test could ever catch a misdirected mail.
#   * Rows exist at QUEUED, before the ~2-minute send event runs, so a test can
#     assert that a mail was RAISED without waiting for it to be delivered.
#
# What it costs: the page is Core.Administrator-only, so reading mail means
# logging in as the administrator and losing whatever role session the test was
# using. Read mail at the END of a step, or log back in afterwards.
#
# Freshness is a HIGH-WATER MARK, not an emptied inbox. tt_mail_prepare records
# the rows that already exist; later reads consider only rows that were not there
# before. Nothing is deleted, so this is safe on a shared environment. Two limits
# follow, stated rather than hidden: two byte-identical mails collapse into one,
# and only rows the grid renders are visible - hence the newest-first sort below,
# which keeps fresh mail on the first page.
#
# Env:
#   TT_ADMIN_USER / TT_ADMIN_PASS  administrator account (already required)
#   TT_MAIL_DOMAIN                 domain for tt_mail_address (default e2e.local)
#   TT_MAIL_CUSTAPPROVAL_TAG       default recipient filter (default custapproval)
# ---------------------------------------------------------------------------

TT_MAIL_SEEN_FILE=""

_tt_mail_tag() {
  echo "${1:-${TT_MAIL_CUSTAPPROVAL_TAG:-custapproval}}"
}

_tt_mail_grid_up() {
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-gridEmailsSent'))" 2>/dev/null | _tt_eval_str
}

# _tt_mail_open - as the administrator, land on the Emails Sent grid.
_tt_mail_open() {
  local i
  [ "$(_tt_mail_grid_up)" = "true" ] && return 0
  tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}" || return 1
  playwright-cli click ".mx-name-cardEmailsSent" >/dev/null 2>&1
  for i in $(seq 1 20); do
    [ "$(_tt_mail_grid_up)" = "true" ] && return 0
    sleep 1
  done
  return 1
}

# _tt_mail_sort_newest - sort by Sent Date descending so new mail is on page one.
# Best effort: the grid paginates at 20, and without this a busy environment can
# push a fresh message onto a later page where no read would ever see it.
_tt_mail_sort_newest() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-gridEmailsSent'); if(!g) return 'nogrid'; const hs=[...g.querySelectorAll('[role=columnheader], th')]; const h=hs.find(e=>/sent\\s*date/i.test((e.innerText||'').trim())); if(!h) return 'nocol'; for(let i=0;i<3;i++){ const s=(h.getAttribute('aria-sort')||'').toLowerCase(); if(s.indexOf('desc')===0) return 'desc'; (h.querySelector('[role=button],button')||h).click(); } return (h.getAttribute('aria-sort')||'unsorted'); }" 2>/dev/null | _tt_eval_str
}

# _tt_mail_rows - one line per rendered row, cells joined by " ~ ".
_tt_mail_rows() {
  playwright-cli eval "() => { const g=document.querySelector('.mx-name-gridEmailsSent'); if(!g) return ''; return [...g.querySelectorAll('[role=row], tr')].map(r=>[...r.querySelectorAll('[role=gridcell], td')].map(c=>(c.innerText||'').replace(/\\s+/g,' ').trim()).join(' ~ ')).filter(s=>s.replace(/[ ~]/g,'').length>0).join('\\n'); }" 2>/dev/null | _tt_eval_str
}

# _tt_mail_refresh - re-read the grid without paying for a fresh login.
_tt_mail_refresh() {
  local i
  playwright-cli reload >/dev/null 2>&1
  for i in $(seq 1 15); do
    if [ "$(_tt_mail_grid_up)" = "true" ]; then
      _tt_mail_sort_newest >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done
  _tt_mail_open
}

# _tt_mail_new_rows - rows that were not present at tt_mail_prepare time.
_tt_mail_new_rows() {
  local cur
  cur="$(_tt_mail_rows)"
  if [ -s "${TT_MAIL_SEEN_FILE:-/dev/null}" ]; then
    printf '%s\n' "$cur" | grep -Fxv -f "$TT_MAIL_SEEN_FILE" 2>/dev/null || true
  else
    printf '%s\n' "$cur"
  fi
}

# --- the API the tests use -------------------------------------------------

# tt_mail_prepare - make sure mail is readable, and mark what is already there.
# Call it BEFORE the action that triggers the send.
tt_mail_prepare() {
  _tt_mail_open \
    || tt_fail "could not open the Emails Sent page as ${TT_ADMIN_USER:-MxAdmin} - the suite has nowhere to read mail from (is that account an Administrator?)"
  _tt_mail_sort_newest >/dev/null 2>&1 || true
  [ -n "$TT_MAIL_SEEN_FILE" ] || TT_MAIL_SEEN_FILE="$(mktemp)"
  _tt_mail_rows > "$TT_MAIL_SEEN_FILE"
}

# tt_mail_reset - kept so existing call sites read unchanged; re-marks the page.
tt_mail_reset() { tt_mail_prepare; }

# tt_mail_address <tag> - a synthetic address for the cases where a test CHOOSES
# the recipient (the Email Tester). Mail to the app's real addresses is listed
# too, and is filtered by passing that address as the tag.
tt_mail_address() {
  local tag="${1:-e2e}"
  echo "${tag}@${TT_MAIL_DOMAIN:-e2e.local}"
}

# tt_mail_token <ts-ms> [link-regex] [recipient] [timeout-seconds]
# Print the first link matching <link-regex> (default: customer-approval) from
# mail that appeared since tt_mail_prepare.
#
# <ts-ms> is accepted and ignored: freshness comes from the high-water mark,
# which is stronger than a timestamp fence. The argument is kept so existing
# call sites read unchanged.
tt_mail_token() {
  local ts="$1" rx="${2:-customer-approval}" want="${3:-}" budget="${4:-120}"
  local tag waited=0 rows link scoped
  tag="$(_tt_mail_tag "$want")"
  while [ "$waited" -lt "$budget" ]; do
    rows="$(_tt_mail_new_rows)"
    scoped="$(printf '%s\n' "$rows" | grep -i -- "$tag" 2>/dev/null || true)"
    if [ -n "$scoped" ]; then
      rows="$scoped"
    elif [ -n "$want" ]; then
      rows=""     # an explicit recipient was demanded: do not settle for another
    fi
    link="$(printf '%s' "$rows" | grep -oE "https?://[^ \"'<>()~]+${rx}[^ \"'<>()~]*" | head -1)"
    if [ -n "$link" ]; then echo "$link"; return 0; fi
    sleep 5; waited=$((waited + 5))
    _tt_mail_refresh >/dev/null 2>&1 || true
  done
  return 1
}

# tt_mail_message <ts-ms> [recipient] [timeout-seconds]
# Print the mail that just appeared as "Subject: <s>", a blank line, then the row
# as rendered (recipient, status and body included) - the primitive for a test
# that wants to LOOK at the mail rather than pull a link out of it.
tt_mail_message() {
  local ts="$1" want="${2:-}" budget="${3:-120}"
  local tag waited=0 rows row subj
  tag="$(_tt_mail_tag "$want")"
  while [ "$waited" -lt "$budget" ]; do
    rows="$(_tt_mail_new_rows)"
    row="$(printf '%s\n' "$rows" | grep -i -- "$tag" 2>/dev/null | head -1 || true)"
    if [ -z "$row" ] && [ -z "$want" ]; then
      row="$(printf '%s\n' "$rows" | head -1)"
    fi
    if [ -n "$row" ]; then
      subj="$(printf '%s' "$row" | awk -F' ~ ' '{print $3}')"
      printf 'Subject: %s\n\n%s\n' "$subj" "$row"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
    _tt_mail_refresh >/dev/null 2>&1 || true
  done
  return 1
}

# tt_mail_to <substring> - the recipient of the new mail matching <substring>.
# This is what the catcher could never answer: it exists so a test can assert
# that mail went to the RIGHT address.
tt_mail_to() {
  _tt_mail_new_rows | grep -i -- "$1" | head -1 | awk -F' ~ ' '{print $2}'
}


# tt_consultant_submit_entry
# Fallback data-setup (only used when no pending entry exists): as the currently
# logged-in consultant, steps forward to the first editable week, fills Mon-Fri,
# and submits — clicking through whatever confirm dialogs appear (future-week
# "Submit Anyway", under-40 warning, "Are you sure? yes"). Returns 0 if the row
# became non-editable (submitted), 1 otherwise. Exact hours may vary (Mendix
# decimal inputs commit unreliably under automation) but any submitted entry
# reaches AwaitingCustomerApproval, which is all this flow needs.
tt_consultant_submit_entry() {
  local i d
  for i in $(seq 1 10); do
    if playwright-cli eval "() => { const dm=document.querySelector('.mx-name-txtDayMon input'); const ed=dm && !dm.disabled && !dm.readOnly; const hasSubmit=!!document.querySelector('.mx-name-btnSubmit'); return String(!!ed && hasSubmit); }" 2>/dev/null | grep -qiw true; then
      break
    fi
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSubmit'))" 2>/dev/null | grep -qiw true \
    || tt_fail "consultant: no editable week with a Submit button found"
  # :nth-match is required, not cosmetic: a consultant on several projects has
  # one row per assignment, so a bare .mx-name-txtDayX selector matches them all
  # and Playwright refuses the fill. See tt_fill.
  for d in Mon Tues Wed Thurs Fri; do
    tt_fill ":nth-match(.mx-name-txtDay${d} input, 1)" "8"
  done
  # force the last cell to commit via real focus changes
  playwright-cli click ":nth-match(.mx-name-txtDaySat input, 1)" >/dev/null 2>&1
  playwright-cli click ":nth-match(.mx-name-txtDayMon input, 1)" >/dev/null 2>&1
  sleep 1
  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  # click through any confirm dialogs (Submit Anyway / yes) until none remain
  # Confirmation chain: "Are you Sure? yes" then possibly "Submit Anyway" (current/future
  # week and/or <40h). Click the affirmative only — NEVER the close 'x' (it cancels submit).
  # Mendix popups are .mx-window/.mx-dialog, not [role=dialog]/.modal-dialog.
  # tt_clear_dialogs targets the LAST VISIBLE dialog. The loop that used to
  # live here called document.querySelector, which can return a stale hidden
  # dialog left behind by Mendix — clicking its buttons does nothing, so the
  # confirm chain stalled and the timesheet was never submitted.
  if ! tt_clear_dialogs 8; then
    tt_fail "submit blocked by a dialog with no way forward: $TT_DIALOG_BLOCKED"
  fi
  sleep 2
  playwright-cli eval "() => { const i=document.querySelector('.mx-name-txtDayMon input'); return String(i ? (i.disabled||i.readOnly) : false); }" 2>/dev/null | grep -qiw true
}

# tt_consultant_submit_project_row <project-substring>
# Multi-assignment variant of tt_consultant_submit_entry: on the consultant
# timesheet (which shows one row per active assignment), steps forward to the
# first week where the row for <project-substring> is editable, fills THAT row's
# Mon-Fri, and submits — clicking through any confirm dialog. Targets the correct
# row by computing its ordinal at runtime (row order is not assumed) and using
# Playwright's :nth-match. Best-effort (exact hours may vary); returns 0.
tt_consultant_submit_project_row() {
  local proj="$1" ord="" i d
  for i in $(seq 1 12); do
    ord=$(playwright-cli eval "() => { const mons=[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon')]; const isTarget=(mon)=>{let el=mon; for(let k=0;k<12;k++){el=el.parentElement; if(!el)break; const t=el.innerText||''; if(t.indexOf('$proj')>=0 && (t.match(/E2E (Customer|Manager) Approval/g)||[]).length===1) return true;} return false;}; for(let n=0;n<mons.length;n++){ const inp=mons[n].querySelector('input'); if(isTarget(mons[n]) && inp && !inp.disabled && !inp.readOnly && document.querySelector('.mx-name-btnSubmit')) return String(n+1); } return '0'; }" 2>/dev/null | sed -n '2p')
    ord="${ord%\"}"; ord="${ord#\"}"
    [ -n "$ord" ] && [ "$ord" != "0" ] && break
    playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
    sleep 2
  done
  { [ -n "$ord" ] && [ "$ord" != "0" ]; } || tt_fail "consultant: no editable week with a '$proj' row found"

  # Record WHICH week is being submitted, in the "MMM DD - MMM DD" form the HR
  # dashboard uses. Callers need it to find the entry they just created rather
  # than any card that happens to mention the same project — see
  # tt647_select_exact_week. The consultant caption is "E2E Oct 04 - Oct 10";
  # the HR week picker renders "Oct 04 - Oct 10, 2026". Stripping the prefix
  # and keeping the day range makes them comparable.
  TT_SUBMITTED_WEEK=$(playwright-cli eval "() => { const t=((document.querySelector('.mx-name-txtWeekRange')||{}).innerText||'').trim(); const m=t.match(/[A-Z][a-z]{2}\\s+\\d{1,2}\\s*-\\s*[A-Z][a-z]{2}\\s+\\d{1,2}/); return m ? m[0] : ''; }" 2>/dev/null | sed -n '2p' | tr -d '"')
  export TT_SUBMITTED_WEEK

  for d in Mon Tues Wed Thurs Fri; do
    playwright-cli fill ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "8" >/dev/null 2>&1
  done
  # commit the last cell via real focus changes within the same row
  playwright-cli click ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDaySat input, ${ord})" >/dev/null 2>&1
  playwright-cli click ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDayMon input, ${ord})" >/dev/null 2>&1
  sleep 1

  # Save Draft BEFORE submitting, then confirm the hours actually persisted.
  # Without this the typed values often never reach the server: the entry
  # submits with TotalHours = 0, which the status expression routes STRAIGHT to
  # ToProcess ("if TotalHours = 0 then ToProcess") with no approval step. The
  # card then legitimately reads "No approval required" — which is what made
  # verify-tt647-a2/a6 look like TT-647 defects when the seed was at fault.
  if playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnSaveDraft'))" 2>/dev/null | grep -qiw true; then
    playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
    sleep 3
    tt_clear_dialogs 4 >/dev/null 2>&1 || true
  fi
  local mon
  mon=$(playwright-cli eval "() => String((document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDayMon input')[$ord - 1]||{}).value||'')" 2>/dev/null | sed -n '2p' | tr -d '"')
  case "$mon" in
    ""|0|0.00|0.0)
      tt_fail "consultant: hours did not persist on the '$proj' row (Monday reads '$mon'). Submitting now would create a ZERO-hour entry, which skips approval entirely and renders 'No approval required' — any approval assertion downstream would be meaningless." ;;
  esac

  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  # Confirmation chain: "Are you Sure? yes" then possibly "Submit Anyway" (current/future
  # week and/or <40h). Click the affirmative only — NEVER the close 'x' (it cancels submit).
  # Mendix popups are .mx-window/.mx-dialog, not [role=dialog]/.modal-dialog.
  # tt_clear_dialogs targets the LAST VISIBLE dialog. The loop that used to
  # live here called document.querySelector, which can return a stale hidden
  # dialog left behind by Mendix — clicking its buttons does nothing, so the
  # confirm chain stalled and the timesheet was never submitted.
  if ! tt_clear_dialogs 8; then
    tt_fail "submit blocked by a dialog with no way forward: $TT_DIALOG_BLOCKED"
  fi
  sleep 2
  return 0
}
