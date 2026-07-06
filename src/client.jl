# jld client: talks to a per-project Julia daemon over a unix socket.
# Runs with --compile=min and only stdlib deps, so it starts fast.

using Sockets
using TOML
using SHA

include(joinpath(@__DIR__, "protocol.jl"))

const JLD_HOME = dirname(@__DIR__)
const DAEMON_DEPS = ["Revise", "RemoteREPL"]
const SIGTERM_ = Cint(15)
const SIGKILL_ = Cint(9)

info(msg) = println(stderr, "jld: ", msg)
die(msg, code=2) = (info(msg); exit(code))

uv_kill(pid, sig) = ccall(:uv_kill, Cint, (Cint, Cint), pid, sig)
pid_alive(pid) = uv_kill(pid, Cint(0)) == 0

cache_root() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "julia-daemon")

struct Ctx
    project::String
    name::String
    id::String
    dir::String
    julia::String
end

function find_project(flag)
    p = flag !== nothing ? flag : get(ENV, "JULIA_PROJECT", nothing)
    if p !== nothing && !isempty(p)
        if startswith(p, "@") && p != "@."
            expanded = Base.load_path_expand(p)
            expanded === nothing && die("cannot expand project \"$p\"")
            p = expanded
        end
        path = abspath(expanduser(p))
        isfile(path) && (path = dirname(path))
        isdir(path) || die("project path does not exist: $path")
        if !isfile(joinpath(path, "Project.toml")) && !isfile(joinpath(path, "JuliaProject.toml"))
            die("no Project.toml in $path")
        end
        return realpath(path)
    end
    d = pwd()
    while true
        if isfile(joinpath(d, "Project.toml")) || isfile(joinpath(d, "JuliaProject.toml"))
            return realpath(d)
        end
        nd = dirname(d)
        nd == d && return nothing
        d = nd
    end
end

function make_ctx(flags)
    project = find_project(get(flags, "project", nothing))
    project === nothing && die("no Project.toml found upwards from $(pwd()); pass --project=<path> (or e.g. --project=@v1.12 for a default environment)")
    name = get(flags, "name", get(ENV, "JLD_NAME", ""))
    slug = replace(basename(project), r"[^A-Za-z0-9_.-]" => "-")
    h = bytes2hex(sha1(project * "\0" * name))[1:8]
    id = isempty(name) ? "$slug-$h" : "$slug-$name-$h"
    julia = get(flags, "julia", get(ENV, "JLD_JULIA", "julia"))
    jpath = Sys.which(julia)
    jpath === nothing && die("julia executable not found: $julia")
    Ctx(project, name, id, joinpath(cache_root(), id), jpath)
end

# ---- daemon environment (per julia minor version) ----

# Environment for julia subprocesses: drop LOAD_PATH/PROJECT overrides so the
# default stack applies (the Pkg app shim pins JULIA_LOAD_PATH to the app env,
# which has no @stdlib and would break `using Pkg` in children).
function default_julia_env()
    env = copy(ENV)
    delete!(env, "JULIA_LOAD_PATH")
    delete!(env, "JULIA_PROJECT")
    env
end

# Resolve which julia actually runs for this project and where it lives.
# The launcher (e.g. juliaup) may pick a channel based on the project's
# manifest, so `julia --version` without the project can lie; probe with the
# project and use the concrete binary from then on.
function probe_julia(julia, project)
    out = try
        readchomp(setenv(`$julia --startup-file=no --project=$project -e 'print(VERSION, "\0", Sys.BINDIR)'`, default_julia_env()))
    catch
        die("failed to run $julia")
    end
    parts = split(out, '\0')
    length(parts) == 2 || die("unexpected julia probe output: \"$out\"")
    ver, bindir = String(parts[1]), String(parts[2])
    bin = joinpath(bindir, "julia")
    (ver, isfile(bin) ? bin : julia)
end

minor_of(ver) = (m = match(r"^(\d+)\.(\d+)\.", ver); m === nothing ? die("cannot parse julia version \"$ver\"") : "$(m[1]).$(m[2])")

