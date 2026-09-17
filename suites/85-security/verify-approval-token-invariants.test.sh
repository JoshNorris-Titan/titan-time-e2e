#!/usr/bin/env bash
# Every approval token is bounded and attributable — it has an approver and an
# expiry, and no live one has already expired.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. An ApprovalToken is a bearer credential: whoever holds the link
# can see and act on the rows it covers, with no login. Three properties keep that
# tolerable, and none of them is asserted anywhere.
#
#   * ApproverEmail scopes what the token shows. DS_Projects_ByToken filters on it
#     in memory, so a token with no approver email is a link with no scope.
#   * ExpiresAt bounds how long a leaked link stays useful. DS_Projects_ByToken
#     refuses a token past it. A token with no expiry never stops working.
#   * A token that is past ExpiresAt but still marked live is the exact state that
#     refusal exists to catch, and the one a lifetime change is most likely to
#     produce - the window is moving from 30 days to 7.
#
# The suite's token coverage is all about FORGED or CONSUMED tokens
# (verify-anon-bad-token, verify-anon-token-value-gate, verify-token-replay-refused).
# The real-but-unbounded token has never been looked for, and unlike those it is
# not something an attacker has to construct - it is something the app can mint by
# accident.
#
# WHAT IT ASSERTS, over every ApprovalToken the admin session can see:
#   A. none has an empty ApproverEmail;
#   B. none has an empty ExpiresAt;
#   C. none is past its ExpiresAt while its TokenStatus is not Revoked;
#   D. something was examined.
#
# WHY IT RUNS AS ADMIN. Main.ApprovalToken is one of only two entities with a
# genuine data-layer denial for staff roles - that is what verify-role-token-denial
# asserts, and this test must not weaken it by discovering some role that can read
# them. The administrator is the session that legitimately can.
#
# Reads only. Changes nothing.
#
# Consumes: nothing.
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"
# TT_ADMIN_U / TT_ADMIN_P are defined in _testdata.sh, not _login.sh. Sourcing it
# is how this step gets them; spelling the defaults out here instead would bake in
# the local-only fallbacks that must never satisfy a guard on a deployed
# environment.
source "$TT_ROOT/lib/_testdata.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

tokens() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.ApprovalToken\", filter:{amount:300}, callback:function(o){ clearTimeout(t); res((o||[]).map(k=>{ const ex=k.get('ExpiresAt'); return String(k.get('ApproverEmail')||'')+'~'+(ex?Number(ex):'')+'~'+String(k.get('TokenStatus')||''); }).join('|')); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

tt_login "$TT_ADMIN_U" "Welcome to your homepage" "$TT_ADMIN_P"
note "session roles: $(tt_authz_roles)"

T="$(tokens)"
case "$T" in
  ERR:*) tt_fail "the administrator could not read Main.ApprovalToken ($T). That is not a pass - it means this step never asked its question." ;;
esac
[ -n "$T" ] || tt_fail "no ApprovalToken exists, so nothing was examined and this step has no verdict to give. suites/30-approval mints them; run the suite in order."

NOW_MS=$(( $(date -u +%s) * 1000 ))
checked=0
no_email=0
no_expiry=0
stale=0

IFS='|'
for row in $T; do
  unset IFS
  [ -n "$row" ] || { IFS='|'; continue; }
  email="${row%%~*}"
  rest="${row#*~}"
  exp="${rest%%~*}"
  status="${rest##*~}"
  checked=$((checked+1))

  [ -n "$email" ] && [ "$email" != "null" ] || no_email=$((no_email+1))
  if [ -z "$exp" ] || [ "$exp" = "null" ]; then
    no_expiry=$((no_expiry+1))
  elif [ "$exp" -lt "$NOW_MS" ] 2>/dev/null; then
    case "$status" in
      Revoked) : ;;
      *)       stale=$((stale+1)) ;;
    esac
  fi
  IFS='|'
done
unset IFS

# ------------------------------------------------------------------------ A/B/C
[ "$no_email" -eq 0 ] \
  && note "A ok: every token names an approver" \
  || bad "A: $no_email of $checked token(s) have no ApproverEmail. DS_Projects_ByToken scopes what a token shows by that address, so a token without one is a link with no scope."

[ "$no_expiry" -eq 0 ] \
  && note "B ok: every token has an expiry" \
  || bad "B: $no_expiry of $checked token(s) have no ExpiresAt. A bearer link with no expiry never stops working."

[ "$stale" -eq 0 ] \
  && note "C ok: no live token is past its expiry" \
  || bad "C: $stale token(s) are past ExpiresAt and not Revoked. That is the state DS_Projects_ByToken's refusal exists to catch, and the one a lifetime change is most likely to produce - the window is moving from 30 days to 7."

# ------------------------------------------------------------------- D. did we look?
[ "$checked" -gt 0 ] \
  && note "D ok: $checked token(s) examined" \
  || bad "D: no token was examined, so this step has no verdict to give"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-approval-token-invariants — $fails problem(s) across $checked token(s)."
  exit 1
fi
echo "PASS: verify-approval-token-invariants — all $checked token(s) name an approver, carry an expiry, and none is live past it."
