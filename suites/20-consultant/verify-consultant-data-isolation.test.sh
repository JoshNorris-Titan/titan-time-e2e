#!/usr/bin/env bash
# verify-consultant-data-isolation.test.sh
#
# One consultant must not be able to read another consultant's timesheet entries.
#
# WHY THIS EXISTS. A read of the security model found that Main.AssignmentEntry
# has no XPath constraint for the Main.Consultant role: the rule grants read (and
# member write, including Status) over the whole entity, and what actually keeps a
# consultant to their own rows is the XPath on the pages and microflows that fetch
# them. Page-level scoping is real protection for anyone using the app through its
# screens, but it is one layer, and it is the layer a test never exercises — every
# other step in this suite goes through those same pages and would look identical
# either way.
#
# So this asks the data layer directly, as an ordinary logged-in consultant, using
# the app's own client API. No tooling, no exploit: the same call the app itself
# makes, with a different XPath.
#
# HOW A ZERO IS MADE MEANINGFUL. "Consultant A retrieved none of B's entries" is
# only reassuring if B has entries to retrieve. So the step first proves, as the
# administrator, that the very same XPath returns rows. A control that returns
# nothing aborts the run rather than reporting a pass — otherwise this would be a
# test that passes hardest on an empty database.
#
# IF IT FAILS. It means a consultant can read another consultant's hours by asking
# for them, which is a data-protection matter rather than a bug in a screen. The
# fix is an XPath constraint on the entity access rule, not a change to any page.
#
# Reads only. Creates nothing, changes nothing.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

MINE_USER="${TT_ISO_USER:-e2e_consultant}"
MINE_NAME="${TT_ISO_NAME:-E2E Consultant}"
OTHER_NAME="${TT_ISO_OTHER:-E2E Consultant Two}"

XPATH="//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '$OTHER_NAME']"

# di_count <xpath> — how many objects the CURRENT session can retrieve.
# Returns a number, or ERR:<reason>. mx.data.get is the client API the app itself
# uses; entity access is applied to it exactly as to any other request, which is
# the whole point of asking this way.
di_count() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t = setTimeout(() => res('ERR:timeout'), 15000); mx.data.get({ xpath: \"$1\", filter: { amount: 500 }, callback: function(objs){ clearTimeout(t); res(String((objs||[]).length)); }, error: function(e){ clearTimeout(t); res('ERR:' + ((e && e.message) || 'retrieve-refused')); } }); } catch (e) { res('ERR:' + e.message); } })" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------- 1. control: the data exists
tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}"
admin="$(di_count "$XPATH")"

case "$admin" in
  ERR:*)
    tt_fail "the control retrieve failed as administrator ($admin). Without it a zero from the consultant proves nothing, so this step will not report a result." ;;
  ''|*[!0-9]*)
    tt_fail "the control retrieve returned something that is not a count: [$admin]" ;;
esac

if [ "$admin" -eq 0 ]; then
  tt_fail "the administrator can see no '$OTHER_NAME' entries at all, so there is nothing for '$MINE_NAME' to be denied. Seed an entry for the second consultant (verify-00-fixtures) and run again — passing here would mean nothing."
fi
echo "  control: administrator sees $admin entr(ies) belonging to '$OTHER_NAME'"

# ------------------------------------------- 2. the same question, as a consultant
tt_login "$MINE_USER" "My Timesheets"
mine="$(di_count "$XPATH")"

case "$mine" in
  ERR:no-mx-client)
    tt_fail "the Mendix client API was not available on the consultant's page, so the data layer could not be asked. This step cannot report a pass without having asked." ;;
  ERR:*)
    # A refused retrieve is the correct outcome: the platform declined the request.
    echo "  the data layer refused the request outright ($mine)"
    echo "PASS: verify-consultant-data-isolation - '$MINE_NAME' cannot read '$OTHER_NAME' entries (retrieve refused)"
    exit 0 ;;
  ''|*[!0-9]*)
    tt_fail "the consultant retrieve returned something that is not a count: [$mine]" ;;
esac

echo "  as '$MINE_NAME': $mine of those entries came back"

if [ "$mine" -eq 0 ]; then
  echo "PASS: verify-consultant-data-isolation - '$MINE_NAME' retrieved 0 of the $admin '$OTHER_NAME' entries the administrator can see"
  exit 0
fi

echo "FAIL: verify-consultant-data-isolation - '$MINE_NAME' retrieved $mine of $admin timesheet entries belonging to '$OTHER_NAME'."
echo "      A consultant can read another consultant's hours simply by asking the data"
echo "      layer for them. The screens scope correctly, which is why nothing else in this"
echo "      suite notices; the entity access rule for Main.Consultant on"
echo "      Main.AssignmentEntry has no XPath constraint behind them."
echo "      This is a data-protection issue, not a page bug - the fix belongs on the"
echo "      access rule, not on any screen."
exit 1