# The daemon's deps live in a named depot environment (@jld-v1.X), keyed by
# julia minor version. Kept out of JLD_HOME so the installation can be
# read-only; the depot must be writable for Pkg to work at all.
function ensure_env(julia, version; force=false)
    isempty(Base.DEPOT_PATH) && die("empty DEPOT_PATH; cannot locate a julia depot")
    minor = minor_of(version)
    envdir = joinpath(first(Base.DEPOT_PATH), "environments", "jld-v$minor")
    if force || !isfile(joinpath(envdir, "Manifest.toml"))
        mkpath(envdir)
        info("setting up daemon environment @jld-v$minor (one-time, installs $(join(DAEMON_DEPS, ", ")))...")
        code = "using Pkg; Pkg.add($(repr(DAEMON_DEPS)))"
        run(pipeline(setenv(`$julia --startup-file=no --project=$envdir -e $code`, default_julia_env()), stdout=stderr, stderr=stderr))
    end
    envdir
end

# ---- daemon state ----

# Returns the daemon state Dict, `:timeout` if the socket connects but the
# daemon does not answer (wedged in a non-yielding eval), or nothing if not
# running.
function try_ping(dir; timeout=2.0)
    sockpath = joinpath(dir, "sock")
    issocket(sockpath) || return nothing
    conn = try
        connect(sockpath)
    catch
        return nothing
    end
    try
        write_frame(conn, "ping")
        t = @async read_frame(conn)
        timedwait(() -> istaskdone(t), timeout; pollint=0.05) === :ok || return :timeout
        kind, payload = fetch(t)
        kind == "pong" || return nothing
        return TOML.parse(payload)
    catch
        return nothing
    finally
        close(conn)
    end
end

ping_alive(dir) = try_ping(dir) isa Dict

read_toml(path) = isfile(path) ? (try TOML.parsefile(path) catch; nothing end) : nothing
daemon_toml(ctx) = read_toml(joinpath(ctx.dir, "daemon.toml"))
config_toml(ctx) = read_toml(joinpath(ctx.dir, "config.toml"))

function daemon_pid(ctx)
    dt = daemon_toml(ctx)
    dt === nothing ? nothing : get(dt, "pid", nothing)
end

log_path(ctx) = joinpath(ctx.dir, "daemon.log")

function log_tail(ctx, n)
    isfile(log_path(ctx)) || return ""
    lines = readlines(log_path(ctx))
    join(lines[max(1, end-n+1):end], "\n") * "\n"
end

# ---- commands ----

function cmd_start(ctx, flags)
    if try_ping(ctx.dir) !== nothing
        info("daemon already running (id $(ctx.id)); `jld restart` to reload, or `jld --name=<n> start` for an additional daemon on this project")
        return
    end
    mkpath(ctx.dir)
    rm(joinpath(ctx.dir, "sock"), force=true)
    rm(joinpath(ctx.dir, "daemon.toml"), force=true)
    ver, julia = probe_julia(ctx.julia, ctx.project)
    envdir = ensure_env(julia, ver)

    startup = get(flags, "startup", String[])
    threads = get(flags, "threads", nothing)
    cfg = Dict{String,Any}(
        "project" => ctx.project, "name" => ctx.name, "julia" => julia,
        "startup" => startup,
    )
    threads !== nothing && (cfg["threads"] = threads)
    open(joinpath(ctx.dir, "config.toml"), "w") do io
        TOML.print(io, cfg)
    end

    logio = open(log_path(ctx), "a")
    println(logio, "=== jld daemon launch $(Libc.strftime("%F %T", time())) ===")
    flush(logio)

    env = copy(ENV)
    env["JULIA_LOAD_PATH"] = "@:$envdir:@stdlib"
    delete!(env, "JULIA_PROJECT")

    jargs = ["--startup-file=no", "--project=$(ctx.project)"]
    # N default threads for evals + 1 interactive thread for the control plane
    # (ping/status/queueing/RemoteREPL stay responsive during CPU-bound evals).
    push!(jargs, "--threads=$(something(threads, "1")),1")
    dargs = ["--dir=$(ctx.dir)"]
    append!(dargs, ["--startup=$s" for s in startup])

    cmd = `$julia $jargs $(joinpath(JLD_HOME, "src", "daemon_main.jl")) $dargs`
    proc = run(pipeline(detach(setenv(cmd, env)), stdin=devnull, stdout=logio, stderr=logio), wait=false)
    close(logio)

    info("starting daemon for $(ctx.project) (id $(ctx.id))...")
    timeout = parse(Float64, get(flags, "timeout", "300"))
    t0 = time()
    lastmsg = time()
    while time() - t0 < timeout
        if process_exited(proc)
            info("daemon exited during startup; last log lines:")
            print(stderr, log_tail(ctx, 30))
            exit(1)
        end
        st = try_ping(ctx.dir)
        if st isa Dict
            info("daemon ready in $(round(time() - t0, digits=1))s (pid $(st["pid"]), julia $(st["julia_version"]))")
            return
        end
        if time() - lastmsg > 5
            info("waiting for daemon to load... ($(round(Int, time() - t0))s)")
            lastmsg = time()
        end
        sleep(0.2)
    end
    info("timed out after $(timeout)s waiting for daemon; it may still be loading. Check `jld logs`.")
    exit(1)
