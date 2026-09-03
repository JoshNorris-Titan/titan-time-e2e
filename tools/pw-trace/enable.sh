# tools/pw-trace/enable.sh — turn on playwright-cli call profiling for this shell.
#
#   source tools/pw-trace/enable.sh          # trace to a timestamped file
#   source tools/pw-trace/enable.sh my.trace # trace to a path you choose
#
# MUST BE SOURCED, not executed: it works by changing PATH and exporting two
# variables, and a child process cannot do either to its parent.
#
# Leaves the suite's behaviour alone. The shim passes stdout, stderr, stdin and the
# exit code through untouched, so a traced run and an untraced run should differ only
# in wall clock - and only by the cost of one extra `bash` fork per call, single-digit
# milliseconds against a ~2,600ms call.

# ---------------------------------------------------------------- sourced check
# ${BASH_SOURCE[0]} == $0 means this file is the script being executed rather than
# a file being read into an existing shell. Exiting would kill the caller's shell if
# we were wrong, so this only warns and returns.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "enable.sh must be SOURCED, not executed:  source tools/pw-trace/enable.sh" >&2
  exit 2
fi

_pwt_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------- the real binary
# Resolved BEFORE the shim dir goes on PATH, and only once. Sourcing this twice
# without the guard would resolve playwright-cli to the shim itself, and the shim
# would exec itself forever.
if [ -z "${TT_PW_REAL:-}" ]; then
  _pwt_real="$(command -v playwright-cli 2>/dev/null || true)"
  if [ -z "$_pwt_real" ]; then
    echo "pw-trace: playwright-cli is not on PATH - nothing to trace." >&2
    unset _pwt_dir _pwt_real
    return 1
  fi
  # Refuse to point at ourselves, however we got here.
  if [ "$(cd "$(dirname "$_pwt_real")" && pwd)" = "$_pwt_dir" ]; then
    echo "pw-trace: playwright-cli already resolves to the shim, and TT_PW_REAL is" >&2
    echo "          unset. Open a fresh shell and source this once." >&2
    unset _pwt_dir _pwt_real
    return 1
  fi
  export TT_PW_REAL="$_pwt_real"
fi

# ------------------------------------------------------------------ trace file
if [ -n "${1:-}" ]; then
  export TT_PW_TRACE_FILE="$1"
else
  export TT_PW_TRACE_FILE="$_pwt_dir/trace-$(date +%Y%m%dT%H%M%S).log"
fi
: > "$TT_PW_TRACE_FILE" || { echo "pw-trace: cannot write $TT_PW_TRACE_FILE" >&2; return 1; }

# ------------------------------------------------------------------------ PATH
case ":$PATH:" in
  *":$_pwt_dir:"*) ;;                       # already ahead of the real binary
  *) PATH="$_pwt_dir:$PATH"; export PATH ;;
esac

echo "pw-trace ON"
echo "  real binary : $TT_PW_REAL"
echo "  trace file  : $TT_PW_TRACE_FILE"
echo "  report with : tools/pw-trace/report.sh \"$TT_PW_TRACE_FILE\""
unset _pwt_dir _pwt_real
