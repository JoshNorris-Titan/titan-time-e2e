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

# ------------------------------------------------------------------------- cleanup
playwright-cli eval "() => { const d=document.getElementById('ttSelfTest'); if(d) d.remove(); window.__ttSelfTestClicked=undefined; return 'removed'; }" >/dev/null 2>&1

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-helper-selftest — $fails helper propert$([ "$fails" -eq 1 ] && echo y || echo ies) not satisfied."
  echo "      A helper that cannot fail makes every test that uses it meaningless,"
  echo "      so treat this as higher priority than any single failing scenario."
  exit 1
fi

echo "PASS: verify-helper-selftest — decoder, click helper (positive + negative) and tt_fail all behave"