end

# Reuse options recorded by a previous `jld start` unless overridden now.
function apply_cfg(ctx, flags, cfg)
    cfg === nothing && return ctx
    haskey(flags, "startup") || (flags["startup"] = get(cfg, "startup", String[]))
    !haskey(flags, "threads") && haskey(cfg, "threads") && (flags["threads"] = cfg["threads"])
    if !haskey(flags, "julia") && !haskey(ENV, "JLD_JULIA")
        j = get(cfg, "julia", "")
        isfile(j) && return Ctx(ctx.project, ctx.name, ctx.id, ctx.dir, j)
    end
    ctx
end

function ensure_running(ctx, flags)
    try_ping(ctx.dir) !== nothing && return
    get(flags, "no-autostart", false) && die("daemon not running (autostart disabled)", 3)
    cmd_start(apply_cfg(ctx, flags, config_toml(ctx)), flags)
end

function cmd_exec(ctx, kind, arg, flags)
    local code
    if kind == "eval"
        code = arg === nothing ? read(stdin, String) : arg
        isempty(strip(code)) && die("no code given")
    else
        arg === nothing && die("usage: jld run <file.jl>")
        code = abspath(arg)
        isfile(code) || die("no such file: $code")
    end
    ensure_running(ctx, flags)

    conn = try
        connect(joinpath(ctx.dir, "sock"))
    catch
        die("cannot connect to daemon socket; try `jld restart`", 3)
    end
    req = Dict("kind" => kind, "code" => code, "cwd" => pwd())
    write_frame(conn, "req", sprint(io -> TOML.print(io, req)))
    exit(stream_response(ctx, conn, flags))
end

function stream_response(ctx, conn, flags)
    Base.exit_on_sigint(false)
    sendlock = ReentrantLock()
    send_interrupt() = try
        lock(sendlock) do
            write_frame(conn, "interrupt")
        end
    catch
    end
    timedout = Ref(false)
    timer = nothing
    if haskey(flags, "timeout")
        secs = parse(Float64, flags["timeout"])
        timer = Timer(secs) do _
            timedout[] = true
            info("timeout after $(secs)s, interrupting daemon eval")
            send_interrupt()
        end
    end

    status = Ref("error")
    lost = Ref(false)
    got_frame = Ref(false)
    hint = Timer(5) do _
        got_frame[] || info("no response from daemon yet; it may be busy in a non-yielding computation (`jld status`, `jld kill` if stuck)")
    end
    reader = @async begin
        while true
            kind, payload = read_frame(conn)
            got_frame[] = true
            if kind == "out"
                write(stdout, payload); flush(stdout)
            elseif kind == "err"
                write(stderr, payload); flush(stderr)
            elseif kind == "warn"
                println(stderr, "jld: ", payload); flush(stderr)
            elseif kind == "result"
                println(stdout, payload); flush(stdout)
            elseif kind == "done"
                status[] = get(TOML.parse(payload), "status", "error")
                return
            elseif kind == "eof"
                lost[] = true
                return
            end # other kinds (e.g. "ack") just mark liveness
        end
    end

    interrupts = 0
    while !istaskdone(reader)
        try
            wait(reader)
        catch e
            if e isa InterruptException
                interrupts += 1
                interrupts >= 3 && (info("giving up"); exit(130))
                info("interrupting daemon eval (Ctrl-C again to force client exit)")
                send_interrupt()
            elseif e isa TaskFailedException
                lost[] = true
                break
            else
                rethrow()
            end
        end
    end
    timer !== nothing && close(timer)
    close(hint)
    close(conn)

    if lost[]
        info("connection to daemon lost (crashed?); see `jld logs`")
        return 3
    end
    status[] == "ok" && return 0
    status[] == "interrupted" && return timedout[] ? 124 : 130
    return 1
