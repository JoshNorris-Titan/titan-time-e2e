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
