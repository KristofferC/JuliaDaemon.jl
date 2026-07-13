---
name: julia-daemon
description: Run Julia code through jld (a persistent Revise-enabled daemon) instead of spawning fresh julia processes. Use whenever executing Julia code in a project — evaluating snippets, running scratch/test scripts, testing package changes, or working on Julia itself (Base/stdlib edits in a julia checkout) — to avoid paying package load and compile latency on every run.
---

# julia-daemon (jld)

`jld` keeps one long-lived Julia process per project with Revise loaded.
Package loading and compilation are paid once; source edits under the project
are applied automatically before each request. Warm requests cost ~0.2s.

## Rules

- In a Julia project, use `jld eval '<code>'` / `jld run <file.jl>` instead of
  `julia -e '<code>'` / `julia script.jl` for anything that loads project
  dependencies or the package under development.
- The daemon autostarts on first use (that request pays the package load).
  Include `--idle-timeout=2h` on commands that may autostart one (`jld eval`,
  `jld run`, `jld start`) so daemons you leave behind stop themselves instead
  of accumulating; it is recorded for restarts and ignored (harmlessly) when
  the daemon is already running.
  The project is already active — never put `Pkg.activate(...)` in scripts.
  With no Project.toml anywhere upwards, the daemon serves the default user
  environment (like plain julia) — except in a julia source checkout, which
  is served directly (see "Working on Julia itself").
- If `--startup` code fails at boot, the daemon stays up without it and
  `jld start`/`jld status` say so — rerun the code via `jld eval`, or fix
  and `jld restart`.
- `Main` state persists between requests like a REPL (including `ans`).
  Prefer fresh variable names; `jld restart` for a clean slate.
- Daemons are shared per project: if other agents (or subagents you spawn)
  may be working in the same project, give each its own daemon by passing
  `--name=<unique>` on every jld command. Without it, concurrent agents
  share one `Main`, and one agent's `restart`/`interrupt`/`stop` clobbers
  the other's warm session. `--name` is not recorded — a single call
  without it targets the shared default daemon.
- Take `jld:`-prefixed warnings seriously: "Revise failed to apply changes"
  means the output came from STALE code — fix the file and rerun, or
  `jld restart` if it persists.
- Exit codes are honest: 0 ok, 1 julia error (backtrace on stderr),
  2 usage error, 3 daemon unreachable, 124 timeout, 130 interrupted; code
  that calls `exit(N)` gives exit code N and the daemon survives it.
  Judge success by the exit code and the final `jld: daemon ready` line —
  not by `ERROR`/backtrace text scrolling past during a one-time setup, which
  may be an expected-and-healed step (e.g. reinstalling Revise from master).
- Backtraces are shown with runs of internal frames (Base, stdlib, installed
  packages) folded; the innermost frame — the throw site — is always kept.
  When you need the machinery in between, `jld trace` prints the full
  backtrace of the last error without rerunning anything.
- For code that may print a lot, pass `--max-output=16k`: output beyond the
  cap keeps its head and tail and drops the middle, so a runaway print loop
  cannot flood your context.

## Joining a human's live session

A user's interactive REPL may itself be serving (state `idle/repl` in
`jld list` — they ran `JuliaDaemon.serve()`). Join it with `--id=<id>`:
read `jld transcript` first (it includes what they typed), eval into it,
and show them results with `jld eval-repl`. NEVER `jld kill` a session —
it is the user's live REPL (`jld stop` is refused automatically).

## Testing changes to a package

1. Write a minimal scratch file with only the code under test
   (`using MyPkg, Test; @testset ...`). Don't run the full test suite.
2. `jld run /path/to/scratch.jl`
3. Edit package source, `jld run` again — the edit is live, no reload.

If the code needs test-only dependencies (from `[extras]`/test target or
`test/Project.toml`), add `--test`: it targets a separate daemon serving the
package's test environment (the `test/` workspace project when the package
declares one, else `TestEnv.activate()` at boot). The regular daemon is
untouched; `--test` works with every command (`jld --test run scratch.jl`,
`jld --test status`, ...). `jld --test run test/runtests.jl` runs the full
suite warm — still prefer scratch subsets.

