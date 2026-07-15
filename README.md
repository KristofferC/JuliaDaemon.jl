# JuliaDaemon (`jld`)

[![CI](https://github.com/KristofferC/JuliaDaemon.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/KristofferC/JuliaDaemon.jl/actions/workflows/ci.yml)

`jld` keeps a Julia process alive for each of your projects, with
[Revise](https://github.com/timholy/Revise.jl) loaded, and lets you run code
in it from the shell. Package loading and compilation happen once, when the
daemon first starts. After that a `jld eval` or `jld run` takes a couple
hundred milliseconds, streams output as it is produced, and the exit code
tells you whether the code ran, threw, or never reached a daemon at all.

You are not limited to one daemon on the machine. Every project gets its
own, they all run side by side, and `jld` picks the right one from the
directory you are in. A single project can have several too (`--name`), and
`jld list` shows everything that is running.

The main audience is coding agents, which love to shell out `julia -e` and
would otherwise pay the full startup cost on every call, but it works just
as well by hand.

```sh
cd MyPkg
jld eval 'using MyPkg; MyPkg.foo()'   # first call starts the daemon and loads MyPkg
# edit src/…
jld run scratch.jl                    # the edit is already live, nothing reloads
jld connect                           # open your own REPL into the same session
```

## How it works

When you run `jld` it figures out which project you are in (`--project`,
`JULIA_PROJECT`, or the nearest `Project.toml`) and talks to that project's
daemon, starting one if needed. Separate projects and worktrees get separate
daemons on their own, and `--name` gives you several for the same project,
for example one per agent.

The daemon is an ordinary `julia --project=<proj>` with Revise loaded beside
it, from a private environment stacked onto `JULIA_LOAD_PATH`, so your
`Project.toml` is never touched. Every request runs `Revise.revise()` first.
If an edit could not be applied you get a `jld:` warning instead of silently
stale results.

Code evaluates into `Main` with the REPL's soft-scope rules. Variables stay
around between calls, `ans` is set, and requests run one at a time: if the
daemon is busy, the next request waits its turn and says so.

`jld connect` opens a REPL into the same session, so you can poke at what an
agent has built up, and it can see what you do. The wire protocol is
length-framed plain text with no serialization, which means any client julia
can talk to any daemon julia, and tab completion keeps working even while
the daemon is busy computing.

Interrupts are soft: the eval task gets an `InterruptException` at its next
yield point. A hot loop that never yields cannot be stopped that way, so both
`--timeout` and `jld interrupt --force` escalate: they keep interrupting for a
few seconds and then kill the daemon (never an interactive session) — a
runaway eval always terminates, at the cost of the warm state.

Errors print with runs of Base/stdlib/package frames folded away, keeping the
frames you can act on; `jld trace` retrieves the last error's full backtrace.
And `exit(n)` inside an eval does not take the daemon down: the client exits
with `n`, the daemon keeps running.

## Commands

`jld --help` prints the same reference. `eval`, `run`, and `connect` start
the daemon if it isn't running; everything else expects one.

### Running code

- `jld eval '<code>'` — run code in the daemon's `Main`. With no argument it
  reads stdin, so heredocs work.
- `jld run <file.jl>` — `include()` a file. The daemon changes to your
  shell's directory for the duration of the request, so relative paths mean
  what you think they mean.

Both take:

- `--scratch` — run in a throwaway module that can read `Main` but leaves
  nothing behind. Good for exploration you don't want polluting the session.
- `--module=M` — run inside `Main.M`, created if needed. Can't be combined
  with `--scratch`.
- `--timeout=SECS` — give up after SECS. The eval is interrupted, you get
  exit code 124, and the daemon keeps its compile state. If the eval never
  yields, the daemon is killed after a few seconds of grace instead (still
  exit 124); the next call starts a fresh one.
- `--max-output=N` — cap streamed output at roughly N bytes (`16k`, `1m`, …).
  The head and tail are kept and the middle is dropped with a marker, so a
  runaway `println` loop cannot flood the caller. Output that fits in
  head+tail is delivered in full.
- `--no-autostart` — normally `eval` and `run` start a daemon when none is
  running, and that first call sits through the whole package load. With
  this flag they fail fast instead (exit 3), for callers that only want an
  already-warm daemon.

### Test environments

`jld --test <cmd>` serves the package's *test* environment: test-only
dependencies are importable, so test code runs as it does under `Pkg.test()`,
but warm. It is a separate daemon (`<Pkg>-test-…` in `jld list`) beside the
regular one, and `--test` selects it for every command (`status`, `restart`,
`connect`, …).

If the package declares `test/` as a workspace project (`[workspace]`
`projects = ["test"]` in Project.toml), the daemon simply runs with `test/`
as the active project. Otherwise it activates the test environment at boot
with [TestEnv.jl](https://github.com/JuliaTesting/TestEnv.jl), which jld
installs into its private environment on first use.

```sh
jld --test run test/runtests.jl        # the full suite, warm
jld --test eval 'using Test, MyPkg; …' # anything needing test-only deps
```

### Lifecycle

- `jld start` — start the daemon ahead of time. `--startup='using MyPkg'`
  runs code at boot (repeat the flag for more) and is remembered, so a later
  `restart` runs it again; if it fails, the daemon stays up without it and
  `start`/`status` warn. `--threads=N` sets the number of eval threads;
  one extra interactive thread is always added, which is what keeps `status`
  and `connect` responsive while an eval is hogging the CPU. `--timeout`
  caps how long to wait for the daemon to come up.
- `jld restart` — stop and start again with the remembered options. This is
  what you want after redefining a struct on julia < 1.12.
- `jld interrupt` — interrupt the current eval at its next yield point. The
  daemon stays up. With `--force`, an eval that does not yield within a few
  seconds gets the daemon killed and restarted with its remembered options
  (never done to interactive sessions).
- `jld stop` — shut down cleanly. Refused if the target is somebody's
  interactive session (see below).
- `jld kill` — SIGKILL, no questions asked. Unlike `stop` this is not
  refused for sessions, so glance at `jld list` before using it on a daemon
  you didn't start.
- `jld gc` — clean up config, logs and transcripts left behind by dead
  daemons.

`jld start --idle-timeout=30m` (or `2h`, or seconds) makes the daemon stop
itself after that long without requests — useful when agents start daemons
that nobody remembers to stop. Remembered like `--startup`;
`--idle-timeout=0` on a restart clears it.

### Looking around

- `jld status` — what the daemon is up to: busy or idle, what it is running
  and for how long, pid, julia version, uptime, and a warning if Revise
  didn't load. Works even mid-eval.
- `jld list` — the daemons, with a `*` on the one your current directory
  targets. Dead ones are summarized on one line instead of listed;
  `--all` shows them as rows.
- `jld trace [id]` — the full backtrace of the last eval error. Errors shown
  by `eval`/`run` fold runs of internal frames (Base, stdlib, installed
  packages) down to their innermost frame, which names the throw site; this
  command has the whole thing when you need it. In a julia checkout, frames
  under the checkout always stay visible.
- `jld logs [-f]` — the daemon's log; the last 100 lines by default,
  `--lines=N` or `--all` for more, `-f` follows it.
- `jld transcript [id] [-f]` — everything that has been evaluated in the
  session, inputs and outputs, from `jld eval` and attached REPLs alike
  (long outputs are truncated). If you are joining a session someone else
  has been working in, read this first.
- `jld stacks [id]` — backtraces of what the daemon's tasks are doing right
  now. Useful for deciding between `interrupt` and `kill`.

### Interactive

- `jld connect [id]` — attach a REPL; the prompt reads `julia@<id>>`.
  Backspace on an empty line drops to a local `julia>` prompt, Ctrl-D exits.
  `--print` prints the socket path instead of attaching.
- `jld eval-repl '<code>'` — type into the attached REPL from the outside:
  the code is echoed at the prompt, evaluated there, and sets `ans`, exactly
  as if typed by hand. This is how an agent can show you something in your
  own REPL.

### Setup

- `jld setup` — (re)install the daemon environment for the chosen julia.
  Happens automatically on first use, so you rarely need it.
- `jld install` — install the agent skill, see [Install](#install).

### Exit codes

0 the code ran, 1 it threw (backtrace on stderr), 2 you called `jld` wrong,
3 the daemon can't be reached, 124 timed out, 130 interrupted. Code that
calls `exit(n)` gives you `n` — the daemon survives it.

## Flags

These work with every command; the eval-specific ones are listed above.

- `--project=PATH` — which project to serve. Defaults like plain julia:
  `JULIA_PROJECT`, else the nearest `Project.toml`, else the default
  environment.
- `--name=NAME` (env `JLD_NAME`) — a separate daemon for the same project.
  Handy when several agents share a directory.
- `--test` — serve the package's test environment in a separate daemon
  (test-only deps importable; see
  [Test environments](#test-environments)).
- `--id=ID` — target a specific daemon from `jld list`: the full id, any
  unique part of it, or its row number.
- `--julia=BIN` (env `JLD_JULIA`) — which julia the daemon runs.
- `--startup=CODE` — code to run at boot; may be repeated.
- `--threads=N` — eval threads (default 1, plus the interactive thread).
- `--timeout=SECS` — for eval/run, interrupt after SECS (killing the daemon
  if the eval never yields); for start, how long to wait.
- `--idle-timeout=T` — for start/restart, stop the daemon after T without
  requests (seconds, or `30m`, `2h`); remembered, `0` clears it.
- `--max-output=N` — for eval/run, cap streamed output at ~N bytes
  (`16k`, `1m`, …), keeping head and tail.
- `--no-revise` — run the daemon without Revise. Source edits then need a
  `jld restart` to be picked up, and `status` will say so. The choice is
  remembered like `--startup`; pass `--revise` to a later restart to switch
  back.

Outside a project, commands that act on a daemon (`connect`, `stop`, `logs`,
`transcript`, …) simply use the one running daemon if there is exactly one,
so you mostly don't need `--id`. Set `JLD_DEBUG=1` to watch what the client
is doing step by step.

## Serving an existing session

Your interactive REPL can be a daemon too:

```julia-repl
julia> using JuliaDaemon
julia> JuliaDaemon.serve()        # or serve(name="mysession")
```

It shows up in `jld list` (state `idle/repl`), and from there agents can
eval into it with `jld --id=<id> eval`, read the transcript (your typed
input included), look at its stacks, and paste into your prompt with
`jld eval-repl`. `jld stop` refuses to touch sessions; you end one by
exiting the REPL. Revise is used if the session has it and skipped
otherwise.

## Julia versions

`--julia=BIN` (or `JLD_JULIA`) decides which julia the daemon runs. A julia
source checkout is detected automatically: `jld eval` from inside one serves
the checkout with its in-tree `usr/bin/julia` build, an empty scratch
environment, and `Revise.track(Base)` at boot — Base edits apply live, no
setup. The daemon's own dependency (Revise) installs on first use into a
small named environment per minor version (`@jld-v1.12`, …), so the jld
installation itself can live on a read-only path. Before starting, jld
checks that Revise actually loads with that julia and project; on an
unreleased julia where the registry's Revise stack does not precompile, it
reinstalls the stack from master automatically (`jld setup --dev` by hand)
instead of launching a doomed daemon. And since the protocol is plain text,
the CLI and `jld connect` work across versions. When your dev build is
broken mid-rebase, `status`, `logs` and `stop` still work.

## Install

As a Pkg app (julia 1.12 or newer; the `jld` shim lands in `~/.julia/bin`,
keep that on PATH):

```
pkg> app add <this repo url>
$ jld install        # installs the agent skill (SKILL.md)
```

`install` copies the skill into `~/.agents/skills/` (the shared Agent Skills
location that opencode, Gemini CLI and others read) and into the skill
directories of agents that only read their own (`~/.claude`, `~/.codex`).
Run from a clone, `bin/jld install` also symlinks `~/.local/bin/jld` if
nothing named `jld` is on PATH yet.

State lives in `~/.cache/julia-daemon/<id>/` (config, log, transcript).
The tests are in `test/e2e.sh`.