end

function cmd_stop(ctx)
    sockpath = joinpath(ctx.dir, "sock")
    if issocket(sockpath)
        try
            conn = connect(sockpath)
            write_frame(conn, "shutdown")
            read_frame(conn)
            close(conn)
            info("daemon stopped")
            return
        catch
        end
    end
    pid = daemon_pid(ctx)
    if pid !== nothing && pid_alive(pid)
        uv_kill(pid, SIGTERM_)
        info("sent SIGTERM to pid $pid")
    else
        info("daemon not running")
    end
    rm(sockpath, force=true)
end

function cmd_kill(ctx)
    pid = daemon_pid(ctx)
    if pid !== nothing && pid_alive(pid)
        uv_kill(pid, SIGKILL_)
        info("killed pid $pid")
    else
        info("daemon not running")
    end
    rm(joinpath(ctx.dir, "sock"), force=true)
end

function cmd_restart(ctx, flags)
    cfg = config_toml(ctx)
    cmd_stop(ctx)
    pid = daemon_pid(ctx)
    if pid !== nothing
        t0 = time()
        while pid_alive(pid) && time() - t0 < 10
            sleep(0.1)
        end
        pid_alive(pid) && (uv_kill(pid, SIGKILL_); sleep(0.2))
    end
    cmd_start(apply_cfg(ctx, flags, cfg), flags)
end

function cmd_interrupt(ctx)
    conn = try
        connect(joinpath(ctx.dir, "sock"))
    catch
        die("daemon not running", 3)
    end
    write_frame(conn, "interrupt")
    kind, payload = read_frame(conn)
    close(conn)
    if kind == "done" && contains(payload, "ok")
        info("interrupt requested; it lands at the eval's next yield point (CPU-bound code may run to completion first — `jld kill` if stuck)")
    else
        info("nothing to interrupt (daemon idle)")
    end
end

function cmd_status(ctx)
    st = try_ping(ctx.dir)
    dt = daemon_toml(ctx)
    println("id:       ", ctx.id)
    println("project:  ", ctx.project)
    if !(st isa Dict)
        pid = dt === nothing ? nothing : get(dt, "pid", nothing)
        if st === :timeout
            println("state:    unresponsive (pid $pid busy in a non-yielding eval, or still loading; `jld kill` if stuck)")
        elseif pid !== nothing && pid_alive(pid)
            println("state:    unresponsive (pid $pid alive but not answering; still loading or wedged)")
        else
            println("state:    not running")
        end
        return
    end
    println("state:    ", st["busy"] ? "busy" : "idle")
    st["busy"] && println("running:  `$(get(st, "current", "?"))` for $(get(st, "current_elapsed", "?"))s")
    println("pid:      ", st["pid"])
    println("julia:    ", st["julia_version"])
    println("uptime:   ", round(st["uptime"] / 60, digits=1), " min")
    if dt !== nothing
        println("REPL:     jld connect   (RemoteREPL on localhost:$(dt["repl_port"]))")
    end
    isfile(joinpath(ctx.dir, "transcript.log")) &&
        println("history:  jld transcript   ($(joinpath(ctx.dir, "transcript.log")))")
end

function cmd_list()
    root = cache_root()
    entries = isdir(root) ? sort(readdir(root)) : String[]
    rows = Vector{NTuple{5,String}}()
    for id in entries
        dir = joinpath(root, id)
        cfg = read_toml(joinpath(dir, "config.toml"))
        cfg === nothing && continue
        st = try_ping(dir)
        state = st isa Dict ? (st["busy"] ? "busy" : "idle") :
                st === :timeout ? "unresponsive" : "dead"
        dt = read_toml(joinpath(dir, "daemon.toml"))
        pid = st isa Dict ? string(st["pid"]) :
              st === :timeout && dt !== nothing ? string(get(dt, "pid", "-")) : "-"
        port = dt !== nothing ? string(get(dt, "repl_port", "-")) : "-"
        push!(rows, (id, state, pid, port, get(cfg, "project", "?")))
    end
    isempty(rows) && (println("no daemons"); return)
    header = ("ID", "STATE", "PID", "REPL", "PROJECT")
    widths = [maximum(length.([header[i], (r[i] for r in rows)...])) for i in 1:4]
    printrow(r) = println(join([rpad(r[i], widths[i]) for i in 1:4], "  "), "  ", r[5])
    printrow(header)
    foreach(printrow, rows)
