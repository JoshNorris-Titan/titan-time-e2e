#!/usr/bin/env bash
# A consultant may change the hours on their own entries while those are still
# theirs to edit, and nothing else: not another consultant's hours, not their own
# Status, not the hours of a week they already submitted, not their week's Status,
# and they may not create entries from the browser.
#
# tt-timeout: 12m
#
# RED UNTIL THE CONSULTANT ACCESS FIX DEPLOYS (2026-10-06). Today Main.AssignmentEntry
# rule 1 lists Consultant with no XPath and Status/Monday ReadWrite, and create
# allowed; rule 3 (Consultant) adds Status ReadWrite. So every write below lands.
# The approved Gate 2 proposal ("bug 1, consultant write isolation", §3 and §7)
# replaces those with own-entries-only rules whose day columns are writable only
# while Status is Draft, Rejected or empty, and Status never. This spec asserts the
# behaviour AFTER that fix and must not be loosened to match today's.
#
# WHY IT WAS REWRITTEN. The previous version's evidence was hollow both ways:
#   - E wrote ToProcess onto an entry that was ALREADY ToProcess (it took the first
#     entry for the consultant with no Status filter), so F's "unchanged" proved
#     nothing and E's ok was ambiguous;
#   - C/D looked the other consultant's entry up AS THE CONSULTANT through
#     Assignment/ConsultantName, which the consultant cannot traverse, so the
#     lookup came back notfound and the cross-consultant write was never attempted.
# Now every target is found as HR and attacked BY GUID as the consultant, and each
# target is picked by the Status the step needs, seeded when absent.
#
# WHAT IT ASSERTS (as e2e_consultant unless stated)
#   A. the session holds Consultant and nothing more - a consultant who is also
#      PM/HR/TM is not protected by the fix and would make every result moot;
#   B. CONTROL: Monday on an OWN DRAFT entry can be changed to a NEW value and reads
#      back changed, then is put back. Without it no refusal below is attributable:
#      this runtime answers "Internal server error" for a denial, a typo'd
#      attribute and a validation failure alike;
#   C/D. Monday=23 on ANOTHER consultant's entry (guid fetched as HR) is refused or
#      not found, and HR reads its Monday back unchanged;
#   E/F. Status Draft -> ToProcess on the own Draft entry (self-approval) is refused,
#      and HR reads it back still Draft;
#   G. Monday on an OWN SUBMITTED entry (AwaitingManagerApproval, AwaitingCustomer-
#      Approval or ToProcess) is refused, and HR reads it back unchanged;
#   H. Status on the consultant's own Main.Timesheet is refused, and HR reads it
#      back unchanged;
#   I. creating a Main.AssignmentEntry from the browser is refused.
#
# The readbacks (D, F, G, H) are what decide. A refusal that landed anyway is
# exactly what they are there to catch.
#
# SCOPE AND CLEANUP. Touches only entries of "E2E Consultant" and "E2E Consultant
# Two". Every value that moved is put back (as HR, falling back to the consultant),
# and an entry created in I is deleted. May consume ONE week of e2e_consultant's on
# 'E2E Manager Approval' when no submitted entry exists yet, and visits up to six
# earlier weeks to find a Draft one.
#
# Consumes: one Draft and one submitted entry of E2E Consultant, one entry of E2E
# Consultant Two (00-setup's isolation control seeds that one).
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

ME="${TT_ISO_USER:-e2e_consultant}"
MINE="${TT_ISO_MINE:-E2E Consultant}"
THEIRS="${TT_ISO_THEIRS:-E2E Consultant Two}"
SEED_PROJECT="${TT_ISO_SEED_PROJECT:-E2E Manager Approval}"

ent_of() { printf "//Main.AssignmentEntry[Main.AssignmentEntry_Assignment/Main.Assignment/ConsultantName = '%s']%s" "$1" "${2:-}"; }
by_id()  { printf "//%s[id = '%s']" "$1" "$2"; }
DRAFT_XP="$(ent_of "$MINE" "[Status = 'Draft']")"
SUBMITTED_XP="$(ent_of "$MINE" "[Status = 'AwaitingManagerApproval' or Status = 'AwaitingCustomerApproval' or Status = 'ToProcess']")"
THEIR_XP="$(ent_of "$THEIRS")"

# A decimal as the client hands it back ("8", "8.5", "0") plus <n>, kept as text.
plus() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%g", a + b }'; }

as_hr()         { tt_login "e2e_hr" "$TT_HR_READY"; }
as_consultant() { tt_login "$ME" "My Timesheets"; }

# ------------------------------------------------------------------ setup, as HR
as_hr
D_G="$(tt_authz_guid "$DRAFT_XP")"
S_G="$(tt_authz_guid "$SUBMITTED_XP")"
T_G="$(tt_authz_guid "$(ent_of "$THEIRS" "[Status = 'Draft']")")"
case "$T_G" in ERR:notfound) T_G="$(tt_authz_guid "$THEIR_XP")" ;; esac
case "$T_G" in
  ERR:notfound) tt_fail "setup: '$THEIRS' has no AssignmentEntry to attempt a cross-consultant write against. suites/00-setup/verify-002 seeds one; run the suite in order." ;;
  ERR:*)        tt_fail "setup: HR could not look up '$THEIRS' entries ($T_G)" ;;
