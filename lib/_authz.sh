#!/usr/bin/env bash
# Shared helpers for the negative-authorization suite (suites/85-security).
#
# WHAT THIS IS FOR. Every other spec in this suite drives the app through its
# screens, and a screen only ever shows you what it was built to show you. That
# makes the whole suite blind to the security model: if a role were granted
# something it should not have, no page would start rendering it, so no test
# would notice. These helpers ask the DATA LAYER directly, as an ordinary
# logged-in user, using the client API the app itself uses -- the same technique
# suites/20-consultant/verify-consultant-data-isolation.test.sh already uses, and
# the only one that can see a grant nothing has drawn a screen for yet.
#
# WHY NOT PAGE ACCESS. The obvious shape for this ("open a page the role may not
# open, expect a refusal") cannot be written against this app. mx.ui.openForm was
# removed in the Mendix 11 React client -- mx.ui exposes openForm2 instead, whose
# arguments are undocumented and which rejects with the SAME
# "Cannot read properties of undefined" for an allowed page and a forbidden one,
# because it fails on its own argument shape long before it reaches an access
# check. A denial test built on it would have passed on every pair, allowed and
# denied alike. Entity access is the surface that has an honest answer.
#
# Sourcing: these build on lib/_login.sh, which the spec must source first.
#
# Env: none of its own.
# ---------------------------------------------------------------------------

# tt_authz_count <xpath> — how many objects the CURRENT session can retrieve.
#
# Echoes a number, or ERR:<reason>. mx.data.get is the client API the app itself
# uses; entity access is applied to it exactly as to any other request, which is
# the whole point of asking this way. A refused retrieve (ERR:) and a zero count
# are BOTH denials as far as Mendix is concerned -- which of the two you get
# depends on whether the role has no rule at all or a rule that matches no rows --
# so callers should treat them alike and say which one they saw.
#
# The amount cap is deliberate. These queries are unconstrained (`//Main.X`) and
# run against a shared environment; 200 is far more than any assertion here needs
# and keeps a large table from turning a denial check into a slow one.
tt_authz_count() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t = setTimeout(() => res('ERR:timeout'), 15000); mx.data.get({ xpath: \"$1\", filter: { amount: 200 }, callback: function(objs){ clearTimeout(t); res(String((objs||[]).length)); }, error: function(e){ clearTimeout(t); res('ERR:' + ((e && e.message) || 'retrieve-refused')); } }); } catch (e) { res('ERR:' + e.message); } })" 2>/dev/null | _tt_eval_str
}

# tt_authz_roles — the module roles the CURRENT session holds, as a JSON array.
#
# mx.session.sessionData.roles is the server's own answer, delivered with the
# session, so it is not a guess made from what the page happens to render. It is
# what makes a denial attributable: "the consultant saw nothing" means something
# quite different once you can also say the session really did hold Consultant and
# not, say, an expired anonymous session that would see nothing either way.
tt_authz_roles() {
  playwright-cli eval "() => JSON.stringify((mx.session && mx.session.sessionData && mx.session.sessionData.roles) || null)" 2>/dev/null | _tt_eval_str
}

# tt_authz_expect_count <label> <xpath> — a count, or tt_fail if it is not one.
#
# Wraps tt_authz_count for the CONTROL half of a test, where an ERR: or a
# non-numeric answer means the question was never actually asked and no verdict
# can be reported. Assertions about a denial want the raw helper instead, because
# there ERR: is a legitimate pass.
tt_authz_expect_count() {
  local label="$1" xpath="$2" n
  n="$(tt_authz_count "$xpath")"
  case "$n" in
    ERR:*)       tt_fail "$label: the retrieve failed ($n), so this step cannot report a result" ;;
    ''|*[!0-9]*) tt_fail "$label: the retrieve returned something that is not a count: [$n]" ;;
  esac
  printf '%s' "$n"
}

# tt_authz_anonymous — drop the session and land on the app as an anonymous user.
#
# cookie-clear alone is not enough against a live Mendix session (the session
# cookie is httpOnly and the runtime will re-issue), so this also waits for the
# client to come back up and confirms the session really is anonymous before
# returning. Echoes the roles it ended up with so a caller can assert on them;
# tt_fail's if the client never loaded, because every assertion that follows
# would otherwise read as "anonymous can see nothing" when the truth is that
# nothing was asked.
tt_authz_anonymous() {
  local i roles
  playwright-cli cookie-clear >/dev/null 2>&1
  playwright-cli goto "$TT_BASE/" >/dev/null 2>&1
  for i in $(seq 1 20); do
    roles="$(tt_authz_roles)"
    case "$roles" in
      '['*) printf '%s' "$roles"; return 0 ;;
    esac
    sleep 1
  done
  tt_fail "the Mendix client never came up as an anonymous session at $TT_BASE/ (last answer: [${roles:-nothing}])"
}

