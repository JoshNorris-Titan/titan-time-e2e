#!/usr/bin/env bash
# Tier 0 smoke test (anonymous, NON-DESTRUCTIVE) — the "Forgot password?" link.
#
# WHAT THIS COVERS. The self-service password reset added on 2026-08-26:
# btnForgotPassword on Core.Login calls Core.ACT_Password_Forgot with the login
# form's LoginHelper. This drives the two paths that change nobody's password:
#
#   1. the control is present and reachable WITHOUT a session;
#   2. clicking it with an empty username gives field-level validation and does
#      NOT claim an email was sent;
#   3. an identifier matching no account gets the generic confirmation, and that
#      confirmation does not echo the submitted identifier back.
#
# WHY 3 IS THE POINT. Core.Login is the anonymous home page, so this form is
# reachable by anyone on the internet. ACT_Password_Forgot deliberately shows the
# SAME message whether or not an account matched — otherwise the form becomes a
# username-and-email oracle: submit an address, read the response, learn whether
# that person has an account. The flow being silent about misses is the security
# property, and it is the one a well-meaning "helpful error message" change would
# quietly remove.
#
# WHAT THIS DOES NOT COVER, deliberately. The found-account path — password
# replaced, ForceReset flagged, mail queued. Proving that end to end through the
# UI requires resetting a real account's password, which would break every later
# test in the run (they all sign in with TT_ROLE_PASS) and cannot be undone,
# because the new password only exists in an email this suite cannot read. That
# half is covered by the unit tests in Core's "995. Unit Tests/Password", which
# roll back. See also verify-email-templates-present, which proves the
# ForgotPassword template row exists so the send is not skipped silently.
#
# No login, no writes, nothing to clean up.
#
# Environment:
#   TT_BASE_URL   app origin (no trailing slash)
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

BASE="${TT_BASE_URL:-http://localhost:8080}"

# An identifier no account can plausibly have. Fixed rather than random so a
# failure is reproducible, and shaped like an address so it exercises the Email
# half of the flow's "Name or Email" lookup rather than only the username half.
UNKNOWN="ut-nobody-9f83ka@titan.test"

# A distinctive fragment of the confirmation ACT_Password_Forgot shows. Matching a
# fragment rather than the whole sentence means rewording the middle of the message
# does not fail the test, but removing it entirely does.
CONFIRM_RE="temporary password has been sent"

# ------------------------------------------------------------------- helpers

# fp_open — land on the anonymous custom login page, with no session.
fp_open() {
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$BASE/" >/dev/null 2>&1
  local variant
  variant="$(_tt_login_form_variant)"
  case "$variant" in
    new) return 0 ;;
    old)
      tt_fail "the anonymous home page served the STOCK Mendix login form, not Core.Login. btnForgotPassword only exists on Core.Login, so the link cannot be reached from here. Check the navigation profile's home page." ;;
    *)
      tt_fail "no sign-in form appeared at $BASE/ within the timeout - the app may still be starting" ;;
  esac
}

# fp_body_matches <js-regex-body> — does the page text match? echoes true/false.
# The needle grepped for by callers is 'true', which never appears in the snippet,
# so this cannot match its own echoed source (see verify-no-echo-trap).
fp_body_matches() {
  playwright-cli eval "() => String(/$1/i.test(document.body ? document.body.innerText : ''))" 2>/dev/null | sed -n '2p' | tr -d '"'
}

# fp_wait_for_body <js-regex-body> <seconds> — poll for text to appear.
fp_wait_for_body() {
  local re="$1" budget="${2:-20}" i
  for i in $(seq 1 "$budget"); do
    [ "$(fp_body_matches "$re")" = "true" ] && return 0
    sleep 1
  done
  return 1
}

fp_click_forgot() {
  playwright-cli click ".mx-name-btnForgotPassword" >/dev/null 2>&1
}

# --------------------------------------------------- 1. the control is present

fp_open

# Named explicitly in the model precisely so this selector is a contract. If it
# ever reads as absent, check the widget's Name property before the CSS.
if [ "$(playwright-cli eval "() => String(!!document.querySelector('.mx-name-btnForgotPassword'))" 2>/dev/null | sed -n '2p' | tr -d '"')" != "true" ]; then
  tt_fail "no .mx-name-btnForgotPassword on the anonymous login page. Either the widget was removed or renamed, or the login card was rebuilt without it - a user who forgets their password now has no way in without an administrator."
fi

echo "  the Forgot password? control is present and anonymous-reachable"

# ------------------------------------------- 2. empty username -> validation

# The username box is untouched on a freshly opened page, so this is the
# "clicked the link without typing anything" case.
fp_click_forgot
sleep 2

if ! fp_wait_for_body "Enter your username or email" 10; then
  tt_fail "clicking Forgot password? with an empty username produced no field validation. ACT_Password_Forgot is supposed to return validation feedback on LoginHelper/Username before doing anything else."
fi

# The important half: it must not ALSO claim to have sent something.
if [ "$(fp_body_matches "$CONFIRM_RE")" = "true" ]; then
  tt_fail "an empty username produced the 'temporary password has been sent' confirmation. The flow is reporting a send it cannot have made."
fi

echo "  empty username -> field validation, and no false claim of a send"

# --------------------------------- 3. unknown identifier -> generic confirmation

fp_open

# fill does not commit a Mendix input - only blur does - so use the committing
# helper. Without it the microflow reads an empty Username and this test would
# silently re-run case 2.
tt_fill_commit "input.form-control[type=text]" "$UNKNOWN"

fp_click_forgot

if ! fp_wait_for_body "$CONFIRM_RE" 20; then
  tt_fail "an unknown identifier produced no confirmation message. It must be answered exactly as a real one is - anything else (an error, silence, 'no such user') tells an anonymous visitor whether an account exists."
fi

# And the confirmation must not hand the submitted value back. Echoing it is not
# an oracle by itself, but it is how one creeps in - the next step from echoing
# the input is qualifying it.
echoed="$(playwright-cli eval "() => { const all=[...document.querySelectorAll('div,p,span')].filter(e => /temporary password/i.test(e.innerText||'')); const el=all[all.length-1]; if(!el) return 'nomessage'; return (el.innerText||'').indexOf('$UNKNOWN') >= 0 ? 'echoed' : 'clean'; }" 2>/dev/null | _tt_eval_str)"

case "$echoed" in
  clean) ;;
  echoed)  tt_fail "the confirmation message repeats the submitted identifier back. Keep the response free of anything derived from the input." ;;
  *)       tt_fail "could not read the confirmation message back to check it ($echoed)" ;;
esac

tt_clear_dialogs 6 >/dev/null 2>&1 || true

echo "  unknown identifier -> the same generic confirmation, with no echo of the input"
echo "PASS: verify-forgot-password-link - link present anonymously; blank input validates; unknown identifier answered generically"
