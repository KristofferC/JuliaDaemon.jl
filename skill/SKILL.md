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
  The project is already active — never put `Pkg.activate(...)` in scripts.
  With no Project.toml anywhere upwards, the daemon serves the default user
  environment (like plain julia).
- If `--startup` code fails at boot, the daemon stays up without it and
  `jld start`/`jld status` say so — rerun the code via `jld eval`, or fix
  and `jld restart`.
- `Main` state persists between requests like a REPL (including `ans`).
  Prefer fresh variable names; `jld restart` for a clean slate.
- Take `jld:`-prefixed warnings seriously: "Revise failed to apply changes"
  means the output came from STALE code — fix the file and rerun, or
  `jld restart` if it persists.
- Exit codes are honest: 0 ok, 1 julia error (backtrace on stderr),
  3 daemon unreachable, 124 timeout, 130 interrupted.

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

Long-running commands: pass `--timeout=SECS` (exit 124 interrupts the eval but
keeps the daemon and its compile state alive). Note struct-layout changes may
be handled by Revise on Julia ≥1.12; on older Julia they need `jld restart`.

## Working on Julia itself (Base/stdlib)

In a julia checkout with an in-tree build, Base edits apply live — no `make`:

    mkdir -p /tmp/jld-base && touch /tmp/jld-base/Project.toml
    jld start --julia=/path/to/julia/usr/bin/julia \
        --project=/tmp/jld-base --startup='Revise.track(Base)'   # prints the daemon id
    jld --id=<id> eval 'Base.foo(...)'   # edits under base/ apply per request

- The julia repo has no top-level Project.toml, so bare `jld` commands run
  from the checkout target the *default user environment*, not this daemon —
  pass `--id=<id>` (printed by start, shown by `jld list`) or the same
  `--project` on every command, `eval` included.
- Keep the scratch Project.toml empty — a populated environment's manifest
  can pin different versions of Revise's own deps, which forces (and on a
  -DEV julia can break) re-precompilation.
- On unreleased julia versions (X.Y-DEV) the registry's Revise stack may not
  precompile at all; `jld start` detects this and prints the fix:
  `jld setup --dev --julia=... --project=...` installs the stack from
  master into `@jld-vX.Y` (or start with `--no-revise`).

## Interrupting

`jld interrupt` stops the current eval at the next yield point; the daemon
survives. Pure CPU loops that never yield cannot be soft-interrupted: check
`jld stacks` to see what it is doing, then `jld kill` if stuck — the next
eval autostarts fresh.

## Commands

```
jld eval '<code>'   evaluate (stdin if no arg; heredocs work)   [autostarts]
jld eval --scratch '<code>'  eval in a throwaway module that sees Main's bindings
                    and keeps NOTHING — prefer for exploration so Main stays
                    clean (also works with run: `jld run --scratch file.jl`)
jld run <file.jl>   include a file                              [autostarts]
jld start           pre-warm; --startup='using MyPkg' runs at boot
jld restart         reload from scratch (keeps recorded --startup)
jld status | list | stop | kill | interrupt | gc
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
one project — set this if another agent may share the directory),
`--id=ID` (target any existing daemon from `jld list`, any command),
`--module=M` (eval/run in module Main.M instead of Main),
`--julia=BIN` / `JLD_JULIA` (daemon's julia, e.g. an in-tree build),
`--timeout=SECS`,
`--no-revise` (daemon without Revise: faster start, but source edits need
`jld restart`; recorded — pass `--revise` on restart to re-enable).
