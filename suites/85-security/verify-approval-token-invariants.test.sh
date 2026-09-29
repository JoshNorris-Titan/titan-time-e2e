#!/usr/bin/env bash
# Every approval token is bounded and attributable — it has an approver and an
# expiry, and a freshly minted one lives no longer than the lifetime allows.
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
#   * An ExpiresAt far in the future is a token that is bounded in name only - the
#     state a lifetime change or a date-arithmetic slip is most likely to produce
#     (the window has moved from 30 days to 7).
#
# HOW TOKENS LIVE NOW. Every approval email mints its own token, nothing revokes
# one any more, and a token ends only at its own ExpiresAt. So a token past
# ExpiresAt and not Revoked is simply an expired token - not a defect - and this
# step used to fail on exactly that (its old check C). The nightly
# Core.SUB_Retention_Purge DELETES tokens past ExpiresAt or Revoked, so expired
# rows do not linger either. The refusal of an expired token at the link is
# DS_Projects_ByToken's own XPath ([ExpiresAt > '[%CurrentDateTime%]']); this
# step does not exercise it.
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
#   C. every token minted in the last TT_TOKEN_RECENT_HOURS (default 24 - i.e.
#      this run's, from suites/30-approval) has a LIFETIME, ExpiresAt minus its own
#      createdDate, that is positive and at most TT_TOKEN_MAX_LIFETIME_DAYS
#      (default 7, Core.CONST_ApprovalTokenLifetimeDays' default; set the variable
#      if an environment overrides the constant) plus one hour. The lifetime is
#      measured from the token's own mint, not from now, so a mint with the old
#      30-day window - or any date-arithmetic slip - fails on the day it happens.
#      At least one such token must exist, or C has no verdict and fails.
#      Older tokens are not judged by C: some were minted under the 30-day window
#      and are legitimately still live. They, and expired rows awaiting the purge,
#      are counted and reported, not failed;
#   D. something was examined.
#
# WHY ZERO ROWS STILL FAILS, even though the purge can legitimately empty the
# table on a quiet environment. Within a suite run it cannot: suites/30-approval
# sends customer-approval mail minutes before this step, each mail mints a token,
# nothing revokes it and the purge takes only expired ones - so the tokens this
# run minted are still there. An empty read here therefore means this session
# could not see them (see the access note below), not that there are none. Run
# on its own after a quiet spell, outside the suite, this step can fail on a
# correctly empty table; that is the price of not letting "could not look" read
# as a pass.
#
# RED UNTIL A MODEL-SIDE READER EXISTS (2026-09-29). This step cannot currently
# see a single token, on any environment, and so fails before A-D. Main.ApprovalToken
# has NO access rule for ANY role - Administrator included (the domain model's
# accessRules list is empty, and verify-role-token-denial asserts exactly that for
# consultant, PM, HR, Titan Manager and the administrator). That denial is the
# point: a token is a bearer credential. So no client session can ever read these
# rows, and no role should be given a rule just so this step can look. Measured on
# dev 2026-09-17 and again 2026-09-29: a session holding ["Administrator"] read 0
# rows minutes after suites/30-approval had sent customer-approval mail.
#
# The fix is model-side, and enters the gates at Gate 1: a Test Data action that
# runs in a microflow (which ignores entity access) and reports, per token, only
# ApproverEmail-present, ExpiresAt and createdDate - never the token value. Point
# tokens() at that and A-D below apply unchanged. Until then this step stays red on
# purpose; it is not in ci-skip.txt, because a skipped invariant reads as a kept one.
#
# It still signs in as the administrator because that is the account the eventual
# Test Data action will be granted to, and because this test must not weaken
# verify-role-token-denial by discovering some role that can read tokens.
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
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.ApprovalToken\", filter:{amount:300}, callback:function(o){ clearTimeout(t); res((o||[]).map(k=>{ const ex=k.get('ExpiresAt'); const cr=k.get('createdDate'); return String(k.get('ApproverEmail')||'')+'~'+(ex?Number(ex):'')+'~'+String(k.get('TokenStatus')||'')+'~'+(cr?Number(cr):''); }).join('|')); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

tt_login "$TT_ADMIN_U" "Welcome to your homepage" "$TT_ADMIN_P"
note "session roles: $(tt_authz_roles)"

T="$(tokens)"
case "$T" in
  ERR:*) tt_fail "the administrator could not read Main.ApprovalToken ($T). That is not a pass - it means this step never asked its question." ;;