# ---------------------------------------------------------------------------
# THE WRITE SIDE
#
# Everything above asks what a session can SEE. These ask what it can DO, and the
# difference is not cosmetic: Main.Consultant grants member write over the whole
# entity including Status with no XPath, and Main.ACT_Page_Approve is callable by
# three roles with no actor check in it at all. Neither of those is visible to a
# retrieve, and neither is visible to a page test, because no screen offers the
# button to the wrong person. The only way to ask honestly is to make the call.
#
# THE SHAPE IS DELIBERATELY DIFFERENT FROM THE READ SIDE. For a retrieve, ERR: and
# 0 are both denials and a caller is told to treat them alike. A write has no zero:
# it either happened or it did not, and "no error" is not proof it was refused --
# it is proof of the opposite. So every one of these returns a discriminated
# sentinel, and a test that wants to prove a refusal must ALSO read the value back
# as somebody entitled to see it. tt_authz_readback exists for that half.
#
# TWO CONTROLS, NOT ONE. A refusal only means something when the same call is known
# to succeed for somebody. An ERR: from a denied role proves nothing on its own --
# a typo'd entity name, a validation rule, a stale session and a genuine access
# denial all arrive looking identical. Run the positive control first, with
# tt_authz_expect_ok, and only then assert the denial. This is the inverse of
# verify-tt737-null-startdate-heals, which treats ERR: as a SETUP failure for the
# same reason seen from the other side.
#
# AND THE REASON THAT IS NOT OPTIONAL: THE ERROR STRING TELLS YOU NOTHING. Measured
# against dev on 2026-09-17, a refused create and a call to a microflow that does
# not exist BOTH come back as "Internal server error" -- the runtime does not
# distinguish "you may not do this" from "that blew up" or "no such thing" on the
# wire, and it is right not to, because telling an unauthorised caller which one it
# was is itself a disclosure. The practical consequence for every test built on
# these helpers: an ERR: is evidence that the call did not visibly succeed, and
# nothing more. What makes it a finding about ACCESS is the pair around it -- the
# same call succeeding for an entitled session, and a readback proving the value
# did not move. A test that asserts only the ERR: is asserting that something,
# somewhere, went wrong, which a broken fixture satisfies just as well.
# ---------------------------------------------------------------------------

# tt_authz_create <entity> -- try to create and commit one object of <entity>.
#
# Echoes the new object's guid on success, or ERR:create-<why> / ERR:commit-<why>.
# The two are kept apart on purpose: entity-create access and the access that lets
# a commit through are different rules that fail at different points, and a test
# that collapses them cannot say which one held. The object is left behind on
# success -- the caller owns cleaning it up, because only the caller knows whether
# it wanted the thing it just proved it could make.
tt_authz_create() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t = setTimeout(() => res('ERR:timeout'), 15000); mx.data.create({ entity: \"$1\", callback: function(obj){ mx.data.commit({ mxobj: obj, callback: function(){ clearTimeout(t); res(obj.getGuid()); }, error: function(e){ clearTimeout(t); res('ERR:commit-' + ((e && e.message) || 'refused')); } }); }, error: function(e){ clearTimeout(t); res('ERR:create-' + ((e && e.message) || 'refused')); } }); } catch (e) { res('ERR:' + e.message); } })" 2>/dev/null | _tt_eval_str
}

# tt_authz_write <xpath> <attribute> <value> -- try to set one attribute and commit.
#
# Echoes 'ok' on success, ERR:notfound when the xpath matched nothing (which is NOT
# a denial and must not be read as one -- it usually means the fixture is missing),
# or ERR:retrieve-/ERR:set-/ERR:commit-<why>. Follows the idiom that
# verify-tt729-new-customer-save.test.sh already proves works against this app.
#
# A plain 'ok' from a role that should not have been able to do this is the finding.
# So is an ERR: that turns out, on readback, to have written anyway -- which is why
# no caller should stop at this answer.
tt_authz_write() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t = setTimeout(() => res('ERR:timeout'), 15000); mx.data.get({ xpath: \"$1\", filter: { amount: 1 }, callback: function(objs){ if (!objs || !objs.length) { clearTimeout(t); return res('ERR:notfound'); } try { objs[0].set(\"$2\", \"$3\"); } catch (e) { clearTimeout(t); return res('ERR:set-' + (e.message || 'refused')); } mx.data.commit({ mxobj: objs[0], callback: function(){ clearTimeout(t); res('ok'); }, error: function(e){ clearTimeout(t); res('ERR:commit-' + ((e && e.message) || 'refused')); } }); }, error: function(e){ clearTimeout(t); res('ERR:retrieve-' + ((e && e.message) || 'refused')); } }); } catch (e) { res('ERR:' + e.message); } })" 2>/dev/null | _tt_eval_str
}

# tt_authz_action <microflow> [guid] -- try to invoke a microflow from the client.
#
# Echoes 'ok' or 'ok:<result>' when the server ran it, or ERR:action-<why>. With a
# guid it is applied to that object ('selection'), without one it is called bare.
#
# THIS IS THE ONLY WAY TO ASK THE QUESTION THAT MATTERS. A microflow's "May be
# called from the client by" list is a grant, and several in this app carry a status
# guard but no actor guard -- the scoping that makes them look safe lives in the
# DATASOURCE that feeds the page, not in the action. Drive the page and you only
# ever call it the way it was meant to be called; the grant is what an attacker has.
#
# mx.data.action is new ground in this repo -- nothing else here calls it -- so a
# failure that mentions the argument shape rather than access is a bug in the CALL,
# not a finding. Prove the positive control first, always.
tt_authz_action() {
  local mf="$1" guid="${2:-}" params
  if [ -n "$guid" ]; then
    params="{ applyto: 'selection', actionname: \"$mf\", guids: [\"$guid\"] }"
  else
    params="{ actionname: \"$mf\" }"
  fi
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t = setTimeout(() => res('ERR:timeout'), 20000); mx.data.action({ params: $params, callback: function(r){ clearTimeout(t); res(r === undefined || r === null ? 'ok' : 'ok:' + String(r)); }, error: function(e){ clearTimeout(t); res('ERR:action-' + ((e && e.message) || 'refused')); } }); } catch (e) { res('ERR:' + e.message); } })" 2>/dev/null | _tt_eval_str
}

