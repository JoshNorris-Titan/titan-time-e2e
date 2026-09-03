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
_pwt_root="$(cd "$_pwt_dir/../.." && pwd)"

# ------------------------------------------------------------- the real binary
# Resolved BEFORE the shim dir goes on PATH, and only once. Sourcing this twice
# without the guard would resolve playwright-cli to the shim itself, and the shim
# would exec itself forever.
#
# node_modules/.bin IS CHECKED FIRST, AND NOT AS A NICETY. `playwright-cli` is a
# local dependency (@playwright/cli in package.json); the only thing that ever
# puts it on PATH is run-tests.sh, which does its own prepend - long AFTER this
# file is sourced. So on a CI runner, where there is no global install, resolving
# from PATH alone can never succeed and the trace could never be enabled. It
# looked fine locally only because the authoring host happens to have a global
# copy. Same reasoning, same order, as run-tests.sh's own prepend.
if [ -z "${TT_PW_REAL:-}" ]; then
  if [ -x "$_pwt_root/node_modules/.bin/playwright-cli" ]; then
    _pwt_real="$_pwt_root/node_modules/.bin/playwright-cli"
  else
    _pwt_real="$(command -v playwright-cli 2>/dev/null || true)"
  fi
  if [ -z "$_pwt_real" ]; then
    echo "pw-trace: playwright-cli found neither in $_pwt_root/node_modules/.bin" >&2
    echo "          nor on PATH - nothing to trace. Run 'npm ci' first." >&2
    unset _pwt_dir _pwt_root _pwt_real
    return 1
  fi
  # Refuse to point at ourselves, however we got here.
  if [ "$(cd "$(dirname "$_pwt_real")" && pwd)" = "$_pwt_dir" ]; then
    echo "pw-trace: playwright-cli already resolves to the shim, and TT_PW_REAL is" >&2
    echo "          unset. Open a fresh shell and source this once." >&2
    unset _pwt_dir _pwt_root _pwt_real
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
unset _pwt_dir _pwt_root _pwt_real
