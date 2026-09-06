#!/usr/bin/env bash
# verify-anon-token-value-gate.test.sh
#
# tt-timeout: 5m
#
# A customer-approval token of the RIGHT LENGTH but the wrong value is refused.
#
# WHY THIS EXISTS. /p/customer-approval/<token> is the app's only unauthenticated
# write path: whoever reaches the page behind it can approve other people's hours
# with no login. Main.NAV_Email_RecieveToken guards it with two conditions -- the
# token must be exactly 44 characters AND must resolve to a Main.ApprovalToken row
# whose TokenStatus is Active -- and until this step existed the suite only ever
# tested the first of them. suites/10-smoke/verify-anon-bad-token.test.sh sends
# "not-a-valid-token", 21 characters, which is turned away by the length check
# before the lookup is ever reached.
#
# So the second condition -- the one that actually distinguishes a real customer
# from a stranger -- had no test at all. A regression that dropped the lookup, took
# the first row it found, or compared on a prefix would leave every existing token
# test green while making the approval surface reachable by anyone who can type 44
# characters. That is the hole this closes, and it is the same hole the remediation
# plan names: "Currently only a 44-char length gate is tested."
#
# WHAT IT SENDS. Four tokens, each exactly 44 characters so that every one of them
# clears the length check and is judged on its VALUE:
#
#   random    a fresh URL-safe string, regenerated every run -- the realistic guess,
#             and fresh so a pass can never be an artefact of one cached string;
#   zeros     44 '0' characters -- the shape an uninitialised or defaulted field has;
#   numeric   44 digits -- a different character class from a real token, which
#             catches a gate that validates the alphabet instead of the value;
#   xpath     an XPath-injection payload, padded to exactly 44 characters. Mendix
#             parameterises its retrieves, so this is expected to be refused for the
#             same boring reason as the others and is a STANDING GUARD rather than a
#             live suspicion: if the token were ever spliced into a query instead of
#             compared as a value, "or string-length(Token)>0" would match a real
#             row and the approval page would open. Nothing else in the suite would
#             notice that.
#
# WHAT IS ASSERTED FOR EACH. The assertion is deliberately POSITIVE-first, because
# "the approval page did not appear" is also what a broken route, a 404 or a dead
# browser looks like:
#
#   1. Main.Customer_LinkInvalid rendered -- .mx-name-textLinkInvalidHeading is
#      present. This is the app reaching its refuse branch, not merely failing to
#      reach the accept one, and it is what fails if the deep link stops working.
#   2. The approval surface is absent -- neither .mx-name-galPendingEntries nor
#      .mx-name-btnCustomerApprove exists.
#   3. The session still holds ONLY Anonymous, read from mx.session.sessionData
#      (the server's own answer). A forged token must not confer anything.
#   4. No error dialog and no error text. The refusal is a designed branch; a stack
#      trace reaching the browser would be a different bug wearing the same "did not
#      get in" clothes, and for the injection candidate it would be the interesting
#      half of the result.
#
# WHY THE ABSENCE CHECKS ARE NOT VACUOUS. An absence assertion on a selector that no
# longer exists anywhere cannot fail, which is this suite's most expensive historical
# defect. So before asserting anything, this step requires that both selectors it
# expects NOT to see are still referenced by the specs that DO expect to see them
# (suites/30-approval, lib/). If a Studio Pro rename retires one, this fails and says
# so rather than passing on a selector that stopped meaning anything.
#
# LIMITS, STATED. This proves an unissued token is refused. It does NOT prove that a
# genuine token is accepted -- that is suites/30-approval/verify-customer-token-approve
# -- and it cannot prove refusal of a token that is one character off a REAL, ACTIVE
# one, because obtaining a live token means driving the mail flow, and a mutated dead
# token would be refused on its STATUS rather than on its value, which answers a
# different question by accident.
#
# Reads only. Anonymous throughout. Creates nothing, changes nothing, consumes no
# fixture data, and is safe to run any number of times in any order. It DOES clear
# cookies, so like its neighbours in this directory it must not sit between a login
# and an assertion that depends on it.
#
# Env:
#   TT_BASE_URL   app origin (no trailing slash)
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

# The length Main.NAV_Email_RecieveToken demands. Every candidate must be exactly
# this, or the test silently degrades into a second copy of verify-anon-bad-token.
TOKEN_LEN=44

INVALID_SEL='.mx-name-textLinkInvalidHeading'
APPROVAL_SELS='.mx-name-galPendingEntries .mx-name-btnCustomerApprove'

# ------------------------------------------- 0. keep the absence checks meaningful
# Both selectors below are asserted ABSENT further down. An absent selector that no
# part of the app renders any more would make those assertions unfalsifiable, so
# require that the specs which drive the real approval surface still name them.
for sel in $APPROVAL_SELS; do
  if ! grep -rqF -- "$sel" "$TT_ROOT/suites/30-approval" "$TT_ROOT/lib"; then
    tt_fail "'$sel' is no longer referenced by suites/30-approval or lib/, so asserting its ABSENCE here proves nothing. It was probably renamed in Studio Pro -- retarget this step and the approval specs together."
  fi
done
echo "  absence checks are live: the approval specs still name $APPROVAL_SELS"

