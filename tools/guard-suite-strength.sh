#!/usr/bin/env bash
# guard-suite-strength.sh <base-ref> — refuse a change that makes the suite weaker.
#
# WHY THIS EXISTS. The e2e-autofix loop merges its own PRs into a repository with no
# branch protection and no reviewer. Its rails are good and its ledger shows it has
# kept to them -- it escalated two real product regressions rather than routing
# around them -- but they are rails in a Markdown file. Nothing in GitHub stops a
# future or carelessly-edited version of that skill from turning a red test green by
# making it toothless, which the README calls the worst possible outcome because
# nobody investigates a green result.
#
# This is the mechanical half of that skill's Step 4. It enforces the rails that can
# be checked from a diff, and deliberately not the ones that cannot:
#
#   enforced   deleting a test, or renaming one out of the verify-*.test.sh glob
#   enforced   adding an entry to ci-skip.txt
#   enforced   removing assertions from a test
#   enforced   adding `|| true` or a swallowed exit code to a test
#   enforced   raising a per-test tt-timeout
#   enforced   lowering suites/expected-count.txt
#   NOT        "is this assertion meaningfully weaker" -- a human judgement
#   NOT        "did this touch .github/workflows" -- Josh edits workflows routinely,
#              and a guard that failed on its own PR would be self-blocking
#
# ESCAPE HATCH. Every rule here is legitimate to break on purpose sometimes: tests do
# get deleted, timeouts do genuinely need raising. Set GUARD_OVERRIDE=1 (in CI, the
# `weakens-suite-on-purpose` label) and the run reports what it found and passes. The
# point is never to make a change impossible -- only to make it impossible to do
# silently, and unavailable to an unattended loop.
set -uo pipefail

BASE="${1:?usage: guard-suite-strength.sh <base-ref>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 2

fails=0
bad() { echo "  REFUSED: $*"; fails=$((fails+1)); }

# Lines that carry the weight of a test. Deliberately broad: the check is on the
# COUNT changing, so a rename or a reflow nets to zero and only a real removal shows.
ASSERTION_RE='tt_fail|tt_assert|tt_wait_for|tt_wait_text|tt_expect|^[[:space:]]*exit 1|\bbad "|\[ "'

changed="$(git diff --name-status "$BASE"...HEAD)"
if [ -z "$changed" ]; then
  echo "guard: no changes against $BASE"
  exit 0
fi

# ---------------------------------------------------------- 1. deleted / renamed out
while IFS=$'\t' read -r status path rest; do
  case "$status" in
    D*)
      case "$path" in
        suites/*verify-*.test.sh) bad "test deleted: $path" ;;
      esac
      ;;
    R*)
      case "$path" in
        suites/*verify-*.test.sh)
          case "$rest" in
            *verify-*.test.sh) : ;;                       # renamed, still discovered
            *) bad "test renamed OUT of the verify-*.test.sh glob: $path -> $rest" ;;
          esac
          ;;
      esac
      ;;
  esac
done <<< "$changed"

# ------------------------------------------------------------------- 2. ci-skip.txt
skipadd="$(git diff "$BASE"...HEAD -- ci-skip.txt | grep '^+[^+]' | sed 's/^+//' | grep -vE '^[[:space:]]*(#|$)' || true)"
if [ -n "$skipadd" ]; then
  bad "ci-skip.txt gains $(printf '%s\n' "$skipadd" | grep -c .) entr(y/ies): $(printf '%s' "$skipadd" | tr '\n' ' ')"
fi

# --------------------------------------------------- 3. assertions removed from a test
testfiles="$(git diff --name-only "$BASE"...HEAD | grep -E '^suites/.*verify-.*\.test\.sh$' || true)"
for f in $testfiles; do
  [ -f "$f" ] || continue                                   # deletions handled above
  d="$(git diff "$BASE"...HEAD -- "$f")"
  removed="$(printf '%s\n' "$d" | grep '^-[^-]' | grep -cE "$ASSERTION_RE" || true)"
  addedl="$(printf '%s\n' "$d" | grep '^+[^+]' | grep -cE "$ASSERTION_RE" || true)"
  if [ "$removed" -gt "$addedl" ]; then
    bad "$f loses $(( removed - addedl )) assertion-bearing line(s) ($removed removed, $addedl added)"
  fi
  if printf '%s\n' "$d" | grep '^+[^+]' | grep -qE '\|\|[[:space:]]*true|\|\|[[:space:]]*:[[:space:]]*$|set \+e'; then
    bad "$f gains a swallowed failure (|| true, || :, or set +e)"
  fi
done

# ------------------------------------------------------------------ 4. timeouts raised
for f in $testfiles; do
  [ -f "$f" ] || continue
  old="$(git show "$BASE:$f" 2>/dev/null | grep -o '^# tt-timeout:[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' | head -1)"
  new="$(grep -o '^# tt-timeout:[[:space:]]*[0-9]\+' "$f" | grep -o '[0-9]\+' | head -1)"
  if [ -n "$old" ] && [ -n "$new" ] && [ "$new" -gt "$old" ]; then
    bad "$f raises tt-timeout ${old}m -> ${new}m (needs evidence the step is genuinely slower)"
  fi
done

# ------------------------------------------------------------ 5. expected-count lowered
countchanged="$(git diff --name-only "$BASE"...HEAD -- suites/expected-count.txt)"
if [ -n "$countchanged" ]; then
  o="$(git show "$BASE:suites/expected-count.txt" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | head -1 | tr -d '[:space:]')"
  n="$(grep -vE '^[[:space:]]*(#|$)' suites/expected-count.txt | head -1 | tr -d '[:space:]')"
  case "$o" in ''|*[!0-9]*) o="" ;; esac
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  if [ -n "$o" ] && [ -n "$n" ] && [ "$n" -lt "$o" ]; then
    bad "suites/expected-count.txt drops $o -> $n; $(( o - n )) step(s) left discovery"
  fi
fi

# ----------------------------------------------------------------------- verdict
if [ "$fails" -eq 0 ]; then
  echo "PASS: guard-suite-strength — nothing in this change makes the suite weaker"
  exit 0
fi

echo ""
if [ -n "${GUARD_OVERRIDE:-}" ]; then
  echo "OVERRIDDEN: $fails finding(s) above were allowed on purpose."
  echo "            (GUARD_OVERRIDE is set; in CI that is the weakens-suite-on-purpose label.)"
  exit 0
fi
echo "guard-suite-strength refuses this change: $fails finding(s)."
echo ""
echo "  Each of these is sometimes the right thing to do, and none of them is"
echo "  something to do unattended. If it is deliberate, say so out loud: add the"
echo "  'weakens-suite-on-purpose' label to the PR and explain why in the body."
echo ""
echo "  The autofix loop must NOT use that label. Its own rails (Step 4) say every"
echo "  finding above is an escalation to Josh, never an autonomous merge."
exit 1