end

known_ids() = (root = cache_root(); isdir(root) ?
    filter(d -> isfile(joinpath(root, d, "config.toml")), sort(readdir(root))) : String[])

function ctx_from_id(idarg)
    ids = known_ids()
    matches = filter(d -> d == idarg || startswith(d, idarg), ids)
    isempty(matches) && die("no daemon matching \"$idarg\" (see `jld list`)", 3)
    if length(matches) > 1 && !(idarg in matches)
        # Prefer a unique running daemon over dead prefix-siblings.
        running = filter(id -> ping_alive(joinpath(cache_root(), id)), matches)
        length(running) == 1 ||
            die("ambiguous id \"$idarg\": matches $(join(matches, ", "))")
        matches = running
    end
    id = idarg in matches ? idarg : only(matches)
    dir = joinpath(cache_root(), id)
    cfg = read_toml(joinpath(dir, "config.toml"))
    cfg === nothing && die("unreadable daemon state in $dir")
    Ctx(get(cfg, "project", ""), get(cfg, "name", ""), id, dir, get(cfg, "julia", "julia"))
end

# With no project and no id: connect to the single running daemon, if unique.
function ctx_from_only_running()
    running = filter(id -> ping_alive(joinpath(cache_root(), id)), known_ids())
    isempty(running) && die("no running daemons", 3)
    if length(running) > 1
        info("multiple daemons running; pick one with `jld connect <id>`:")
        cmd_list()
        exit(2)
    end
    ctx_from_id(only(running))
end

# Paste code into an attached `jld connect` REPL, as if typed there.
function cmd_eval_repl(ctx, arg)
    code = arg === nothing ? read(stdin, String) : arg
    isempty(strip(code)) && die("no code given")
    sockpath = joinpath(ctx.dir, "repl.sock")
    issocket(sockpath) || die("no REPL attached to $(ctx.id); start one with `jld connect`", 3)
    conn = try
        connect(sockpath)
    catch
        die("attached REPL is gone (stale socket); reconnect with `jld connect`", 3)
    end
    write_frame(conn, "paste", code)
    kind, _ = read_frame(conn)
    close(conn)
    kind == "done" || die("REPL did not acknowledge the paste", 3)
end

# eval-repl outside a project: target the unique attached REPL, if any.
function ctx_for_eval_repl(flags)
    find_project(get(flags, "project", nothing)) !== nothing && return make_ctx(flags)
    attached = filter(id -> issocket(joinpath(cache_root(), id, "repl.sock")), known_ids())
    isempty(attached) && die("no attached REPL found; start one with `jld connect`", 3)
    length(attached) > 1 &&
        die("multiple attached REPLs ($(join(attached, ", "))); run from the project or pass --project", 3)
    ctx_from_id(only(attached))
end

function cmd_connect(ctx, flags)
    st = try_ping(ctx.dir)
    st === :timeout && die("daemon is unresponsive (busy in a non-yielding eval?); it cannot accept a REPL until the eval yields or finishes — see `jld status`, or `jld kill` if stuck", 3)
    st === nothing && die("daemon not running; start it with `jld start`", 3)
    st["busy"] && info("note: daemon is busy (`$(get(st, "current", "?"))` for $(get(st, "current_elapsed", "?"))s); the REPL shares the session and runs alongside it")
    dt = daemon_toml(ctx)
    port = dt["repl_port"]
    dver = string(get(dt, "julia_version", "?"))
    if get(flags, "print", false)
        println("RemoteREPL server: localhost:$port (daemon julia $dver)")
        println("From a Julia $dver REPL with RemoteREPL installed:")
        println("  using RemoteREPL; connect_repl($port)")
        return
    end
    # Use the daemon's own julia binary: RemoteREPL requires matching versions.
    julia = joinpath(string(get(dt, "julia_bindir", "")), "julia")
    if !isfile(julia)
        julia = ctx.julia
        info("warning: daemon's julia binary not found, using $julia; RemoteREPL needs julia $dver")
    end
    envdir = ensure_env(julia, dver)
    info("connecting to $(ctx.id) on port $port (press '>' for the remote prompt, backspace to leave it, Ctrl-D to exit)")
    env = copy(ENV)
    env["JULIA_LOAD_PATH"] = "@:$envdir:@stdlib"
    script = joinpath(JLD_HOME, "src", "connect_repl.jl")
    inputsock = joinpath(ctx.dir, "repl.sock")
    p = run(ignorestatus(setenv(`$julia --project=$(ctx.project) -i $script $port $inputsock`, env)))
    exit(p.exitcode)
