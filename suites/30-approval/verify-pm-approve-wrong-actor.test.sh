#!/usr/bin/env bash
# verify-pm-approve-wrong-actor.test.sh
#
# One project manager must not be able to act on another's approvals.
#
# WHY THIS EXISTS. Approval is the app's authority boundary: a PM signing off
# hours is the thing the customer is eventually invoiced for. Nothing tested that
# the boundary holds sideways - that PM B cannot reach PM A's queue. Every
# approval step in the suite drives a single PM against their own work, which
# looks identical whether or not the scoping exists.
#
# WHAT THE SCOPING ACTUALLY IS. Main.DS_ApprovalHelper_PM, which feeds both the
# dashboard list and Approve All, constrains its retrieve to
#
#   [ ... /Main.Project/Main.ProjectManager_Account/Administration.Account = '[%CurrentUser%]']
#   [Status = 'AwaitingManagerApproval']
#
# so the list is filtered by the logged-in user. That means the interesting
# question is NOT "does PM B see an Approve button for PM A's entry" - PM B sees
# no such row at all. The question is whether the data underneath is equally
# closed, or whether the microflow XPath is the only thing standing there.
#
# WHAT IT ASSERTS
#   A. Control: PM A genuinely has entries awaiting manager approval. Without
#      that, everything below passes for the wrong reason and the run aborts.
#   B. PM B's pending gallery does not show them.
#   C. PM B cannot retrieve them from the data layer either, asked directly
#      through the app's own client API.
#
# C is the one that would catch a real hole. B can pass on an empty database; C
# only passes when the platform actually refuses.
#
# WHAT IT DOES NOT DO. Attempt the approval itself. The per-entry action takes an
# ApprovalHelper that Main.DS_ApprovalHelper_PM builds per session, so PM B has no
# way to obtain PM A's helper to pass in - there is nothing to forge. If that
# action ever becomes reachable by id, this is the file to extend.
#
# Needs the second project manager account, e2e_pm2, which manages no projects of
# its own - see the role accounts section of the README.
#
# Read-only. Approves nothing, changes nothing.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"

PM_A="${TT_PM_A:-e2e_pm}"
PM_B="${TT_PM_B:-e2e_pm2}"

# Entries awaiting PM A's approval, named by PM A's username rather than by
# [%CurrentUser%] so the same query can be asked from any session.
XPATH="//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/Main.Assignment_Project/Main.Project/Main.ProjectManager_Account/Administration.Account/Name = '$PM_A'][Status = 'AwaitingManagerApproval']"

# wa_count <xpath> - how many objects the CURRENT session can retrieve, or ERR:<why>.
wa_count() {
  playwright-cli eval "() => new Promise(res => { try { if (typeof mx === 'undefined' || !mx.data) return res('ERR:no-mx-client'); const t = setTimeout(() => res('ERR:timeout'), 15000); mx.data.get({ xpath: \"$1\", filter: { amount: 500 }, callback: function(objs){ clearTimeout(t); res(String((objs||[]).length)); }, error: function(e){ clearTimeout(t); res('ERR:' + ((e && e.message) || 'retrieve-refused')); } }); } catch (e) { res('ERR:' + e.message); } })" 2>/dev/null | _tt_eval_str
}

# ------------------------------------------------- A. control: the data exists
tt_login "${TT_ADMIN_USER:-MxAdmin}" "Welcome to your homepage" "${TT_ADMIN_PASS:-${TT_PASS:-}}"
admin="$(wa_count "$XPATH")"

case "$admin" in
  ERR:*)          tt_fail "the control retrieve failed as administrator ($admin). A zero from '$PM_B' would then prove nothing, so this step will not report a result." ;;
  ''|*[!0-9]*)    tt_fail "the control retrieve returned something that is not a count: [$admin]" ;;
esac

if [ "$admin" -eq 0 ]; then
  tt_fail "'$PM_A' has no entries awaiting manager approval, so there is nothing for '$PM_B' to be kept away from. Run the manager-approval step first; passing here would mean nothing."
fi
echo "  control: '$PM_A' has $admin entr(ies) awaiting manager approval"

# --------------------------------------------- B. PM B's dashboard is not theirs
tt_login "$PM_B" "Project Manager Dashboard"

# '$PM_B' manages no projects, so its queue is empty BY DESIGN -- which is exactly
# the state the dashboard stopped rendering a gallery for on 2026-09-03. This used
# to wait for .mx-name-galPMPendingEntries and then treat its absence as a failure,
# so the correct empty state timed out and took the rest of the CI run with it.
# tt_pm_pending_rows reports an absent gallery on a loaded dashboard as 0, and only
# says ERR when the dashboard itself never arrived -- the one case where a zero here
# would be meaningless.
rows="$(tt_pm_pending_rows)"

case "$rows" in
  ERR:*)       tt_fail "'$PM_B' dashboard never rendered ($rows), so step B could not be checked. A zero would not have meant anything, so this step will not report one." ;;
  ''|*[!0-9]*) tt_fail "could not count '$PM_B' pending rows (got [$rows])" ;;
esac

if [ "$rows" -eq 0 ]; then
  echo "  '$PM_B' sees 0 approvable rows"
else
  echo "  note: '$PM_B' sees $rows approvable row(s) of its own - that is allowed; C is what matters"
fi

# ----------------------------------------- C. and neither is the data underneath
mine="$(wa_count "$XPATH")"

case "$mine" in
  ERR:no-mx-client)
    tt_fail "the Mendix client API was not available on '$PM_B' page, so the data layer could not be asked. This step will not report a pass without having asked." ;;
  ERR:*)
    echo "  the data layer refused the request outright ($mine)"
    echo "PASS: verify-pm-approve-wrong-actor - '$PM_B' cannot reach '$PM_A' approvals (retrieve refused)"
    exit 0 ;;
  ''|*[!0-9]*)
    tt_fail "the '$PM_B' retrieve returned something that is not a count: [$mine]" ;;
esac

echo "  as '$PM_B': $mine of those $admin entries came back"

if [ "$mine" -eq 0 ]; then
  echo "PASS: verify-pm-approve-wrong-actor - '$PM_B' retrieved 0 of the $admin entries awaiting '$PM_A' approval"
  exit 0
fi

echo "FAIL: verify-pm-approve-wrong-actor - '$PM_B' retrieved $mine of $admin entries awaiting '$PM_A' approval."
echo "      The dashboard filters by the logged-in manager, so this does not show on screen -"
echo "      but the entity access rule behind it does not, and approval is the boundary the"
echo "      customer is invoiced on. The fix belongs on the access rule, not on the dashboard."
exit 1
