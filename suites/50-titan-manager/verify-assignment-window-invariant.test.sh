#!/usr/bin/env bash
# No assignment ends before it starts.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS, AND WHY IT IS SHAPED THIS WAY. Main.SUB_AssignmentValidation
# checks StartDate and EndDate for EMPTINESS and nothing else. There is no
# EndDate >= StartDate rule anywhere in the model - grep the flow and the
# comparison simply is not there.
#
# So an inverted range saves cleanly, and then does something worse than erroring:
# RULE_Assignment_Active computes HasStarted as StartDate < weekStart + 7 and
# HasNotEnded as EndDate >= weekStart, so an assignment whose EndDate precedes its
# StartDate satisfies neither for any week. The consultant's timesheet renders
# zero rows, for every week, with no message. Nothing tells them why they cannot
# log time, and nothing tells the person who created it that they made a mistake.
#
# THE OBVIOUS TEST IS THE WRONG ONE. Driving the form with an inverted range and
# asserting a refusal would be permanently red until the rule exists, and a
# permanently-red step in a nightly is worse than no step: it trains people to
# scroll past. This asserts the CONSEQUENCE instead - that no such assignment is
# present - which passes today, keeps passing while the data stays sane, and goes
# red the moment one is created, whether by this suite, by a person, or by an
# import. It is the same defect, caught where it costs something.
#
# WHAT IT ASSERTS, over E2E assignments:
#   A. none has EndDate before StartDate;
#   B. none has an empty StartDate or EndDate - the rule that DOES exist, asserted
#      against the stored data rather than against the form;
#   C. something was examined.
#
# Reads only. Changes nothing.
#
# Consumes: nothing.
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_authz.sh"

fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

OWNED="starts-with(ConsultantName,'E2E ')"

# Read the pairs and compare in shell: Mendix XPath cannot compare two members of
# the same object to each other, so the comparison has to happen here.
windows() {
  playwright-cli eval "() => new Promise(res => { try { const t=setTimeout(()=>res('ERR:timeout'),20000); mx.data.get({ xpath: \"//Main.Assignment[$OWNED]\", filter:{amount:200}, callback:function(o){ clearTimeout(t); res((o||[]).map(a=>{ const s=a.get('StartDate'), e=a.get('EndDate'); return String(a.get('ConsultantName'))+'~'+(s?Number(s):'')+'~'+(e?Number(e):''); }).join('|')); }, error:function(e){ clearTimeout(t); res('ERR:'+((e&&e.message)||'refused')); } }); } catch(e){ res('ERR:'+e.message); } })" 2>/dev/null | _tt_eval_str
}

tt_login "e2e_tm" "Add Customer"
note "session roles: $(tt_authz_roles)"

W="$(windows)"
case "$W" in ERR:*) tt_fail "could not read E2E assignments ($W)" ;; esac
[ -n "$W" ] || tt_fail "no E2E assignment exists, so nothing was examined and this step has no verdict to give. suites/00-setup builds them; run the suite in order."

checked=0
IFS='|'
for row in $W; do
  unset IFS
  [ -n "$row" ] || { IFS='|'; continue; }
  who="${row%%~*}"
  rest="${row#*~}"
  s="${rest%%~*}"
  e="${rest##*~}"
  checked=$((checked+1))

  # ------------------------------------------------------------- B. both dates present
  if [ -z "$s" ] || [ -z "$e" ]; then
    bad "B: '$who' has an empty StartDate or EndDate (start='$s' end='$e'). SUB_AssignmentValidation is supposed to refuse that, so this one got past the form."
    IFS='|'; continue
  fi

  # --------------------------------------------------------------- A. the right way round
  if awk -v a="$s" -v b="$e" 'BEGIN{ exit (b+0 >= a+0) ? 0 : 1 }'; then
    :
  else
    bad "A: '$who' ends before it starts (start=$(date -u -d "@$((s/1000))" +%Y-%m-%d 2>/dev/null || echo "$s"), end=$(date -u -d "@$((e/1000))" +%Y-%m-%d 2>/dev/null || echo "$e")). No EndDate >= StartDate rule exists in the model, and RULE_Assignment_Active will render ZERO rows for every week of this assignment with no message to the consultant."
  fi
  IFS='|'
done
unset IFS

# ------------------------------------------------------------------- C. did we look?
[ "$checked" -gt 0 ] || bad "C: no assignment was examined, so this step has no verdict to give"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-assignment-window-invariant — $fails problem(s) across $checked assignment(s)."
  exit 1
fi
echo "PASS: verify-assignment-window-invariant — all $checked E2E assignment(s) have a start, an end, and the two the right way round."
