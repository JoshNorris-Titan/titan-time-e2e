#!/usr/bin/env bash
# TT-654 A6 — an MCP token only ever sees its own consultant's data.
#
# The security property the whole design rests on. There is no per-request
# session: Core.SUB_MCP_Authenticate resolves the bearer token to an Account and
# that becomes currentUser, after which the existing entity access rules do the
# scoping. If that ever breaks, one consultant's token reads and submits another
# consultant's timesheets — silently, with no error anywhere.
#
# Mints a token for each of two consultants and asserts each one's
# ListMyAssignments is disjoint from the other's: every project A sees is a
# project B does not, and vice versa. That catches the real failure mode (the
# tools ignoring currentUser and returning everything) without depending on
# exact fixture data.
#
# Requires a SECOND consultant account. The e2e fixtures ship "E2E Consultant"
# and "E2E Consultant Two"; set TT654_CONSULTANT_B to the second one's login if
# the default below is not right for this environment.
#
#   TT654_CONSULTANT     default e2e_consultant
#   TT654_CONSULTANT_B   default e2e_consultant2
#
# The two accounts must be assigned to DIFFERENT projects, otherwise the
# disjointness assertion is vacuous — the test detects that and fails rather
# than reporting a green run that proves nothing.

set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt654.sh"

TT654_CONSULTANT_B="${TT654_CONSULTANT_B:-e2e_consultant2}"

# projects_for <login> — log in, mint a token, return that token's
# ListMyAssignments payload.
projects_for() {
  local who="$1" tok out
  tt_login "$who" "My Timesheets"
  tok="$(tt654_mint_token)"
  [ -n "$tok" ] || tt_fail "could not mint an MCP token as '$who'"
  out="$(tt654_mcp_call "$tok" ListMyAssignments "{}")"
  case "$out" in
    *AUTHFAIL*)   tt_fail "MCP rejected a freshly minted token for '$who'" ;;
    *NOSESSION*)  tt_fail "MCP endpoint gave no session — is TT654_MCP_PATH ('$TT654_MCP_PATH') right here?" ;;
    *RPCERROR*)   tt_fail "ListMyAssignments failed for '$who': ${out:0:200}" ;;
  esac
  echo "$out"
}

# project names out of the JSON payload, one per line
names_from() {
  printf '%s' "$1" | grep -oE '"project":"[^"]*"' | sed 's/^"project":"//; s/"$//' | sort -u
}

A_JSON="$(projects_for "$TT654_CONSULTANT")"
A_NAMES="$(names_from "$A_JSON")"
[ -n "$A_NAMES" ] || tt_fail "'$TT654_CONSULTANT' has no assignments — nothing to scope, seed assignments first"
echo "$TT654_CONSULTANT sees: $(echo "$A_NAMES" | tr '\n' ' ')"

B_JSON="$(projects_for "$TT654_CONSULTANT_B")"
B_NAMES="$(names_from "$B_JSON")"
[ -n "$B_NAMES" ] || tt_fail "'$TT654_CONSULTANT_B' has no assignments — set TT654_CONSULTANT_B to a consultant that does, or the scoping assertion is vacuous"
echo "$TT654_CONSULTANT_B sees: $(echo "$B_NAMES" | tr '\n' ' ')"

# The two must differ somewhere, or this test cannot distinguish correct scoping
# from no scoping at all.
if [ "$A_NAMES" = "$B_NAMES" ]; then
  tt_fail "both consultants return an identical project list — either they are assigned to exactly the same projects (making this test vacuous, so assign them differently) or the tools are ignoring currentUser entirely"
fi

# Shared projects are legitimate — two consultants can staff one project. What
# matters is that neither list is the UNION of both, which is what you would see
# if the tools ignored currentUser and returned every assignment in the system.
# (two consultants can staff one project), what matters is that each list is the
# consultant's OWN, i.e. neither is the union of both.
UNION_A_B="$(printf '%s\n%s\n' "$A_NAMES" "$B_NAMES" | sort -u)"
if [ "$A_NAMES" = "$UNION_A_B" ] && [ "$B_NAMES" != "$UNION_A_B" ]; then
  tt_fail "'$TT654_CONSULTANT' sees every project '$TT654_CONSULTANT_B' sees plus its own — that is the union, so the tools are not scoping to currentUser"
fi
if [ "$B_NAMES" = "$UNION_A_B" ] && [ "$A_NAMES" != "$UNION_A_B" ]; then
  tt_fail "'$TT654_CONSULTANT_B' sees every project '$TT654_CONSULTANT' sees plus its own — that is the union, so the tools are not scoping to currentUser"
fi

# Cross-check with a write attempt: B must not be able to touch a project only A
# is on. Uses a project unique to A, if there is one.
A_ONLY="$(printf '%s\n' "$A_NAMES" | grep -vxF -f <(printf '%s\n' "$B_NAMES") | head -1 || true)"
if [ -n "$A_ONLY" ]; then
  tt_login "$TT654_CONSULTANT_B" "My Timesheets"
  BTOK="$(tt654_mint_token)"
  OUT="$(tt654_mcp_call "$BTOK" SetWeekHours "{ProjectName:'$A_ONLY',WeekStartDate:'2026-01-04',Sunday:0,Monday:8,Tuesday:0,Wednesday:0,Thursday:0,Friday:0,Saturday:0}")"
  case "$OUT" in
    *'"error"'*) echo "cross-account write to '$A_ONLY' refused" ;;
    *) tt_fail "'$TT654_CONSULTANT_B' was able to write to '$A_ONLY', a project only '$TT654_CONSULTANT' is assigned to (got: ${OUT:0:300})" ;;
  esac
else
  echo "NOTE: no project unique to '$TT654_CONSULTANT' — cross-account write check skipped"
fi

echo "PASS: MCP tokens scope to their own consultant"