Long-running commands: pass `--timeout=SECS`. It always terminates in bounded
time with exit 124: the eval is interrupted (daemon and compile state
survive), and only if it never yields is the daemon killed after a ~3s grace
— the next call starts a fresh one. Note struct-layout changes may
be handled by Revise on Julia ≥1.12; on older Julia they need `jld restart`.

## Working on Julia itself (Base/stdlib)

In a julia checkout with an in-tree build (`usr/bin/julia`), Base edits apply
live — no `make`. jld detects the checkout automatically: bare commands run
from inside it use the in-tree julia, a jld-managed scratch environment, and
`Revise.track(Base)` at boot — no setup, no `--id`:

    jld eval 'Base.foo(...)'   # edits under base/ apply per request, including
                               # edits made before the daemon started (anything
                               # newer than the last `make`)

- `--julia=BIN` overrides the binary; `--startup=...` on the first `jld start`
  replaces the default `Revise.track(Base)` (recorded for restarts).
- On unreleased julia versions (X.Y-DEV) the registry's Revise stack usually
  fails to precompile; jld installs the stack from master into `@jld-vX.Y`
  instead (same as `jld setup --dev`), so the failing registry precompile is
  never run or shown. Expect the first start on a fresh env to take a few
  minutes; only if the master stack also fails does it stop with alternatives
  (e.g. `--no-revise`), printing the captured error then.
- The first `jld eval`/`jld run` in a not-yet-started daemon pays this whole
  setup, interleaving its output with your result. When you care about reading
  the result cleanly (or the env is fresh), run `jld start` first — it prints
  only progress plus a final `daemon ready`, then evals come back clean.

## Interrupting

`jld interrupt` stops the current eval at the next yield point; the daemon
survives. Pure CPU loops that never yield cannot be soft-interrupted: check
`jld stacks` to see what it is doing, then `jld interrupt --force` — it
soft-interrupts first and only kills + restarts the daemon (pre-warmed, with
its recorded options) if the eval does not yield within ~3s. Never use
`--force` or `jld kill` on a session daemon (it is the user's live REPL;
`--force` refuses them automatically, `kill` does not).

## Commands

```
jld eval '<code>'   evaluate (stdin if no arg; heredocs work)   [autostarts]
jld eval --scratch '<code>'  eval in a throwaway module that sees Main's bindings
                    and keeps NOTHING — prefer for exploration so Main stays
                    clean (also works with run: `jld run --scratch file.jl`)
jld run <file.jl>   include a file                              [autostarts]
jld start           pre-warm; --startup='using MyPkg' runs at boot;
                    --idle-timeout=30m stops it after 30m without requests
jld restart         reload from scratch (keeps recorded --startup)
jld status | list | stop | kill | interrupt [--force] | gc
jld trace           full backtrace of the last eval error (errors print a
                    collapsed one)
jld logs [-f | --lines=N | --all]   daemon log (default: last 100 lines —
                    a failed start's root cause may be further up: --all)
jld stacks          task backtraces of what the daemon is executing right now
jld transcript      full session history (all inputs + outputs, incl. the human's
                    REPL) — read this first when joining an existing session
jld connect [id]    attach an interactive human REPL (shares Main); id targets any daemon
jld eval-repl '<code>'  paste code into the human's attached REPL (echoed + evaluated
                    at whatever prompt is active there) — useful to show results
```

Flags: `--project=PATH` (default: nearest Project.toml, else the default
environment like plain julia), `--name=N` / `JLD_NAME` (parallel daemons on
one project — required on every command when agents share a directory, see
Rules),
`--test` (separate daemon serving the package's test environment —
test-only deps importable),
`--id=ID` (target any existing daemon from `jld list`, any command),
`--module=M` (eval/run in module Main.M instead of Main),
`--julia=BIN` / `JLD_JULIA` (daemon's julia, e.g. an in-tree build),
`--timeout=SECS`, `--max-output=N` (cap streamed output, e.g. `16k`),
`--idle-timeout=T` (start/restart: self-stop after T idle, e.g. `30m`),
`--no-revise` (daemon without Revise: faster start, but source edits need
`jld restart`; recorded — pass `--revise` on restart to re-enable).
