---
name: julia-daemon
description: Run Julia code through jld (a persistent Revise-enabled daemon) instead of spawning fresh julia processes. Use whenever executing Julia code in a project — evaluating snippets, running scratch/test scripts, or testing package changes — to avoid paying package load and compile latency on every run.
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
jld status | list | logs [-f] | stop | kill | interrupt | gc
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
