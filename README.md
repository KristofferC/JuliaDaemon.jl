# JuliaDaemon (`jld`)

[![CI](https://github.com/KristofferC/JuliaDaemon.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/KristofferC/JuliaDaemon.jl/actions/workflows/ci.yml)

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

`jld --help` prints the same reference. `eval`, `run`, and `connect`
autostart the daemon; the rest act on an existing one.

### Running code

- `jld eval '<code>'` — evaluate in the daemon's `Main`. Reads stdin when no
  argument is given, so heredocs work. Output streams live, the result is
  displayed REPL-style, and `ans` is set.
- `jld run <file.jl>` — `include()` a file. Each request runs with the daemon
  `cd`'d to your shell's cwd, so relative paths behave as expected.

Both accept:

- `--scratch` — evaluate in a fresh throwaway module that sees `Main`'s
  bindings but keeps nothing; everything it defines is released afterwards.
  Use it for exploration so `Main` stays clean.
- `--module=M` — evaluate in `Main.M` instead of `Main` (created on demand;
  not combinable with `--scratch`).
- `--timeout=SECS` — interrupt the eval after SECS and exit 124. The daemon
  and its compile state survive.
- `--no-autostart` — fail (exit 3) instead of starting a daemon.

### Lifecycle

- `jld start` — pre-warm. `--startup='using MyPkg'` runs code at boot
  (repeatable) and is recorded so `restart` replays it. `--threads=N` sets
  eval threads (an interactive thread is always added on top — that's why
  `status`, `stacks`, and `connect` keep working during a CPU-bound eval).
  `--timeout` bounds the wait for the daemon to come up.
- `jld restart` — stop and start from scratch, keeping the recorded startup
  code. Needed after struct layout redefinitions (on julia < 1.12).
- `jld interrupt` — interrupt the current eval at its next yield point; the
  daemon survives.
- `jld stop` — graceful shutdown. Refused for served sessions (that would be
  someone's live REPL).
- `jld kill` — SIGKILL. Not session-guarded; check `jld list` before using it
  on a daemon you didn't start.
- `jld gc` — remove state (config, log, transcript) of dead daemons.

### Inspecting

- `jld status` — state of the daemon this context targets: busy/idle, the
  current eval and how long it has run, pid, julia version, uptime, and a
  warning if Revise failed to load. Works mid-eval.
- `jld list` — all daemons; `*` marks the one the current context targets.
- `jld logs [-f]` — daemon log (`-f` follows).
- `jld transcript [id] [-f]` — the full session history: every input and
  output evaluated in the daemon (`jld eval`/`run` and REPL input alike),
  truncated per entry. The fastest way to pick up the context of a running
  session.
- `jld stacks [id]` — task backtraces of what the daemon is executing right
  now; useful before deciding whether to `interrupt` or `kill`.

### Interactive

- `jld connect [id]` — attach a REPL (`julia@<id>>` prompt) to a daemon;
  backspace switches to a local `julia>` prompt, Ctrl-D exits. `--print`
  prints the socket path instead of attaching.
- `jld eval-repl '<code>'` — paste code into the attached `connect` REPL
  exactly as if typed there: echoed at the prompt, evaluated, `ans` set.
  Lets an agent show results in the human's REPL.

### Installation

- `jld setup` — (re)install the daemon environment for the selected julia.
  Normally automatic on first use.
- `jld install` — install the agent skill (see [Install](#install)).

### Exit codes

0 ok, 1 julia error, 2 usage, 3 daemon unavailable, 124 timeout,
130 interrupted.

## Flags

All commands accept the flags that select a daemon; the eval-specific ones
are listed above.

| Flag | Env | Meaning |
|------|-----|---------|
| `--project=PATH` | `JULIA_PROJECT` | project to serve (default: nearest `Project.toml`, else the default environment — like plain julia) |
| `--name=NAME` | `JLD_NAME` | distinct daemon for the same project (parallel agents, throwaway experiments) |
| `--id=ID` | | target an existing daemon: full id, any unique substring, or its row number in `jld list`; works with every command |
| `--julia=BIN` | `JLD_JULIA` | julia executable for the daemon |
| `--startup=CODE` | | code to run at daemon boot (repeatable; `start`/`restart`) |
| `--threads=N` | | daemon eval threads (default 1; +1 interactive thread always) |
| `--timeout=SECS` | | eval/run: interrupt after SECS; start: wait limit |
| `--module=M` / `--scratch` | | eval/run target module (see above) |
| `--no-autostart` | | eval/run: fail instead of autostarting |
| `--no-revise` | | start the daemon without Revise — source edits then need `jld restart`. Recorded like `--startup`; pass `--revise` to re-enable on restart. `status` shows `revise: disabled` |
| `-f` | | follow (`logs`, `transcript`) |

Outside any project, commands that act on a daemon (`connect`, `stop`,
`restart`, `logs`, `transcript`, …) fall back to the single running daemon
when there is exactly one, so `--id` is only needed to disambiguate.
`JLD_DEBUG=1` traces client-side steps.

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
