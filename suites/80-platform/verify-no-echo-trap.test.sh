#!/usr/bin/env bash
# verify-no-echo-trap.test.sh
#
# Static guard against the suite's most expensive recurring bug: an assertion that
# cannot fail because `grep` matched the ECHOED JS SOURCE instead of the result.
#
# THE BUG. playwright-cli prints the snippet back under "### Ran Playwright code",
# so this idiom
#     playwright-cli eval "() => { …; return 'ok'; }" | grep -qiw ok
# matches the literal `return 'ok'` inside the snippet and reports success no matter
# what the page did. `'ok'`, `'none'`, `'true'` and `'armed'` all match as whole
# words because quotes are not word characters. The result is always on line 2 —
# decode it first, as lib/_seed.sh's pw() and lib/_login.sh's _tt_eval_str() do.
#
# WHY A TEST AND NOT A README NOTE. The trap is already documented in README.md,
# CLAUDE.md and lib/_seed.sh:29-30, and it still reached six live call sites. A
# comment cannot fail a build; this can.
#
# WHAT COUNTS AS AN OFFENCE. A line that pipes `playwright-cli eval` into `grep`
# without first decoding through `sed -n '2p'` or `_tt_eval_str`, AND whose grep
# needle literally appears inside the snippet. A grep for a word the snippet never
# contains is safe and is not reported — the point is to catch assertions that are
# structurally incapable of failing, not to ban the idiom.
#
# SELF-TEST. Before trusting a clean scan this script proves its own detector still
# works, by running it over a known-bad and a known-good fixture line. A detector
# that silently stopped matching would otherwise turn this guard into exactly the
# kind of always-green assertion it exists to prevent.
#
# No browser and no login: pure static analysis, so it is safe in CI and costs
# nothing to run.
#
# Env: none.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"

DETECTOR="$(mktemp)"
FIXTURE="$(mktemp)"
trap 'rm -f "$DETECTOR" "$FIXTURE"' EXIT

cat > "$DETECTOR" <<'AWK'
/playwright-cli[ \t]+eval/ && /grep/ {
  line = $0
  # Ignore commented-out examples — README/helper docs quote the bad idiom on purpose.
  if (line ~ /^[ \t]*#/) next

  pi = index(line, "| grep"); if (pi == 0) pi = index(line, "|grep")
  if (pi == 0) next
  pre  = substr(line, 1, pi - 1)     # the snippet side
  post = substr(line, pi)            # the grep side

  # Already decoded to the result line? Then the grep sees data, not source.
  if (pre ~ /sed -n '2p'/ || pre ~ /_tt_eval_str/) next

  # Pull the needle out of the grep invocation, dropping any flags.
  n = post
  sub(/.*grep[^ \t]*[ \t]+(-[a-zA-Z-]+[ \t]+)*/, "", n)
  sub(/[ \t].*$/, "", n)
  gsub(/[^A-Za-z0-9_]/, "", n)       # strip quotes and trailing ; ) etc
  if (n == "") next

  # The offence: the needle also occurs in the snippet, so the echo alone matches.
  if (index(tolower(pre), tolower(n)) > 0)
    printf "%s:%d: grep -w %s matches the echoed snippet\n", FILENAME, FNR, n
}
AWK

# ---------------------------------------------------------------- detector self-test
# Fixture 1 must be flagged (undecoded, needle in the snippet); 2 and 3 must not
# (2 decodes first, 3 greps for a word the snippet never contains).
#
# The grep and sed fragments are held in variables so that no single line of THIS
# file contains both "playwright-cli eval" and the word "grep" — otherwise these
# deliberate examples would trip the scan below, and the guard would fail on itself
# rather than on the suite. That keeps this file in scope for genuine offences.
GB='| grep -qiw'
SD="| sed -n '2p'"
{
  printf '  playwright-cli eval "() => { return %s; }" 2>/dev/null %s ok\n'    "'ok'" "$GB"
  printf '  playwright-cli eval "() => { return %s; }" 2>/dev/null %s %s ok\n' "'ok'" "$SD" "$GB"
  printf '  playwright-cli eval "() => { return String(x); }" 2>/dev/null %s true\n'  "$GB"
} > "$FIXTURE"

self="$(awk -f "$DETECTOR" "$FIXTURE" 2>/dev/null)"
hits="$(printf '%s' "$self" | grep -c . || true)"
if [ "$hits" -ne 1 ] || ! printf '%s' "$self" | grep -q ':1:'; then
  echo "FAIL: verify-no-echo-trap — the detector itself is broken."
  echo "      Expected exactly 1 hit on fixture line 1; got $hits:"
  printf '%s\n' "$self" | sed 's/^/        /'
  echo "      Refusing to report a clean scan from a detector that cannot detect."
  exit 1
fi

# ---------------------------------------------------------------------------- scan
mapfile -t FILES < <(find "$TT_ROOT/lib" "$TT_ROOT/suites" -name '*.sh' -type f | LC_ALL=C sort)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "FAIL: verify-no-echo-trap — found no shell scripts to scan under $TT_ROOT."
  exit 1
fi

found="$(awk -f "$DETECTOR" "${FILES[@]}" 2>/dev/null | sed "s@^$TT_ROOT/@@")"

if [ -n "$found" ]; then
  count="$(printf '%s\n' "$found" | grep -c .)"
  echo "FAIL: verify-no-echo-trap — $count assertion(s) cannot fail:"
  printf '%s\n' "$found" | sed 's/^/  /'
  echo
  echo "  Fix: decode the result before grepping, e.g."
  echo "    playwright-cli eval \"…\" 2>/dev/null | sed -n '2p' | grep -qiw ok"
  echo "  or use pw() from lib/_seed.sh / _tt_eval_str from lib/_login.sh."
  exit 1
fi

echo "PASS: verify-no-echo-trap — ${#FILES[@]} scripts scanned, no echo-matched assertions (detector self-test OK)"