esac

# A submitted own entry: reuse one, or submit a week on SEED_PROJECT.
case "$S_G" in
  ERR:notfound)
    note "setup: no submitted entry for '$MINE' - submitting a '$SEED_PROJECT' week"
    as_consultant
    tt_consultant_submit_project_row "$SEED_PROJECT" >/dev/null
    as_hr
    S_G="$(tt_authz_guid "$SUBMITTED_XP")" ;;
esac
case "$S_G" in ERR:*) tt_fail "setup: still no submitted entry for '$MINE' after seeding ($S_G)" ;; esac

# A Draft own entry: reuse one, or visit weeks until one exists. Visiting a week
# whose actions are still offered is what creates its Draft rows (fx_ensure_entries).
case "$D_G" in
  ERR:notfound)
    note "setup: no Draft entry for '$MINE' - visiting weeks as the consultant to create one"
    as_consultant
    for i in 1 2 3 4 5 6; do
      [ "$(tt_week_actionable)" = "true" ] && break
      playwright-cli click ".mx-name-btnWeekPrev" >/dev/null 2>&1
      sleep 3
    done
    note "setup: consultant is on $(tt_current_week) (actions offered: $(tt_week_actionable))"
    as_hr
    D_G="$(tt_authz_guid "$DRAFT_XP")" ;;
esac
case "$D_G" in ERR:*) tt_fail "setup: no Draft entry for '$MINE' exists or could be created ($D_G). Every own-entry assertion needs one; this is a fixture problem, not a finding." ;; esac

D_XP="$(by_id Main.AssignmentEntry "$D_G")"
S_XP="$(by_id Main.AssignmentEntry "$S_G")"
T_XP="$(by_id Main.AssignmentEntry "$T_G")"
TS_G="$(tt_authz_readback "$D_XP" 'Main.AssignmentEntry_Timesheet')"
case "$TS_G" in ''|ERR:*) tt_fail "setup: could not read the Draft entry's timesheet ($TS_G)" ;; esac
TS_XP="$(by_id Main.Timesheet "$TS_G")"

D_MON="$(tt_authz_readback "$D_XP" 'Monday')"
D_STATUS="$(tt_authz_readback "$D_XP" 'Status')"
S_MON="$(tt_authz_readback "$S_XP" 'Monday')"
S_STATUS="$(tt_authz_readback "$S_XP" 'Status')"
T_MON="$(tt_authz_readback "$T_XP" 'Monday')"
TS_STATUS="$(tt_authz_readback "$TS_XP" 'Status')"
for v in "$D_MON" "$D_STATUS" "$S_MON" "$S_STATUS" "$T_MON" "$TS_STATUS"; do
  case "$v" in ERR:*) tt_fail "setup: an HR control read failed ($v)" ;; esac
done
[ "$D_STATUS" = "Draft" ] || tt_fail "setup: the Draft entry reads Status=$D_STATUS - E would not be a Draft -> ToProcess transition"
case "$TS_STATUS" in Approved) TS_NEW="Draft" ;; *) TS_NEW="Approved" ;; esac
note "targets: own Draft $D_G (Mon=$D_MON) / own $S_STATUS $S_G (Mon=$S_MON) / $THEIRS $T_G (Mon=$T_MON) / own week $TS_G (Status=${TS_STATUS:-(empty)})"

# ----------------------------------------------------------------- A. the consultant
as_consultant
ROLES="$(tt_authz_roles)"
note "session roles: $ROLES"
case "$ROLES" in
  *'"Consultant"'*) : ;;
  *) tt_fail "A: the session does not hold Consultant ($ROLES) - nothing below would mean anything" ;;
esac
for privileged in HR TitanManager Administrator ProjectManager; do
  case "$ROLES" in
    *"\"$privileged\""*) bad "A: a consultant session also holds $privileged ($ROLES)" ;;
  esac
done

# ----------------------------------------------------------------- B. positive control
# A NEW value, read back changed: proves the write path, the attribute name and the
# value format, so an ERR: below is a refusal and not a malformed call.
B_NEW="$(plus "$D_MON" 1)"
tt_authz_expect_ok "B" "$(tt_authz_write "$D_XP" 'Monday' "$B_NEW")" >/dev/null
B_READ="$(tt_authz_readback "$D_XP" 'Monday')"
[ "$(plus "$B_READ" 0)" = "$B_NEW" ] || tt_fail "B: the control write reported ok but Monday reads [$B_READ], not $B_NEW - no refusal below could be attributed"
tt_authz_expect_ok "B-restore" "$(tt_authz_write "$D_XP" 'Monday' "$D_MON")" >/dev/null
note "B ok: own Draft Monday $D_MON -> $B_NEW -> $D_MON"