# tt_authz_readback <xpath> <attribute> -- read one attribute as the CURRENT session.
#
# Echoes the value, ERR:notfound, or ERR:<why>. This is the half that catches a
# write which was reported as refused and landed anyway, so it must be run as a
# session entitled to see the truth -- normally the privileged control account, not
# the one whose denial is being tested.
tt_authz_readback() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t = setTimeout(() => res('ERR:timeout'), 15000); mx.data.get({ xpath: \"$1\", filter: { amount: 1 }, callback: function(objs){ clearTimeout(t); if (!objs || !objs.length) return res('ERR:notfound'); const v = objs[0].get(\"$2\"); res(v === undefined || v === null ? '' : String(v)); }, error: function(e){ clearTimeout(t); res('ERR:' + ((e && e.message) || 'retrieve-refused')); } }); } catch (e) { res('ERR:' + e.message); } })" 2>/dev/null | _tt_eval_str
}

# tt_authz_expect_ok <label> <answer> -- the POSITIVE CONTROL half.
#
# tt_fail unless <answer> is a success sentinel. Use it on the entitled role before
# asserting any denial: without it, an ERR: from the denied role is unattributable.
tt_authz_expect_ok() {
  local label="$1" answer="$2"
  case "$answer" in
    ERR:*) tt_fail "$label: the control call failed ($answer), so no denial below can be attributed to access control" ;;
    '')    tt_fail "$label: the control call returned nothing, so the question was never asked" ;;
  esac
  printf '%s' "$answer"
}

# tt_authz_expect_refused <label> <answer> -- the ASSERTION half.
#
# tt_fail when <answer> is anything but an ERR:. Deliberately strict, and unlike the
# read side there is no second form of denial to allow for: a write that reports
# success did happen. Pair it with tt_authz_readback whenever the write could have
# landed silently.
#
# The four ERR: forms below are NOT denials and are called out separately, because
# each of them is a test that failed to ask its question rather than an app that
# refused to answer it.
tt_authz_expect_refused() {
  local label="$1" answer="$2"
  case "$answer" in
    ERR:no-mx-client) tt_fail "$label: the Mendix client API was not available, so the data layer was never asked" ;;
    ERR:timeout)      tt_fail "$label: the call never came back, which is not a refusal - it is an unanswered question" ;;
    ERR:notfound)     tt_fail "$label: the target did not exist, so nothing was attempted (check the fixture, not the access rule)" ;;
    ERR:*)            printf '%s' "$answer"; return 0 ;;
  esac
  tt_fail "$label: the call SUCCEEDED (answer: [$answer]) - this session was allowed to do something it should not have been"
}
