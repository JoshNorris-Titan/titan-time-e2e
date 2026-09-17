#!/usr/bin/env bash
# A sent message carries substituted values, not the placeholders they came from.
#
# tt-timeout: 8m
#
# WHY THIS EXISTS. Nothing anywhere in this suite asserts that a merge token was
# actually replaced. verify-email-templates-present asserts that a template ROW
# exists, and says so in its own header; the three specs that read a mail read it
# to pull a TOKEN LINK out of it, never to look at the prose. So an EmailTemplate
# whose Content is empty, or one that ships "{%WeekRange%}" or "{%DaysOverdue%}"
# through to the customer verbatim, passes every test in the suite.
#
# That failure is invisible from the inside and embarrassing from the outside:
# the mail sends, the queue reports it delivered, the link in it even works. The
# only person who sees "Please approve {%ConsultantName%}'s timesheet" is the
# client.
#
# WHAT IT ASSERTS, on a message that actually exists:
#   A. a message for the fixture approver address can be read at all - fatal if
#      not, because every assertion below would otherwise pass on an empty string,
#      which is the exact shape of a test that cannot fail;
#   B. it contains no unresolved Mendix placeholder - no "{%...%}";
#   C. nor a bare "{1}" / "{2}" positional, which is how a template parameter that
#      was never given an argument renders;
#   D. the body is not empty once the subject line is discounted.
#
# WHY IT LOOKS FOR PATTERNS RATHER THAN EXPECTED CONTENT. Asserting that the mail
# says a particular consultant's name would pin this test to one template and one
# scenario, and would go red for any wording change. The placeholder syntax is the
# thing that is never legitimate in a delivered message, whatever the template says.
#
# Consumes: reads the Emails Sent admin page. Sends nothing.
# Env: TT_BASE_URL, TT_ADMIN_USER, TT_ADMIN_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_fixtures.sh"

ADDR="${TT_MERGE_ADDR:-$FX_APPROVER_EMAIL}"
fails=0
note() { echo "  $*"; }
bad()  { echo "  FAILED: $*"; fails=$((fails+1)); }

tt_mail_prepare || tt_fail "could not open the Emails Sent admin page, so no message could be read"

# ------------------------------------------------------------------ A. find a message
MAIL="$(tt_mail_find "$ADDR" 2>/dev/null)"
if [ -z "$MAIL" ]; then
  tt_fail "no message was found for '$ADDR', so this step has nothing to inspect and no verdict to give. suites/30-approval and 60-email cause messages to that address; run the suite in order, or point TT_MERGE_ADDR at an address that has one."
fi
note "A ok: found a message for $ADDR (${#MAIL} chars)"

# ------------------------------------------------------- B. no unresolved placeholders
LEFTOVER="$(printf '%s' "$MAIL" | grep -oE '\{%[^%]*%\}' | sort -u | head -5)"
if [ -n "$LEFTOVER" ]; then
  bad "B: the message still carries unresolved placeholder(s): $(printf '%s' "$LEFTOVER" | tr '\n' ' ')"
else
  note "B ok: no {%...%} placeholder survives in the message"
fi

# ------------------------------------------------- C. no unfilled positional parameters
POSITIONAL="$(printf '%s' "$MAIL" | grep -oE '\{[0-9]+\}' | sort -u | head -5)"
if [ -n "$POSITIONAL" ]; then
  bad "C: the message carries unfilled positional parameter(s): $(printf '%s' "$POSITIONAL" | tr '\n' ' ')"
else
  note "C ok: no {1}/{2} positional survives in the message"
fi

# ------------------------------------------------------------------- D. it has a body
BODY="$(printf '%s' "$MAIL" | sed '1{/^Subject:/d;}' | tr -d '[:space:]')"
if [ -z "$BODY" ]; then
  bad "D: the message has a subject and nothing else - an EmailTemplate with empty Content sends exactly like this and passes every other test in the suite"
else
  note "D ok: the message has a body (${#BODY} non-space chars)"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: verify-email-merge-tokens-resolved — $fails problem(s) in the message sent to $ADDR."
  exit 1
fi
echo "PASS: verify-email-merge-tokens-resolved — the message to $ADDR is fully substituted and has a body."
