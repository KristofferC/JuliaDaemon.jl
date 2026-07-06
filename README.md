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
- A RemoteREPL server runs in the same process. `jld connect` (or
  `connect_repl(port)` from any Julia REPL of the same version) shares `Main`
  with the agent: inspect what it built, and vice versa.
- Interrupts are soft (`schedule(task, InterruptException())`, like
  RemoteREPL): they land at yield points. A hot loop that never yields cannot
  be interrupted — `jld kill` it; the next eval autostarts a fresh daemon.

## Commands

See `jld --help`. The essentials: `eval`, `run`, `start`, `restart`, `stop`,
`interrupt`, `status`, `list`, `connect`, `logs`.

Exit codes: 0 ok, 1 julia error, 2 usage, 3 daemon unavailable, 124 timeout,
130 interrupted.

## Julia versions

`--julia=BIN` (or `JLD_JULIA`) picks the daemon's julia — e.g. an in-tree
`usr/bin/julia` build. Daemon dependencies are installed on first use into a
named depot environment per minor version (`@jld-v1.12`, …), so the jld
installation itself can be read-only. The wire protocol is plain text, so the `jld` CLI works
against daemons of any version (handy when the dev build is broken mid-rebase:
`status`/`logs`/`stop` still work). RemoteREPL attach does require the REPL's
julia to match the daemon's.

## Install

```sh
git clone <this repo> && JuliaDaemon.jl/bin/jld install
```

`install` symlinks `~/.local/bin/jld` and the Claude Code skill
(`~/.claude/skills/julia-daemon`). Requires `julia` on PATH; daemon
dependencies install themselves on first use.

State lives in `~/.cache/julia-daemon/<id>/` (socket, config, log).
Test: `test/e2e.sh`.