end

function cmd_logs(ctx, flags)
    isfile(log_path(ctx)) || die("no log file at $(log_path(ctx))")
    if get(flags, "follow", false)
        run(`tail -n 40 -f $(log_path(ctx))`)
    else
        print(log_tail(ctx, 100))
    end
end

function cmd_transcript(ctx, flags)
    path = joinpath(ctx.dir, "transcript.log")
    isfile(path) || die("no transcript for $(ctx.id) yet", 3)
    if get(flags, "follow", false)
        run(`tail -n 100 -f $path`)
    else
        write(stdout, read(path))
    end
end

function install_link(link, target)
    if islink(link)
        readlink(link) == target && (info("already installed: $link"); return)
        rm(link)
    elseif ispath(link)
        die("$link exists and is not a symlink; remove it first")
    end
    mkpath(dirname(link))
    symlink(target, link)
    info("installed $link -> $target")
end

function cmd_install()
    # Copy the skill rather than symlink: app-installed package directories
    # are versioned and move on update, which would leave a dangling link.
    src = joinpath(JLD_HOME, "skill")
    dst = joinpath(homedir(), ".claude", "skills", "julia-daemon")
    islink(dst) && rm(dst)
    mkpath(dst)
    for f in readdir(src)
        cp(joinpath(src, f), joinpath(dst, f); force=true)
    end
    info("installed skill: $dst")
    # A bin symlink is only needed when jld is not already reachable
    # (the Pkg app shim in ~/.julia/bin makes this unnecessary).
    if Sys.which("jld") === nothing
        install_link(joinpath(homedir(), ".local", "bin", "jld"), joinpath(JLD_HOME, "bin", "jld"))
        bindir = joinpath(homedir(), ".local", "bin")
        any(p -> abspath(p) == bindir, split(get(ENV, "PATH", ""), ':')) ||
            info("note: $bindir is not on PATH")
    end
end

function cmd_setup(ctx)
    ver, julia = probe_julia(ctx.julia, ctx.project)
    ensure_env(julia, ver, force=true)
    info("daemon environment ready")
end

const HELP = """
jld - persistent Revise-enabled Julia daemon, one per project

usage: jld [flags] <command> [args]

commands:
  eval '<code>'     evaluate code in the daemon (reads stdin if no arg); autostarts
  run <file.jl>     include() a file in the daemon; autostarts
  start             start the daemon (pre-warm); --startup='using Foo' to run code at boot
  restart           restart (needed after struct redefinitions); keeps recorded --startup
  stop | kill       stop gracefully | SIGKILL
  interrupt         interrupt the current eval at its next yield point; daemon survives
  status [--all]    daemon state for this project; all daemons if --all or outside a project
  list              list all daemons
  connect [id]      attach an interactive REPL (RemoteREPL) to this project's daemon,
                    or to any daemon by id/prefix (see `jld list`); outside a project
                    with no id, connects to the single running daemon
  eval-repl '<code>'  paste code into the attached `jld connect` REPL, exactly as if
                    typed there (echoed at the prompt, output shown, ans set)
  transcript [id] [-f]  print the session transcript: every input + output evaluated
                    in the daemon (jld eval/run and remote REPL), output truncated
                    per entry — lets an agent read the context of a running session
  logs [-f]         show daemon log
  setup             (re)install the daemon environment for the selected julia
  install           install the Claude Code skill (+ ~/.local/bin/jld symlink if jld is not on PATH)

flags:
  --project=PATH    project to serve (default: JULIA_PROJECT or nearest Project.toml)
  --name=NAME       distinct daemon for the same project (env: JLD_NAME)
  --julia=BIN       julia executable for the daemon (env: JLD_JULIA, default: julia)
  --startup=CODE    code to run at daemon boot (repeatable; with start/restart)
  --threads=N       daemon eval threads (default 1; +1 interactive thread is always
                    added so status/queueing/REPL work during CPU-bound evals)
  --timeout=SECS    eval/run: interrupt after SECS (exit 124); start: wait limit
  --no-autostart    fail instead of autostarting (eval/run)

exit codes: 0 ok, 1 julia error, 2 usage, 3 daemon unavailable, 124 timeout, 130 interrupted

The daemon evaluates into Main with REPL soft-scope semantics and calls
Revise.revise() before every request, so source edits under the project apply
without reloading. Struct layout changes require `jld restart`.
"""