# ------------------------------------------------- the attempts (judged on readback)
C="$(tt_authz_write "$T_XP" 'Monday' '23')"
E="$(tt_authz_write "$D_XP" 'Status' 'ToProcess')"
G_NEW="$(plus "$S_MON" 5)"
G="$(tt_authz_write "$S_XP" 'Monday' "$G_NEW")"
H="$(tt_authz_write "$TS_XP" 'Status' "$TS_NEW")"
I="$(tt_authz_create 'Main.AssignmentEntry')"

# What the call itself said. ERR:timeout / ERR:no-mx-client mean nothing was asked.
said() {  # said <label> <answer> <what> [notfound-is-refusal]
  case "$2" in
    ERR:timeout|ERR:no-mx-client) bad "$1: the call never got an answer ($2), so it is not a refusal" ;;
    ERR:notfound) if [ -n "${4:-}" ]; then note "$1 ok: the consultant cannot even read it ($2)"; else bad "$1: the consultant could not find their OWN entry ($2) - the fix must still let them read it"; fi ;;
    ERR:*)        note "$1 ok: $3 was refused ($2)" ;;
    *)            bad "$1: $3 and the call returned [$2]" ;;
  esac
}
said C "$C" "'$ME' wrote Monday=23 on '$THEIRS' entry" notfound-ok
said E "$E" "'$ME' set their own Draft entry's Status to ToProcess (self-approval)"
said G "$G" "'$ME' changed Monday $S_MON -> $G_NEW on their own $S_STATUS entry"
said H "$H" "'$ME' set their own week's Status to $TS_NEW"
case "$I" in
  ERR:timeout|ERR:no-mx-client) bad "I: the create never got an answer ($I)" ;;
  ERR:*) note "I ok: creating a Main.AssignmentEntry was refused ($I)" ;;
  *)     bad "I: '$ME' created and committed a Main.AssignmentEntry from the browser ($I)"
         R="$(tt_authz_remove "$I")"; note "     (deleted it again: $R)" ;;
esac

# ------------------------------------------------------------ readback, as HR
as_hr
RESTORE=()
T_AFTER="$(tt_authz_readback "$T_XP" 'Monday')"
if [ "$(plus "$T_AFTER" 0)" = "$(plus "$T_MON" 0)" ]; then note "D ok: $THEIRS Monday is still $T_AFTER"
else bad "D: $THEIRS Monday moved $T_MON -> $T_AFTER, written by '$ME'"; RESTORE+=("$T_XP|Monday|$T_MON"); fi

D_AFTER="$(tt_authz_readback "$D_XP" 'Status')"
if [ "$D_AFTER" = "Draft" ]; then note "F ok: own entry Status is still Draft"
else bad "F: own entry Status moved Draft -> $D_AFTER, set by the consultant - self-approval"; RESTORE+=("$D_XP|Status|Draft"); fi

S_AFTER="$(tt_authz_readback "$S_XP" 'Monday')"
if [ "$(plus "$S_AFTER" 0)" = "$(plus "$S_MON" 0)" ]; then note "G ok: own $S_STATUS entry Monday is still $S_AFTER"
else bad "G: own $S_STATUS entry Monday moved $S_MON -> $S_AFTER - hours changed after submitting"; RESTORE+=("$S_XP|Monday|$S_MON"); fi

TS_AFTER="$(tt_authz_readback "$TS_XP" 'Status')"
if [ "$TS_AFTER" = "$TS_STATUS" ]; then note "H ok: own week Status is still ${TS_AFTER:-(empty)}"
else bad "H: own week Status moved ${TS_STATUS:-(empty)} -> $TS_AFTER, set by the consultant"; RESTORE+=("$TS_XP|Status|$TS_STATUS"); fi

# ------------------------------------------------------------ put things back
if [ "${#RESTORE[@]}" -gt 0 ]; then
  LEFT=()
  for r in "${RESTORE[@]}"; do
    IFS='|' read -r xp attr val <<< "$r"
    if [ "$(tt_authz_write "$xp" "$attr" "$val")" = "ok" ]; then note "     (restored $attr=$val as HR)"; else LEFT+=("$r"); fi
  done
  if [ "${#LEFT[@]}" -gt 0 ]; then
    as_consultant
    for r in "${LEFT[@]}"; do
      IFS='|' read -r xp attr val <<< "$r"
      R="$(tt_authz_write "$xp" "$attr" "$val")"
      note "     (restoring $attr=$val as the consultant: $R)"
    done
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-consultant-write-isolation — $fails problem(s). B proved the write path works, so these are findings about the access rules, not about this script."
  exit 1
fi
echo "PASS: verify-consultant-write-isolation — '$ME' edits only their own Draft hours; other consultants' hours, own Status, submitted hours, the week's Status and entry creation are all refused and unchanged."
