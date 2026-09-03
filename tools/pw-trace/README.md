# tools/pw-trace — where the suite's wall clock actually goes

A full green run takes ~89 minutes (`5,338s`, 67 steps, run `33694764812`). Almost
none of that is Mendix. Measured against `about:blank` on a 12-core host, with zero
app work involved:

| call | cost |
|---|---|
| `playwright-cli eval "() => 1+1"` | ~1,210 ms |
| `playwright-cli click` | ~1,494 ms |

Against Mendix Cloud dev from a GitHub runner the same call is ~2,600 ms. There are
559 `playwright-cli` call sites across `lib/`, `suites/` and `seeders/`, most inside
loops, so the run makes on the order of 1,600 of them — roughly 70 of the 89 minutes
spent starting `node`, not waiting on the app.

That last figure is **derived**, not measured, and this tool exists to replace it
with a number. Nothing here changes how the suite behaves.

## Use it

```bash
source tools/pw-trace/enable.sh          # MUST be sourced - it edits PATH
./run-tests.sh --base-url https://...
tools/pw-trace/report.sh                 # newest trace beside this file
```

In CI, dispatch the `E2E` workflow with **trace** ticked. The report lands in the
step log and the raw trace uploads as the `e2e-pw-trace` artifact.

## How it works

`enable.sh` puts this directory on `PATH` ahead of the real `playwright-cli` and
exports `TT_PW_REAL` (the real binary) and `TT_PW_TRACE_FILE`. The `playwright-cli`
here is a shim: it times the real call, appends `spec|subcommand|ms|rc`, and passes
stdout, stderr, stdin and the exit code through untouched. `run-tests.sh` exports
`TT_PW_SPEC` per step so each call is attributed to the step that caused it.

## Why a PATH shim and not a wrapper function

**Coverage.** A `pw()` helper in `lib/` only measures the call sites converted to
use it, so a partial rollout undercounts by an unknown amount — the exact error a
baseline exists to remove. The shim sees every call, including ones nobody
remembered.

**Stdout is load-bearing.** Every `eval` call site parses the response *by line
number* (`_tt_eval_str` reads line 2). A wrapper that ever wrote one stray byte to
stdout would shift that line and silently corrupt reads suite-wide. The shim writes
only to the trace file — proven byte-identical against the real binary.

## Gotchas

- **`enable.sh` must be sourced.** Executed, it can change nothing and says so.
- **The shim hard-fails without `TT_PW_REAL`.** It is on `PATH` under the real
  binary's name, so a PATH lookup would find itself and fork forever. It also
  refuses to guess, because a profiler that quietly declines to profile yields a
  clean-looking baseline that is simply wrong.
- **Running `run-tests.sh` locally closes the `default` browser session** — the
  runner owns that session's lifecycle and closes it on the way out. Unrelated to
  this tool, but it surprises people mid-profiling.
- Traces are gitignored. Put the numbers in the PR body, not the repo.
