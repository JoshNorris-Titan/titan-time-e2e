#!/usr/bin/env bash
# verify-helper-selftest.test.sh
#
# Proves that the suite's most-used helpers are CAPABLE OF FAILING.
#
# WHY THIS EXISTS. tt_click_text sits under every HR and Titan-Manager tab switch in
# the suite. For a long time it could not fail: it grepped the raw playwright-cli
# output for "ok", and the echoed JS snippet contains `return 'ok'`, so a caption
# that did not exist still "clicked" and the test then asserted against whatever tab
# happened to already be open. Nothing went red. An audit, not a test run, found it.
#
# A green suite only means something if its helpers can go red. This test asserts
# that directly, so the property is checked on every run instead of rediscovered by
# the next audit. verify-no-echo-trap.test.sh guards the same class of bug
# statically; this is the runtime half.
#
# APP-INDEPENDENT BY DESIGN. The positive control injects its own clickable element
# into the current page rather than depending on a real caption, so this test does
# not break when a dashboard is redesigned, needs no login, and cares about no
# particular page — only that a browser session is open.
#
# Env: none beyond the shared session opened by run-tests.sh.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

MARK="__TT_SELFTEST_TARGET__"
MISSING="__TT_SELFTEST_NO_SUCH_CAPTION__"
fails=0

note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

# ------------------------------------------------------------------ 1. _tt_eval_str
# Everything else here depends on the result decoder being sane.
got="$(playwright-cli eval "() => 'de\"co\$ded'" 2>/dev/null | _tt_eval_str)"
if [ "$got" = 'de"co$ded' ]; then
  note "1 _tt_eval_str decodes a quoted result"
else
  bad "1 _tt_eval_str returned [$got], expected [de\"co\$ded]"
fi

# --------------------------------------------------------- 2. tt_click_text POSITIVE
# Inject a clickable element and confirm tt_click_text both reports success AND
# actually dispatched a click. Reporting success without clicking is the exact
# failure mode this file exists to catch, so asserting the side effect matters more
# than asserting the return code.
playwright-cli eval "() => { const d=document.createElement('div'); d.id='ttSelfTest'; d.textContent='$MARK'; d.style.cursor='pointer'; d.onclick=function(){ window.__ttSelfTestClicked=1; }; document.body.appendChild(d); return 'added'; }" >/dev/null 2>&1

if ( tt_click_text "$MARK" "helper self-test" ) >/dev/null 2>&1; then
  landed="$(playwright-cli eval "() => String(window.__ttSelfTestClicked === 1)" 2>/dev/null | _tt_eval_str)"
  if [ "$landed" = "true" ]; then
    note "2 tt_click_text clicked a real element and the click landed"
  else
    bad "2 tt_click_text reported success but no click reached the element"
  fi
else
  bad "2 tt_click_text could not click an element that exists and is cursor:pointer"
fi

# --------------------------------------------------------- 3. tt_click_text NEGATIVE
# The headline assertion: a caption that cannot exist must NOT succeed.
if ( tt_click_text "$MISSING" "helper self-test" ) >/dev/null 2>&1; then
  bad "3 tt_click_text SUCCEEDED on a caption that does not exist — it cannot fail," \
      "so every tab switch in the suite is unverified (see lib/_login.sh)"
else
  note "3 tt_click_text fails on a missing caption"
fi

# ------------------------------------------------------------------------- 4. tt_fail
# tt_click_text signals failure through tt_fail; if that stopped exiting non-zero,
# test 3 would pass for the wrong reason.
if ( tt_fail "deliberate" ) >/dev/null 2>&1; then
  bad "4 tt_fail returned success — every helper that reports errors through it is blind"
else
  note "4 tt_fail exits non-zero"
fi

# ------------------------------------------------------- 5. _tt_poll_in_page
# The waiting primitive behind tt_wait_for and tt_wait_text, and so behind ~39 call
# sites. It replaced a bash polling loop with a single in-page async loop, which
# moved the sentinel INTO the snippet - `return 'Y'` is now a literal in the source
# playwright-cli echoes back. Decoded through _tt_eval_str that is fine; grepped raw
# it would match the echo and the wait could never fail, which is precisely the bug
# tests 2 and 3 above exist for. So assert the property directly, on the primitive.
#
# Budgets here are deliberately tiny (1 legacy round = 4s) to keep this cheap: the
# point is that the two outcomes are reachable, not how patient the default is.
if _tt_poll_in_page "true" 1; then
  note "5a _tt_poll_in_page returns success on a condition that is already true"
else
  bad "5a _tt_poll_in_page FAILED on a trivially true condition - every tt_wait_* call is now broken"
fi

# The headline half. If this ever reports success, tt_wait_for and tt_wait_text can
# no longer fail and every wait in the suite is decoration.
if _tt_poll_in_page "false" 1; then
  bad "5b _tt_poll_in_page SUCCEEDED on a condition that is never true - it cannot" \
      "fail, so tt_wait_for/tt_wait_text are blind (see lib/_login.sh)"
else
  note "5b _tt_poll_in_page fails on a condition that never comes true"
fi

# Returning EARLY is the whole reason for polling in-page rather than sleeping. A
# version that ignored the condition and always burned its budget would satisfy 5a
# and 5b both, so check the timing too: true at ~2s must not take the 4s budget.
playwright-cli eval "() => { window.__ttPollMark = Date.now(); return 'set'; }" >/dev/null 2>&1
_poll_t0=$(date +%s%N)
_tt_poll_in_page "window.__ttPollMark && (Date.now() - window.__ttPollMark) > 2000" 1
_poll_rc=$?
_poll_ms=$(( ($(date +%s%N) - _poll_t0) / 1000000 ))
# Upper bound allows one process launch (~1.2s local, ~2.6s from CI) on top of the
# 2s the condition itself needs; the 4s in-page budget would land well past it.
if [ "$_poll_rc" -eq 0 ] && [ "$_poll_ms" -ge 2000 ] && [ "$_poll_ms" -lt 8000 ]; then
  note "5c _tt_poll_in_page returns when the condition comes true (${_poll_ms}ms), not at the budget"
else
  bad "5c _tt_poll_in_page rc=$_poll_rc after ${_poll_ms}ms - expected success between 2000 and 8000ms;" \
      "it is not reacting to the condition"
fi

# ------------------------------------------------------------------------- cleanup
playwright-cli eval "() => { const d=document.getElementById('ttSelfTest'); if(d) d.remove(); window.__ttSelfTestClicked=undefined; window.__ttPollMark=undefined; return 'removed'; }" >/dev/null 2>&1

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-helper-selftest — $fails helper propert$([ "$fails" -eq 1 ] && echo y || echo ies) not satisfied."
  echo "      A helper that cannot fail makes every test that uses it meaningless,"
  echo "      so treat this as higher priority than any single failing scenario."
  exit 1
fi

echo "PASS: verify-helper-selftest — decoder, click helper (positive + negative), tt_fail and the wait primitive all behave"