esac
# A ZERO COUNT IS NOT EVIDENCE OF ABSENCE. tt_authz_count returns 0 both when there
# are no rows and when an access rule matches none, and verify-role-token-denial
# records that Main.ApprovalToken is one of only two entities with a genuine
# data-layer denial - measured on dev 2026-09-17, a session holding ["Administrator"]
# read 0 from this table minutes after a customer-approval mail carrying a token link
# had demonstrably been sent. So an empty answer here says this step could not look,
# NOT that there is nothing to look at, and claiming the latter would be exactly the
# kind of assertion this suite was audited for.
[ -n "$T" ] || tt_fail "this session retrieved no ApprovalToken rows. That is NOT the same as there being none: an access rule that matches nothing reads identically to an empty table, and this entity is access-restricted even for Administrator. Nothing was examined and this step has no verdict to give - which is a gap in what the suite can see, not a pass."

NOW_MS=$(( $(date -u +%s) * 1000 ))
checked=0
no_email=0
no_expiry=0
overlong=0
unborn=0
recent=0
older=0
expired=0
max_life_h=0
MAX_DAYS="${TT_TOKEN_MAX_LIFETIME_DAYS:-7}"
RECENT_H="${TT_TOKEN_RECENT_HOURS:-24}"
MAX_LIFE_MS=$(( MAX_DAYS * 86400000 + 3600000 ))
RECENT_FROM_MS=$(( NOW_MS - RECENT_H * 3600000 ))

IFS='|'
for row in $T; do
  unset IFS
  [ -n "$row" ] || { IFS='|'; continue; }
  IFS='~' read -r email exp status created <<ROW
$row
ROW
  checked=$((checked+1))

  [ -n "$email" ] && [ "$email" != "null" ] || no_email=$((no_email+1))
  if [ -z "$exp" ] || [ "$exp" = "null" ]; then
    no_expiry=$((no_expiry+1))
  else
    [ "$exp" -lt "$NOW_MS" ] 2>/dev/null && expired=$((expired+1))
    # C judges only tokens with a readable createdDate inside the recent window.
    if [ -n "$created" ] && [ "$created" != "null" ] && [ "$created" -ge "$RECENT_FROM_MS" ] 2>/dev/null; then
      recent=$((recent+1))
      life=$(( exp - created ))
      [ $(( life / 3600000 )) -gt "$max_life_h" ] && max_life_h=$(( life / 3600000 ))
      if [ "$life" -le 0 ]; then
        unborn=$((unborn+1))
      elif [ "$life" -gt "$MAX_LIFE_MS" ]; then
        overlong=$((overlong+1))
      fi
    else
      older=$((older+1))
    fi
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

if [ "$recent" -eq 0 ]; then
  bad "C: no token with a readable createdDate was minted in the last ${RECENT_H}h, so no lifetime could be measured. suites/30-approval mints tokens minutes before this step; run the suite in order."
else
  [ "$overlong" -eq 0 ]     || bad "C: $overlong of $recent token(s) minted in the last ${RECENT_H}h live longer than ${MAX_DAYS} day(s) (+1h) from their own mint (longest ${max_life_h}h). The mint used the wrong lifetime - a link that outlives what the window promises."
  [ "$unborn" -eq 0 ]     || bad "C: $unborn of $recent token(s) minted in the last ${RECENT_H}h expire at or before their own createdDate - a link that is dead on arrival."
  [ "$overlong" -eq 0 ] && [ "$unborn" -eq 0 ]     && note "C ok: all $recent token(s) minted in the last ${RECENT_H}h live more than 0 and at most ${MAX_DAYS} day(s) (+1h); longest ${max_life_h}h"
fi
note "info: $older older token(s) not judged by C; $expired token(s) past ExpiresAt awaiting the nightly purge (expected under per-email tokens, not a failure)"

# ------------------------------------------------------------------- D. did we look?
[ "$checked" -gt 0 ] \
  && note "D ok: $checked token(s) examined" \
  || bad "D: no token was examined, so this step has no verdict to give"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-approval-token-invariants — $fails problem(s) across $checked token(s)."
  exit 1
fi
echo "PASS: verify-approval-token-invariants — all $checked token(s) name an approver, carry an expiry, and this run's $recent live no longer than ${MAX_DAYS} day(s)."