function parse_cli(args)
    flags = Dict{String,Any}()
    pos = String[]
    for a in args
        if a == "-f"
            flags["follow"] = true
        elseif startswith(a, "--")
            if contains(a, "=")
                k, v = split(a[3:end], "=", limit=2)
                if k == "startup"
                    push!(get!(Vector{String}, flags, "startup"), String(v))
                elseif k in ("project", "name", "julia", "threads", "timeout")
                    flags[String(k)] = String(v)
                else
                    die("unknown flag --$k")
                end
            else
                k = a[3:end]
                k in ("no-autostart", "print", "follow", "help", "all") || die("unknown flag --$k")
                flags[k] = true
            end
        else
            push!(pos, a)
        end
    end
    (flags, pos)
end

function run_cli(args::Vector{String})
    flags, pos = parse_cli(args)
    if isempty(pos) || get(flags, "help", false) || (length(pos) == 1 && pos[1] == "help")
        print(HELP)
        return
    end
    cmd = pos[1]
    if cmd == "list"
        cmd_list()
        return
    elseif cmd == "install"
        cmd_install()
        return
    elseif cmd == "status"
        if get(flags, "all", false) || find_project(get(flags, "project", nothing)) === nothing
            cmd_list()
        else
            cmd_status(make_ctx(flags))
        end
        return
    elseif cmd == "connect"
        ctx = if length(pos) >= 2
            ctx_from_id(pos[2])
        elseif find_project(get(flags, "project", nothing)) === nothing
            ctx_from_only_running()
        else
            make_ctx(flags)
        end
        cmd_connect(ctx, flags)
        return
    elseif cmd == "eval-repl"
        cmd_eval_repl(ctx_for_eval_repl(flags), length(pos) >= 2 ? pos[2] : nothing)
        return
    elseif cmd == "transcript"
        ctx = if length(pos) >= 2
            ctx_from_id(pos[2])
        elseif find_project(get(flags, "project", nothing)) === nothing
            ctx_from_only_running()
        else
            make_ctx(flags)
        end
        cmd_transcript(ctx, flags)
        return
    end
    ctx = make_ctx(flags)
    if cmd == "eval"
        cmd_exec(ctx, "eval", length(pos) >= 2 ? pos[2] : nothing, flags)
    elseif cmd == "run"
        cmd_exec(ctx, "include", length(pos) >= 2 ? pos[2] : nothing, flags)
    elseif cmd == "start"
        cmd_start(ctx, flags)
    elseif cmd == "stop"
        cmd_stop(ctx)
    elseif cmd == "kill"
        cmd_kill(ctx)
    elseif cmd == "restart"
        cmd_restart(ctx, flags)
    elseif cmd == "interrupt"
        cmd_interrupt(ctx)
    elseif cmd == "logs"
        cmd_logs(ctx, flags)
    elseif cmd == "setup"
        cmd_setup(ctx)
    else
        die("unknown command \"$cmd\" (see jld --help)")
    end
end

# Exit quietly when stdout goes away mid-write (e.g. `jld list | head`).
function cli_main(args)
    try
        run_cli(args)
    catch e
        e isa Base.IOError && occursin("EPIPE", e.msg) && exit(0)
        rethrow()
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    cli_main(ARGS)
end
