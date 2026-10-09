#!/usr/bin/env bash
# What an unauthenticated session can READ, entity by entity, stated as numbers
# rather than assumed.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. verify-anonymous-data-denial asks about the entities Anonymous
# has no rule on at all - Main.ChangeLog, Main.ApprovalToken, Main.ApprovalVisit.
# The anonymous-grants security finding (resolved 2026-09-30; its doc was deleted
# 2026-10-08 and lives in the model repo's git history) recorded unconstrained
# anonymous READ on Main.Timesheet, Customer, Project, Assignment, LineItem and
# AttachmentDocument as well, and this step asks each of those.
#
# THE CUSTOMER-LINK SECURITY CHANGE IS DEPLOYED (c8cb6095). That change (model,
# 2026-09-29) replaced every one of those grants with a rule that admits only rows
# on a project covered by a live Main.ApprovalVisit of the CURRENT session. This
# session never opens an approval link, so it has no visit, and every count below
# must be 0 or refused. Before the deploy this step fails on the entities the old
# grants exposed; after it, it is one of the two acceptance checks for the deploy
# (with B of verify-anon-approve-without-token). The WITH-a-visit half - what a
# session that did open a link may read - is verify-anon-visit-read-scope.
#
# This is deliberately a DIFFERENT question from the signed-in one, and the
# distinction is worth writing down because it has already been investigated and
# settled the other way: for staff roles, ApprovalToken and ChangeLog are the only
# real data-layer denials, and Timesheet/AssignmentEntry/Project/Customer/
# Assignment are readable by every one of them, with isolation enforced by XPath
# on pages and microflows. So a read-denial matrix over core entities for
# signed-in roles is not worth building. For ANONYMOUS it is an entirely different
# matter: there is no page, no session and no user to scope anything to.
#
# WHAT IT ASSERTS. For each entity below, anonymously: a refusal (ERR:) or 0 rows
# passes; any positive count fails and says how many. A control count is taken as
# HR first, so "anonymous saw 0" can be distinguished from "there are 0" - a
# denial proved against an empty table is not a denial at all, and this suite has
# been bitten by exactly that shape.
#
# WHY A POSITIVE COUNT IS A FAILURE AND NOT A NOTE. An anonymous caller reading
# Main.Customer has the client list. Reading Main.Project has the project list.
# Reading Main.AssignmentEntry has everyone's hours. None of that needs a login,
# a token or a page - only the client API the app ships.
#
# Consumes: reads only. Clears cookies - safe here, in 85-security.
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

# The first seven are the original finding. The next three joined with the
# customer-link security change (2026-09-29), which gave each of them a
# visit-scoped anonymous rule: the attachment and expense rows a customer's review
# popup reads. Administration.Account is here because the Anonymous user role lost
# Administration.User in the same change - it held it for no reason any screen
# needed - and a regrant would hand out every login and email address. And
# Main.WeekSelectorHelper is NON-PERSISTABLE, so a retrieve of it can only ever be
# refused (HR's control is refused too, and the line below says so); it is listed so
# that a change making it persistable, or granting it to Anonymous, is noticed.
ENTITIES="Main.Timesheet Main.AssignmentEntry Main.Customer Main.Project Main.Assignment Main.LineItem Main.AttachmentDocument Main.AssignmentAttachment Main.ExpenseReport Main.ExpenseReportDocuments Administration.Account Main.WeekSelectorHelper"

# ---------------------------------------------------------- controls, as an entitled user
tt_login "e2e_hr" "$TT_HR_READY"
note "control session roles: $(tt_authz_roles)"
CONTROLS=""
for e in $ENTITIES; do
  c="$(tt_authz_count "//$e")"
  case "$c" in
    ERR:*)       note "control: $e -> $c (HR cannot read it either; anonymous denial there proves little)" ;;
    ''|*[!0-9]*) note "control: $e -> unreadable [$c]" ;;
    *)           note "control: $e -> $c row(s)" ;;
  esac
  CONTROLS="$CONTROLS $e=$c"
done

# --------------------------------------------------------------------- become anonymous
ROLES="$(tt_authz_anonymous)"
note "anonymous session roles: $ROLES"
for privileged in Consultant ProjectManager HR TitanManager Administrator; do
  case "$ROLES" in
    *"\"$privileged\""*) bad "the 'anonymous' session still holds $privileged ($ROLES) - every count below is meaningless" ;;
  esac
done

# ------------------------------------------------------------------ the question itself
checked=0
for e in $ENTITIES; do
  ctrl=""
  for kv in $CONTROLS; do
    case "$kv" in "$e="*) ctrl="${kv#*=}" ;; esac
  done

  n="$(tt_authz_count "//$e")"
  case "$n" in
    ERR:no-mx-client)
      bad "$e: the Mendix client API was not available, so the data layer was never asked" ;;
    ERR:*)
      note "$e: refused outright ($n) — control saw $ctrl"
      checked=$((checked+1)) ;;
    ''|*[!0-9]*)
      bad "$e: the retrieve returned something that is not a count: [$n]" ;;
    0)
      case "$ctrl" in
        ERR:*|''|*[!0-9]*) note "$e: anonymous saw 0, but the control could not establish there is anything to see ($ctrl) — inconclusive, not a pass" ;;
        0)                 note "$e: anonymous saw 0, and so did the control — the table is empty, so this proves nothing about access" ;;
        *)                 note "$e: 0 row(s) — control saw $ctrl, so the denial is real"; checked=$((checked+1)) ;;
      esac ;;
    *)
      bad "$e: an unauthenticated session retrieved $n row(s) (control saw $ctrl)" ;;
  esac
done

# A run that asked nothing conclusive must not report a pass.
[ "$checked" -gt 0 ] || bad "no entity produced a conclusive answer, so this step has no verdict to give"

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-anon-entity-read-scope — $fails entit(y/ies) readable without logging in, or unanswerable."
  exit 1
fi
echo "PASS: verify-anon-entity-read-scope — $checked entit(y/ies) conclusively denied to an anonymous session."
