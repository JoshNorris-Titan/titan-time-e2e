#!/usr/bin/env bash
# _login_auth.sh — part of the lib/_login.sh split (2026-09-17).
#
# The authentication surface: the .auth/ session cache and its identity check,
# the interactive sign-in with its forced-reset disambiguation, tt_login, and
# the guard that refuses the built-in password off localhost.
#
# DO NOT SOURCE THIS DIRECTLY. Source lib/_login.sh, which sources every part in
# order; the parts are positional slices of one file and several depend on names
# defined in an earlier one. Sourcing lib/_login.sh is exactly what it always was.
#
# This file is lines 702-936 of the pre-split lib/_login.sh, verbatim. Everything
# below the next line is unchanged, which is how the split was verified.
# --- begin verbatim slice of the original lib/_login.sh ---
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
# Refuse the built-in password against anything but localhost.
#
# This is the TT_BASE_URL incident of 2026-08-27 wearing different clothes. That one
# is written up at length in run-tests.sh: a silent default meant a run intended for
# dev went somewhere else entirely, and the resulting nonsense read as real data
# drift. The fix there was to make the target impossible to leave implicit. The same
# hole was left open one field over -- TT_ROLE_PASS still falls back to a literal
# baked into this file.
#
# Off localhost that default is not merely wrong, it is wrong in the most expensive
# way available: the accounts it is tried against are REAL, so the app answers
# "wrong username or password" per account, which reads as the e2e users having been
# changed or deprovisioned on the environment. The suite has a whole disambiguation
# path for exactly that confusion (_tt_login_interactive tells a bad password apart
# from a forced reset), and password-refresh/ exists because these logins really do
# age out -- so the false signal lands in the one place there is already a plausible
# true story for it. Repeated attempts across the role accounts can also trip real
# lockouts, turning a misconfiguration into damage to the environment.
#
# Localhost keeps the default deliberately: a local app built from this repo's own
# fixtures has that password by construction, and README's local-run instructions
# depend on it.
#
# Checked at first login rather than at source time on purpose -- verify-lib-contract
# sources every library with no environment at all and asserts total silence, so a
# guard that fired on `source` would fail it.
_TT_PASS_CHECKED=""
_tt_require_explicit_pass() {
  [ -z "$_TT_PASS_CHECKED" ] || return 0
  _TT_PASS_CHECKED=1
  [ -z "${TT_ROLE_PASS:-}" ] || return 0        # set explicitly: nothing to police
  case "$TT_BASE" in
    http://localhost*|https://localhost*|http://127.0.0.1*|https://127.0.0.1*) return 0 ;;
  esac
  tt_fail "TT_ROLE_PASS must be set explicitly for a non-local target ($TT_BASE).
      Falling back to the built-in password would try a literal from lib/_login.sh
      against the real e2e_* accounts. That does not fail as a misconfiguration --
      it fails as 'wrong username or password' on every role, which looks exactly
      like the accounts having been changed on the environment, and repeated
      attempts can lock them. Same class of bug as the TT_BASE_URL default removed
      on 2026-08-27; see the note in run-tests.sh.
      Set TT_ROLE_PASS (CI takes it from the secret of the same name)."
}

tt_login() {
  local user="$1" ready="$2" pass="${3:-$TT_PASS}"
  _tt_require_explicit_pass

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

  # /login.html first, on a SHORT budget, then the app's own page on the long one.
  #
  # WHY BOTH, IN THIS ORDER. Some accounts are not offered the stock form at all --
  # measured on dev 2026-08-31, MxAdmin's /login.html served no #usernameInput and no
  # password field for the full 60-try probe, while $TT_BASE/ rendered Core.Login
  # immediately. This used to tt_fail right here with "login form not found at
  # .../login.html", never trying the page that works, after burning ~2-3 minutes
  # doing it. Falling through costs nothing when /login.html does work: the probe
  # returns the moment a form appears.
  variant="$(_tt_login_form_variant 10)"
  if [ -z "$variant" ]; then
    echo "  ($user: no form at /login.html — going to the app's own sign-in page)"
    playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
    sleep 2
    variant="$(_tt_login_form_variant 10)"
    if [ -z "$variant" ]; then
      # Same trap the /login.html block above handles: cookie-clear does not always
      # drop the (httpOnly) session, and the ROOT url of a signed-in session renders
      # the app, not Core.Login. Without this the fallback reports "no sign-in page
      # at either location" purely because the previous test was still logged in.
      playwright-cli eval "() => { if (window.mx && mx.logout) mx.logout(); }" >/dev/null 2>&1
      sleep 3
      playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
      sleep 2
      variant="$(_tt_login_form_variant)"
    fi
    [ -n "$variant" ] || tt_fail "$user: no login form at $TT_BASE/login.html OR $TT_BASE/ — the app did not render a sign-in page at either location."
  fi

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

# tt_wait_text <text> [label] [tries]
#
# Poll until <text> appears anywhere in the page body. Use this INSTEAD of
# tt_assert_all for the first assertion that depends on an asynchronously loaded
# widget -- a gallery or list backed by a microflow data source.
#
# tt_assert_all is deliberately single-shot: one indexOf, no retry. That is right
# for content already on screen, and wrong for content still being fetched.
#
# Wait once for the slow thing, then assert the rest single-shot as before.
#
# WHAT THIS HELPER CANNOT DO. It only waits; it never makes the page load more. The
# note that used to sit here blamed verify-pm-dashboard-pending's managed-project
# failure on render timing and claimed the project was "one of only 10 that PM
# manages, well inside any page size". Both halves were wrong. That gallery pages at
# THREE with virtual scrolling, so 'E2E Customer Approval' was not in the DOM at all
# and no amount of waiting could ever find it. When the target lives in a gallery,
# reach for tt_gallery_load_until_text below instead -- a text wait against a paged
# list fails after the full timeout and reads exactly like slow data.
tt_wait_text() {
  local needle="$1" label="${2:-$1}" tries="${3:-20}" i
  for i in $(seq 1 "$tries"); do
    if playwright-cli eval "() => String(document.body.innerText.indexOf('$needle') >= 0)" 2>/dev/null | grep -qiw true; then
      return 0
    fi
    sleep 1
  done
  tt_fail "timed out waiting for text: $label"
}
