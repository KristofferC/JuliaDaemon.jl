# JuliaDaemon (jld) — agent handoff notes

`jld` keeps one persistent, Revise-enabled Julia daemon per project so agents
(and humans) pay package load/compile latency once. Everything speaks a
length-framed plain-text protocol over a unix socket / Windows named pipe —
no Serialization, so any client julia can talk to any daemon julia.

## Layout

- `bin/jld` — bash shim → `src/client.jl` (stdlib-only, `--compile=min`, ~0.15s)
- `src/client.jl` — the CLI. Context resolution (project → id hash), daemon
  spawn, streaming, all commands.
- `src/daemon.jl` — module `JLDDaemon`, script-included into Main by
  `src/daemon_main.jl` (spawned daemons) or by `JuliaDaemon.serve()`
  (turning an existing REPL session into a daemon).
- `src/protocol.jl` — framing, socket paths, `JLD_PROTO`. Included everywhere.
- `src/connect_repl.jl` — `jld connect`: a LineEdit REPL mode (`julia@<id>>`)
  speaking the same protocol. `src/repl_input.jl` — eval-repl paste machinery.
- `src/JuliaDaemon.jl` — package wrapper: `@main` for the Pkg app
  (`pkg> app add …` installs a `jld` shim), `serve()` for sessions.
- Daemon deps (Revise only) live in depot envs `@jld-v1.X`, stacked via
  `JULIA_LOAD_PATH`; per julia minor version. Never touch the target project.
- State: `~/.cache/julia-daemon/<id>/` (config.toml, daemon.toml, daemon.log,
  transcript.log). Sockets: short per-user runtime dir (see pitfalls).

## Hard-won invariants — read before touching anything

- **World age, four times over.** Anything that reflects over bindings created
  by *earlier requests* (rendering results, formatting errors, resolving
  `--module`, building scratch modules) must run through `invokelatest`.
  Tasks capture their creation world: overrides (method replacement) must
  happen before the serving tasks are spawned, or the spawn itself needs
  `invokelatest`.
- **Windows handle inheritance.** Never spawn a long-lived child through
  libuv from a client whose stdio may be a caller's capture pipe —
  `CreateProcess(bInheritHandles=TRUE)` leaks it and `$(jld eval …)` hangs
  until the daemon dies. Daemons spawn via PowerShell `Start-Process`
  without redirections (ShellExecute: env passes, zero handles) and open
  their own log (`--log=`). Also: `JULIA_LOAD_PATH` separator is `;` on
  Windows; `strftime` lacks `%T`/`%F`; named pipes have no fs entry (probe by
  connecting, never `issocket`).
- **macOS socket path cap (~104 bytes).** Sockets live in
  `XDG_RUNTIME_DIR/jld` (else `tempdir()/jld-<uid>`), named by a hash of the
  state dir. Clients fall back to the legacy `<statedir>/sock` so pre-move
  daemons stay reachable.
- **The Pkg app shim pins `JULIA_LOAD_PATH`** to the app env (no `@stdlib`).
  Every julia subprocess the client spawns must use `default_julia_env()`.
- **juliaup lies without the project**: the launcher picks channels from the
  project manifest, so version probing is `probe_julia(julia, project)` and
  the concrete `Sys.BINDIR` binary is recorded and reused.
- **Stale daemons after upgrades** are the recurring foot-gun (fields
  silently ignored, old sockets). Ping replies carry `proto`/`revise`/`kind`;
  the client warns on mismatch. When testing changes, `restart` daemons.
- **Never signal sessions.** `jld stop` is refused daemon-side for
  `kind=="session"`, and the client's signal fallback refuses too — a bug
  here kills the user's interactive REPL. Shutdown handshake gets one retry
  (rare transient EPIPE, root cause unfound).
- Control plane (ping/status/completions/queueing) lives on an interactive
  thread (`-t N,1`); evals on the default pool. That is why `status`/`stacks`
  work during CPU-bound evals. Plain-`julia` sessions lack this.

## Testing discipline

- `test/e2e.sh` — hermetic (own `XDG_CACHE_HOME`); ~35 checks incl. session
  mode, gc, transcript, completion protocol. `test/repl.jl` — drives
  `jld connect` through a real pty (posix only). `test/matrix.sh <julias…>` —
  full daemon×client cross product.
- **Never run other jld commands or tests concurrently with a matrix run** —
  earlier "failures" were self-inflicted cross-talk.
- Scripted source edits must assert every replacement matched — two past
  incidents of silent no-op patches produced phantom regressions.
- CI (`.github/workflows/ci.yml`): julia 1.12 + pre × linux/macos/windows
  gate; **nightly is informational only** (currently red because released
  JuliaInterpreter doesn't build on julia master — `nteltype` change; fixed
  on their master, heals when they tag). Debug levers: `JLD_E2E_TRACE=1`
  (bash -x + per-check stderr), `JLD_DEBUG=1` (client-side step tracing).
- Daemons run without Revise if it fails to load — loudly (start warning,
  `status` line, log). Check that before chasing "Revise broken" reports.

## Working conventions

- Push to master after local e2e (+ repl.jl when the REPL surface changed)
  is green; CI is the cross-platform gate. Watch runs with
  `gh run list/view -R KristofferC/JuliaDaemon.jl`.
- The user's `jld` on PATH may be the Pkg app shim running *pushed* master —
  test with `~/julia/JuliaDaemon.jl/bin/jld` (checkout) and remember shim
  users need `Pkg.Apps.add(url=…)` to refresh (`Pkg.Apps.update` by app name
  is broken upstream; use the package name).
- The user's own daemons (e.g. Pkg.jl, PerfDyad) may be running — don't
  restart/kill them; use scratchpad ToyPkg daemons with `--name` for tests.
- Skill lives in `skill/SKILL.md`; `jld install` copies it to
  `~/.agents/skills` + `~/.claude`/`~/.codex`. Keep it in sync with CLI
  changes and re-run `jld install` after editing.

## Roadmap (agreed with the user)

Next up, in order:
1. **`jld test [file]`** — companion daemon `<proj>-test` started with
   `using TestEnv; TestEnv.activate()` so scratch tests get test-only deps,
   Revise-live. Default file `test/runtests.jl`.
2. **`jld check`** — run `Revise.revise()` + report queue_errors only
   ("edits applied cleanly" / list of parse-apply failures), no evaluation.
   Sub-second gate for the agent edit loop.
3. **`jld bench 'expr'` / `jld profile 'expr'`** — warmup + repeated timing
   (+allocs; BenchmarkTools when loadable in the project, honest fallback),
   and Profile-report-of-expression (reuse the `stacks` machinery).

Backlog (cheap, agreed useful): `jld summary` (loaded pkgs + varinfo-style
Main table + transcript tail — session handoff in one shot), `--json`
envelope for eval/run, error source-context (append source lines around user
frames on errors). Rejected: anything that reimplements a unix tool
(transcript is a plain file — tail/grep it).
