#!/usr/bin/env bash
# _login_waits.sh — part of the lib/_login.sh split (2026-09-17).
#
# Line-item name guards and the waiting helpers (tt_wait_for and friends) that
# sit under nearly every assertion in the suite.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; the parts are positional slices of one file and several depend on names
# defined in an earlier one. Sourcing lib/_login.sh is exactly what it always was.
#
# This file is lines 497-701 of the pre-split lib/_login.sh, verbatim. Everything
# below the next line is unchanged, which is how the split was verified.
# --- begin verbatim slice of the original lib/_login.sh ---
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

# tt_try_click_text <exact-text> — tt_click_text without the tt_fail: returns 1
# when nothing matches, so a caller that has somewhere else to look can move on.
#
# tt_click_text EXITS THE WHOLE TEST when it misses, which makes it the wrong
# tool for a loop over candidate targets. tt_hr_reject_project walks three HR
# tabs looking for a card, and with the fatal version a dashboard missing one of
# those captions killed the run instead of trying the next tab — and killed it
# silently, because the caller had redirected stderr away.
tt_try_click_text() {
  local txt="$1"
  playwright-cli eval "() => { const el=[...document.querySelectorAll('h4,h5,div,span,a,button,li')].find(e => (e.innerText||'').trim()==='$txt' && getComputedStyle(e).cursor==='pointer'); if (el) { el.click(); return 'ok'; } return 'none'; }" 2>/dev/null | sed -n '2p' | grep -qiw ok || return 1
  sleep 2
  return 0
}

# _tt_login_form_variant — which sign-in form is on screen right now:
#   'old' = the stock Mendix /login.html form (#usernameInput)
#   'new' = the custom Core.Login page (mx widgets, input.form-control)
#   ''    = neither appeared
# Budget: each pass costs two evals, so 15 tries was roughly 15-20 seconds. That is
# plenty against a warm app and not nearly enough against a cold one. The very first
# login of a CI run lands on a Mendix Cloud environment that may not have served a
# request in days. That first caller is whatever sorts first in suites/00-setup --
# verify-000-testdata-clear-before since 2026-09-06, and verify-00-fixtures before
# that, when "-" sorting ahead of "0" put the fixture step in front of the clear.
# Either way it is the step that eats the cold start: it failed with "login form
# not found" while every later login in the same run succeeded, which is the
# signature of a cold start rather than a broken account.
#
# The runner's health check does not cover this: it curls the index and gets a 200
# back long before the client has booted far enough to render a login form.
#
# Raised to 60. It costs nothing on the happy path, because it returns the moment a
# form appears; it only spends the time when the alternative is failing the run.
#
# TRIES IS A PARAMETER because the caller probes TWO locations. Spending the full
# cold-start budget on /login.html before even looking at the app's own page is how
# verify-000-testdata-clear-before came to eat its whole 4m timeout: each pass costs
# two evals plus a sleep, so 60 tries is 2-3 minutes of waiting for a form that this
# environment does not serve there at all. Give the first probe a short budget and
# the second the long one -- a cold start is still covered, because the app has to
# boot before EITHER page renders a form.
_tt_login_form_variant() {
  local _ tries="${1:-60}"
  for _ in $(seq 1 "$tries"); do
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
    # BOTH forms' rejection wordings. "is incorrect" is the stock /login.html
    # message; the custom Core.Login page raises an Information popup reading
    # "Invalid Credentials" instead, which this used to miss entirely -- so a
    # plainly rejected password fell through to the timeout below and was reported
    # as exit 3, "signed in via Core.Login but never reached a dashboard showing
    # '<ready>'". That sentence claims the sign-in worked and blames the ready text,
    # which is the opposite of what happened. It sent an investigation of
    # verify-000-testdata-clear-before at the landing-page wait in
    # tt_open_testdata_admin, when the account simply could not sign in (dev,
    # 2026-08-31: MxAdmin at the root URL, "Invalid Credentials").
    if playwright-cli eval "() => String(/is incorrect|invalid credentials/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null | grep -qiw true; then
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