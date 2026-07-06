# JuliaDaemon (`jld`)

Persistent, Revise-enabled Julia daemons — one per project — driveable from the
command line. Built for agentic workflows: package load and compile latency is
paid once, then each `jld eval`/`jld run` costs ~0.2s, streams output live,
and returns honest exit codes.

```sh
cd MyPkg
jld eval 'using MyPkg; MyPkg.foo()'   # autostarts the daemon, loads MyPkg
# edit src/…
jld run scratch.jl                     # Revise applied your edit; no reload
jld connect                            # attach your own REPL to the same session
```

## How it works

- `jld` resolves the project (`--project`, `JULIA_PROJECT`, or nearest
  `Project.toml`) and keys a daemon on it. Separate projects/worktrees get
  separate daemons automatically; `--name`/`JLD_NAME` separates daemons
  sharing one project.
- The daemon runs `julia --project=<proj>` with Revise loaded (from a private
  environment stacked on `JULIA_LOAD_PATH` — your project's `Project.toml` is
  never touched). Every request calls `Revise.revise()` first and reports
  failures (`jld:` warnings) instead of silently running stale code.
- Requests evaluate into `Main` with REPL soft-scope semantics; state (and
  `ans`) persists across calls. Evals are serialized; concurrent requests
  queue.
- `jld connect` attaches an interactive REPL that shares `Main` with the
  agent: inspect what it built, and vice versa. The remote prompt speaks the
  same framed text protocol as everything else — no serialization, so any
  julia version can attach to any daemon, and completions travel on their own
  connection (answered by the daemon's control thread, even mid-eval).
- Interrupts are soft (`schedule(task, InterruptException())`): they land at
  yield points. A hot loop that never yields cannot
  be interrupted — `jld kill` it; the next eval autostarts a fresh daemon.

## Commands

See `jld --help`. The essentials: `eval`, `run`, `start`, `restart`, `stop`,
`interrupt`, `status`, `list`, `connect`, `logs`.

Exit codes: 0 ok, 1 julia error, 2 usage, 3 daemon unavailable, 124 timeout,
130 interrupted.

## Serving an existing session

A running interactive session can itself become a daemon:

```julia
julia> using JuliaDaemon
julia> JuliaDaemon.serve()        # or serve(name="mysession")
```

It appears in `jld list` (state `idle/repl`), and agents can `jld --id=<id>
eval` into it, read its transcript (which includes your typed inputs),
inspect its stacks, and `jld eval-repl` paste into your prompt. `jld stop` is
refused for sessions — exit the REPL to end it. Revise is optional here and
used when loadable in the session.

## Julia versions

`--julia=BIN` (or `JLD_JULIA`) picks the daemon's julia — e.g. an in-tree
`usr/bin/julia` build. Daemon dependencies are installed on first use into a
named depot environment per minor version (`@jld-v1.12`, …), so the jld
installation itself can be read-only. The wire protocol is plain text, so the `jld` CLI and `jld connect` work
against daemons of any version (handy when the dev build is broken mid-rebase:
`status`/`logs`/`stop` still work).

## Install

As a Pkg app (julia 1.12+; puts the `jld` shim in `~/.julia/bin`, keep it on PATH):

```
pkg> app add <this repo url>
$ jld install        # installs the agent skill (SKILL.md)
```

`install` copies the skill into `~/.agents/skills/` (the cross-tool Agent
Skills location, read by opencode, Gemini CLI, …) and into the skills dirs
of installed agents that only read their own (`~/.claude`, `~/.codex`).
From a clone, `JuliaDaemon.jl/bin/jld install` also symlinks
`~/.local/bin/jld` if `jld` is not already on PATH.

The daemon dependency (Revise) installs itself on first use.

State lives in `~/.cache/julia-daemon/<id>/` (socket, config, log).
Test: `test/e2e.sh`.
