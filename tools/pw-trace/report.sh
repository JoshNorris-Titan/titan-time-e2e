#!/usr/bin/env bash
# tools/pw-trace/report.sh [trace-file] — summarize a pw-trace run.
#
# Answers the three questions the optimisation work is judged on:
#   1. how many playwright-cli processes did the run launch?
#   2. how many seconds did it spend inside them?
#   3. which specs and which subcommands own that time?
#
# With no argument it reports on $TT_PW_TRACE_FILE, else the newest trace beside
# this script. Trace format is `spec|subcommand|ms|rc`, one line per call.
#
# Each section re-reads the file rather than splitting one awk stream. The first
# version piped awk into `{ head -6; tail -n +7 | sort; }` to keep a header above
# sorted rows, and silently dropped rows: `head` reads a full buffer, which swallows
# the whole of a short stream, so `tail` saw nothing and the report showed 6 of 8
# calls under a TOTAL line that correctly said 8. Re-reading a local file costs
# nothing and cannot lie.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="${1:-${TT_PW_TRACE_FILE:-}}"
if [ -z "$F" ]; then
  F="$(ls -1t "$HERE"/trace-*.log 2>/dev/null | head -1 || true)"
fi
[ -n "$F" ] && [ -f "$F" ] || { echo "report.sh: no trace file (pass one, or set TT_PW_TRACE_FILE)" >&2; exit 2; }
[ -s "$F" ] || { echo "report.sh: $F is empty - was the shim actually on PATH? (source tools/pw-trace/enable.sh)" >&2; exit 2; }

echo "trace: $F"
echo

awk -F'|' '
  { n++; ms+=$3; if ($4+0 != 0) bad++ }
  END {
    if (n == 0) { print "no calls recorded"; exit }
    printf "TOTAL  %d launches, %.0fs inside playwright-cli, mean %.0fms/call\n", n, ms/1000, ms/n
    printf "       %d calls returned non-zero\n", bad+0
  }
' "$F"

echo
echo "BY SUBCOMMAND"
printf "  %-16s %7s %9s %9s\n" "subcommand" "calls" "total_s" "mean_ms"
awk -F'|' '{ c[$2]++; m[$2]+=$3 } END { for (s in c) printf "  %-16s %7d %9.0f %9.0f\n", s, c[s], m[s]/1000, m[s]/c[s] }' "$F" \
  | sort -k3 -rn

echo
echo "BY SPEC (worst 25)"
printf "  %-46s %7s %9s %9s\n" "spec" "calls" "total_s" "mean_ms"
awk -F'|' '{ c[$1]++; m[$1]+=$3 } END { for (s in c) printf "  %-46s %7d %9.0f %9.0f\n", s, c[s], m[s]/1000, m[s]/c[s] }' "$F" \
  | sort -k3 -rn | head -25