# --------------------------------------------------------- 1. build the candidates
# Regenerated per run. /dev/urandom is fed through tr -dc so the result is URL-safe
# without any escaping, and the length is asserted below rather than assumed.
rand_token() { head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$TOKEN_LEN"; }
num_token()  { head -c 256 /dev/urandom | od -An -tu1 | tr -dc '0-9'   | cut -c1-"$TOKEN_LEN"; }

T_RANDOM="$(rand_token)"
T_NUMERIC="$(num_token)"
T_ZEROS="$(printf '0%.0s' $(seq 1 "$TOKEN_LEN"))"
# Exactly 44 characters. The run of zeros after '>' is padding: it holds the payload
# at the required length without changing what the expression would mean if it were
# ever evaluated. Do not "tidy" it back to '>0' -- that is 38 characters, would be
# turned away by the length check, and would test nothing.
T_XPATH="' or string-length(Token)>0000000 or Token='"

# percent-encode everything a path segment should not carry literally. '%' first, or
# it would re-encode the escapes the later rules introduce.
urlenc() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e "s/'/%27/g" -e 's/ /%20/g' \
                         -e 's/>/%3E/g' -e 's/</%3C/g' -e 's/(/%28/g' -e 's/)/%29/g' \
                         -e 's/"/%22/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's|/|%2F|g'
}

# ------------------------------------------------------------------ 2. the probe

# probe_token <label> <raw-token> -- navigate anonymously and report the verdict.
# Echoes one of: refused | reached-approval | no-page | error:<detail>
# The observation line goes to stderr: it is diagnostic context, not test output.
probe_token() {
  local label="$1" raw="$2" enc i state
  enc="$(urlenc "$raw")"

  playwright-cli goto "$TT_BASE/p/customer-approval/$enc" >/dev/null 2>&1

  # Poll. Mendix long-polls, so nothing here can wait on network idle, and the
  # refuse branch is a page transition rather than an immediate render. Stop as soon
  # as either destination has appeared; a run that never settles falls through with
  # whatever it last saw, which the caller reports as no-page.
  state=""
  for i in $(seq 1 25); do
    state="$(playwright-cli eval "() => { const inv = !!document.querySelector('$INVALID_SEL'); const gal = !!document.querySelector('.mx-name-galPendingEntries'); const app = !!document.querySelector('.mx-name-btnCustomerApprove'); const txt = document.body ? document.body.innerText : ''; const err = /an error occurred|unexpected error|stack trace/i.test(txt); const dlg = !!document.querySelector('.mx-dialog, [role=dialog]'); const roles = (typeof mx !== 'undefined' && mx.session && mx.session.sessionData && mx.session.sessionData.roles) || null; return [inv, gal, app, err, dlg, JSON.stringify(roles)].join('~'); }" 2>/dev/null | _tt_eval_str)"
    case "$state" in
      true~*)  break ;;
      *~true~*) break ;;
    esac
    sleep 1
  done

  local inv gal app err dlg roles
  IFS='~' read -r inv gal app err dlg roles <<PROBE
$state
PROBE

  echo "  [$label] invalid-page=${inv:-?} approval-gallery=${gal:-?} approve-button=${app:-?} error=${err:-?} dialog=${dlg:-?} roles=${roles:-?}" >&2

  # The approval surface is the one outcome that must never happen.
  if [ "$gal" = "true" ] || [ "$app" = "true" ]; then
    echo "reached-approval"; return
  fi
  # An error page is not a refusal -- say which one it was.
  if [ "$err" = "true" ] || [ "$dlg" = "true" ]; then
    echo "error:the app surfaced an error rather than the invalid-link page"; return
  fi
  if [ "$inv" != "true" ]; then
    echo "no-page"; return
  fi
  # No forged token may confer a role.
  case "$roles" in
    '["Anonymous"]') ;;
    *) echo "error:the session holds ${roles:-nothing} after a forged token, not [\"Anonymous\"]"; return ;;
  esac
  echo "refused"
}

# --------------------------------------------------------------------- 3. run them
playwright-cli cookie-clear >/dev/null 2>&1

fails=0
for cand in random zeros numeric xpath; do
  case "$cand" in
    random)  raw="$T_RANDOM" ;;
    zeros)   raw="$T_ZEROS" ;;
    numeric) raw="$T_NUMERIC" ;;
    xpath)   raw="$T_XPATH" ;;
  esac

  # The whole point is that the token clears the length check. A candidate that does
  # not is a bug in this script, not a finding about the app.
  if [ "${#raw}" -ne "$TOKEN_LEN" ]; then
    tt_fail "candidate '$cand' is ${#raw} characters, not $TOKEN_LEN -- it would be turned away by the length check and this step would re-prove verify-anon-bad-token instead of the value gate"
  fi

  verdict="$(probe_token "$cand" "$raw")"
  case "$verdict" in
    refused)
      echo "  $cand: refused -- the invalid-link page rendered and the session is still anonymous" ;;
    reached-approval)
      echo "FAIL: a forged $TOKEN_LEN-character token ('$cand') REACHED THE CUSTOMER APPROVAL SURFACE."
      echo "      /p/customer-approval/ accepted a token that was never issued, so anyone able to"
      echo "      type $TOKEN_LEN characters can approve other people's timesheets with no login."
      echo "      The gate is Main.NAV_Email_RecieveToken: the token must resolve to a"
      echo "      Main.ApprovalToken row with TokenStatus Active, not merely be the right length."
      fails=$((fails+1)) ;;
    no-page)
      echo "FAIL: neither the invalid-link page nor the approval page rendered for '$cand'."
      echo "      This step cannot report a refusal it did not see -- the deep link route itself"
      echo "      may be broken, which would also make verify-anon-bad-token's pass meaningless."
      fails=$((fails+1)) ;;
    error:*)
      echo "FAIL: '$cand' -- ${verdict#error:}"
      fails=$((fails+1)) ;;
    *)
      echo "FAIL: '$cand' produced an unrecognised verdict [$verdict]"
      fails=$((fails+1)) ;;
  esac
done

[ "$fails" -eq 0 ] || exit 1
echo "PASS: verify-anon-token-value-gate -- four forged $TOKEN_LEN-character tokens (random, zeros, numeric, xpath-injection) were each refused to the invalid-link page with the session still anonymous"
