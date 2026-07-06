# jld client: talks to a per-project Julia daemon over a unix socket.
# Runs with --compile=min and only stdlib deps, so it starts fast.

using Sockets
using TOML
using SHA

include(joinpath(@__DIR__, "protocol.jl"))

const JLD_HOME = dirname(@__DIR__)
const DAEMON_DEPS = ["Revise"]
const SIGTERM_ = Cint(15)
const SIGKILL_ = Cint(9)

info(msg) = println(stderr, "jld: ", msg)
dbg(msg) = haskey(ENV, "JLD_DEBUG") && info("debug [$(Libc.strftime("%T", time()))]: " * msg)
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

function find_project(flag; default_env=false)
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
        if nd == d
            default_env || return nothing
            # No project anywhere upwards: fall back to the default
            # environment, like plain `julia` does.
            def = Base.load_path_expand("@v#.#")
            def === nothing && return nothing
            path = dirname(def)
            mkpath(path)
            return realpath(path)
        end
        d = nd
    end
end

function make_ctx(flags)
    project = find_project(get(flags, "project", nothing); default_env=true)
    project === nothing && die("no project found and cannot resolve a default environment; pass --project=<path>")
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
    # Re-resolve when the env is missing OR was created by an older jld with
    # a different dependency list.
    havedeps = try
        prj = TOML.parsefile(joinpath(envdir, "Project.toml"))
        all(d -> haskey(get(prj, "deps", Dict()), d), DAEMON_DEPS)
    catch
        false
    end
    if force || !isfile(joinpath(envdir, "Manifest.toml")) || !havedeps
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
    dbg("ping: connecting to $(daemon_sock(dir))")
    conn = try
        connect(daemon_sock(dir))
    catch
        dbg("ping: no listener")
        return nothing
    end
    dbg("ping: connected")
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
    chmod(dirname(ctx.dir), 0o700)
    chmod(ctx.dir, 0o700)  # the socket grants code execution as this user
    Sys.iswindows() || rm(daemon_sock(ctx.dir), force=true)
    rm(joinpath(ctx.dir, "daemon.toml"), force=true)
    dbg("start: probing julia")
    ver, julia = probe_julia(ctx.julia, ctx.project)
    dbg("start: julia $ver at $julia")
    envdir = ensure_env(julia, ver)
    dbg("start: env ready at $envdir")

    startup = get(flags, "startup", String[])
    threads = get(flags, "threads", nothing)
    cfg = Dict{String,Any}(
        "project" => ctx.project, "name" => ctx.name, "julia" => julia,
        "startup" => startup,
    )
    threads !== nothing && (cfg["threads"] = threads)
    cfgtmp = joinpath(ctx.dir, ".config.toml.tmp")
    open(cfgtmp, "w") do io
        TOML.print(io, cfg)
    end
    mv(cfgtmp, joinpath(ctx.dir, "config.toml"), force=true)

    logio = open(log_path(ctx), "a")
    println(logio, "=== jld daemon launch $(Libc.strftime("%F %T", time())) ===")
    flush(logio)

    env = copy(ENV)
    sep = Sys.iswindows() ? ";" : ":"
    env["JULIA_LOAD_PATH"] = join(["@", envdir, "@stdlib"], sep)
    delete!(env, "JULIA_PROJECT")

    jargs = ["--startup-file=no", "--project=$(ctx.project)"]
    # N default threads for evals + 1 interactive thread for the control plane
    # (ping/status/queueing/the attached REPL stay responsive during CPU-bound evals).
    push!(jargs, "--threads=$(something(threads, "1")),1")
    dargs = ["--dir=$(ctx.dir)"]
    append!(dargs, ["--startup=$s" for s in startup])

    cmd = `$julia $jargs $(joinpath(JLD_HOME, "src", "daemon_main.jl")) $dargs`
    dbg("start: spawning daemon")
    proc = run(pipeline(detach(setenv(cmd, env)), stdin=devnull, stdout=logio, stderr=logio), wait=false)
    dbg("start: spawned, waiting for readiness")
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
    st = try_ping(ctx.dir)
    if st isa Dict
        # A daemon still running code from before a jld update behaves subtly
        # differently (new request fields are silently ignored); say so.
        get(st, "proto", 0) == JLD_PROTO ||
            info("note: this daemon was started by a different jld version; `jld restart` to align it")
        return
    end
    st === :timeout && return
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
        connect(daemon_sock(ctx.dir))
    catch
        die("cannot connect to daemon socket; try `jld restart`", 3)
    end
    req = Dict{String,Any}("kind" => kind, "code" => code, "cwd" => pwd())
    m = get(flags, "module", "")
    if !isempty(m)
        Base.isidentifier(m) || die("--module must be a simple identifier, got \"$m\"")
        get(flags, "scratch", false) && die("--module cannot be combined with eval-scratch")
        req["module"] = m
    end
    get(flags, "scratch", false) && (req["scratch"] = true)
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
    handshake_err = nothing
    got_any = false
    try
        conn = connect(daemon_sock(ctx.dir))
        write_frame(conn, "shutdown")
        while true
            kind, payload = read_frame(conn)
            got_any = kind != "eof"
            kind == "warn" && (info(payload); continue)
            if kind == "done" && contains(payload, "refused")
                close(conn)
                exit(2)
            end
            break
        end
        close(conn)
        if got_any
            info("daemon stopped")
            return
        end
    catch e
        handshake_err = e
    end
    # Never escalate to signals against an interactive session: a transient
    # handshake failure must not kill the user's REPL.
    session = get(something(daemon_toml(ctx), Dict{String,Any}()), "kind", "") == "session"
    handshake_err !== nothing &&
        info("shutdown handshake failed: $(sprint(showerror, handshake_err))")
    session && die("this daemon is an interactive session and did not confirm shutdown; not signaling it", 3)
    pid = daemon_pid(ctx)
    if pid !== nothing && pid_alive(pid)
        uv_kill(pid, SIGTERM_)
        info("sent SIGTERM to pid $pid")
    else
        info("daemon not running")
    end
    Sys.iswindows() || rm(daemon_sock(ctx.dir), force=true)
end

function cmd_kill(ctx)
    pid = daemon_pid(ctx)
    if pid !== nothing && pid_alive(pid)
        uv_kill(pid, SIGKILL_)
        info("killed pid $pid")
    else
        info("daemon not running")
    end
    Sys.iswindows() || rm(daemon_sock(ctx.dir), force=true)
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
        connect(daemon_sock(ctx.dir))
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
            isempty(known_ids()) || info("`jld list` shows all daemons")
        end
        return
    end
    println("state:    ", st["busy"] ? "busy" : "idle")
    st["busy"] && println("running:  `$(get(st, "current", "?"))` for $(get(st, "current_elapsed", "?"))s")
    println("pid:      ", st["pid"])
    println("julia:    ", st["julia_version"])
    println("uptime:   ", round(st["uptime"] / 60, digits=1), " min")
    if dt !== nothing
        println("REPL:     jld connect")
    end
    isfile(joinpath(ctx.dir, "transcript.log")) &&
        println("history:  jld transcript   ($(joinpath(ctx.dir, "transcript.log")))")
end

function cmd_list(flags=Dict{String,Any}())
    root = cache_root()
    entries = isdir(root) ? sort(readdir(root)) : String[]
    # The daemon this context would target (what `jld eval` here acts upon).
    target = try
        make_ctx(flags).id
    catch
        nothing
    end
    rows = Vector{NTuple{5,String}}()
    for id in entries
        dir = joinpath(root, id)
        cfg = read_toml(joinpath(dir, "config.toml"))
        cfg === nothing && continue
        st = try_ping(dir)
        session = (st isa Dict ? get(st, "kind", "") : get(cfg, "kind", "")) == "session"
        state = st isa Dict ? (st["busy"] ? "busy" : "idle") :
                st === :timeout ? "unresponsive" : "dead"
        session && (state *= "/repl")
        dt = read_toml(joinpath(dir, "daemon.toml"))
        pid = st isa Dict ? string(st["pid"]) :
              st === :timeout && dt !== nothing ? string(get(dt, "pid", "-")) : "-"
        jver = dt !== nothing ? string(get(dt, "julia_version", "-")) : "-"
        push!(rows, (id, state, pid, jver, get(cfg, "project", "?")))
    end
    isempty(rows) && (println("no daemons"); return)
    header = ("ID", "STATE", "PID", "JULIA", "PROJECT")
    widths = [maximum(length.([header[i], (r[i] for r in rows)...])) for i in 1:4]
    printrow(r; mark="  ") = println(mark, join([rpad(r[i], widths[i]) for i in 1:4], "  "), "  ", r[5])
    printrow(header)
    foreach(r -> printrow(r; mark=(r[1] == target ? "* " : "  ")), rows)
    any(r -> r[1] == target, rows) && info("* = the daemon `jld eval` targets from here")
    ndead = count(r -> r[2] == "dead", rows)
    ndead > 0 && info("$ndead dead; `jld gc` removes their state (config, log, transcript)")
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

# With no project and no id: prefer the daemon `jld eval` would target (the
# default-environment identity) when it exists; otherwise the single running
# daemon, if unique.
function ctx_from_only_running(flags, exists::Function)
    ctx = make_ctx(flags)
    exists(ctx) && return ctx
    running = filter(id -> ping_alive(joinpath(cache_root(), id)), known_ids())
    isempty(running) && die("no running daemons", 3)
    if length(running) > 1
        info("multiple daemons running; pick one with `--id=<id>`:")
        cmd_list()
        exit(2)
    end
    ctx_from_id(only(running))
end

# Paste code into an attached `jld connect` REPL, as if typed there.
function cmd_eval_repl(ctx, arg)
    code = arg === nothing ? read(stdin, String) : arg
    isempty(strip(code)) && die("no code given")
    conn = try
        connect(input_sock(ctx.dir))
    catch
        die("no REPL attached to $(ctx.id); start one with `jld connect`", 3)
    end
    write_frame(conn, "paste", code)
    kind, _ = read_frame(conn)
    close(conn)
    kind == "done" || die("REPL did not acknowledge the paste", 3)
end

# eval-repl outside a project: the default-env daemon if a REPL is attached
# to it, else the unique attached REPL.
function ctx_for_eval_repl(flags)
    find_project(get(flags, "project", nothing)) !== nothing && return make_ctx(flags)
    ctx = make_ctx(flags)
    sock_serving(input_sock(ctx.dir)) && return ctx
    attached = filter(id -> sock_serving(input_sock(joinpath(cache_root(), id))), known_ids())
    isempty(attached) && die("no attached REPL found; start one with `jld connect`", 3)
    length(attached) > 1 &&
        die("multiple attached REPLs ($(join(attached, ", "))); pass --id", 3)
    ctx_from_id(only(attached))
end

# Remove state directories (config, log, transcript) of dead daemons.
function cmd_gc()
    removed = 0
    for id in known_ids()
        dir = joinpath(cache_root(), id)
        try_ping(dir) === nothing || continue  # running or unresponsive: keep
        dt = read_toml(joinpath(dir, "daemon.toml"))
        pid = dt === nothing ? nothing : get(dt, "pid", nothing)
        pid !== nothing && pid_alive(pid) && continue
        # No daemon.toml yet + fresh config: probably still starting up.
        cfg = joinpath(dir, "config.toml")
        dt === nothing && isfile(cfg) && time() - mtime(cfg) < 120 && continue
        rm(dir; recursive=true, force=true)
        info("removed $id")
        removed += 1
    end
    removed == 0 && info("no dead daemons to remove")
end

function cmd_connect(ctx, flags)
    st = try_ping(ctx.dir)
    st === :timeout && die("daemon is unresponsive (busy in a non-yielding eval?); it cannot accept a REPL until the eval yields or finishes — see `jld status`, or `jld kill` if stuck", 3)
    if st === nothing
        ensure_running(ctx, flags)
        st = try_ping(ctx.dir)
        st isa Dict || die("daemon did not come up; see `jld logs`", 3)
    end
    st["busy"] && info("note: daemon is busy (`$(get(st, "current", "?"))` for $(get(st, "current_elapsed", "?"))s); the REPL shares the session and runs alongside it")
    dt = something(daemon_toml(ctx), Dict{String,Any}())
    sockpath = daemon_sock(ctx.dir)
    if get(flags, "print", false)
        println("daemon socket: $sockpath (framed text protocol; any julia can attach)")
        println("attach with:   jld connect $(ctx.id)")
        return
    end
    # Prefer the daemon's own julia for the local prompt (not required — the
    # protocol is plain text — it just keeps the two prompts consistent).
    julia = joinpath(string(get(dt, "julia_bindir", "")), "julia")
    isfile(julia) || (julia = ctx.julia)
    # A session daemon owns repl.sock (eval-repl pastes go to *its* prompt);
    # only spawned daemons hand it to the attached REPL.
    inputsock = get(dt, "kind", "") == "session" ? "" : input_sock(ctx.dir)
    info("connecting to $(ctx.id) (backspace for the local julia> prompt, Ctrl-D to exit)")
    script = joinpath(JLD_HOME, "src", "connect_repl.jl")
    # default_julia_env: the app shim pins JULIA_LOAD_PATH to the app env,
    # which lacks @stdlib and would break the connect script's stdlib imports.
    p = run(ignorestatus(setenv(`$julia --project=$(ctx.project) -i $script $sockpath $inputsock $(ctx.id)`, default_julia_env())))
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

# Ask the daemon's control thread to profile the process for ~1s and report
# per-thread/task backtraces — shows what a busy daemon is doing.
function cmd_stacks(ctx)
    st = try_ping(ctx.dir)
    st isa Dict || die(st === :timeout ?
        "daemon unresponsive (started before thread support? `jld restart`)" :
        "daemon not running", 3)
    conn = try
        connect(daemon_sock(ctx.dir))
    catch
        die("cannot connect to daemon socket", 3)
    end
    write_frame(conn, "stacks")
    info("sampling daemon for ~1s...")
    got = false
    while true
        kind, payload = read_frame(conn)
        if kind == "out"
            got = !isempty(payload)
            write(stdout, payload)
        elseif kind == "done" || kind == "eof"
            break
        end
    end
    close(conn)
    got || info("daemon returned no stacks (predates this feature? `jld restart`)")
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
    # ~/.agents/skills is the cross-tool Agent Skills location (opencode,
    # Gemini CLI, ...); tool-specific dirs are added for agents that only
    # read their own (when they appear installed).
    targets = [joinpath(homedir(), ".agents", "skills", "julia-daemon")]
    for tooldir in (".claude", ".codex")
        isdir(joinpath(homedir(), tooldir)) &&
            push!(targets, joinpath(homedir(), tooldir, "skills", "julia-daemon"))
    end
    for dst in targets
        islink(dst) && rm(dst)
        mkpath(dst)
        for f in readdir(src)
            cp(joinpath(src, f), joinpath(dst, f); force=true)
        end
        info("installed skill: $dst")
    end
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
  eval-scratch '<code>'  like eval, but in a fresh module that sees Main's bindings;
                    everything it creates is released afterwards (no state kept)
  run <file.jl>     include() a file in the daemon; autostarts
  start             start the daemon (pre-warm); --startup='using Foo' to run code at boot
  restart           restart (needed after struct redefinitions); keeps recorded --startup
  stop | kill       stop gracefully | SIGKILL
  interrupt         interrupt the current eval at its next yield point; daemon survives
  status            state of the daemon this context targets (see `list` for all)
  list              list all daemons; * marks the one this context targets
  gc                remove the state (config, log, transcript) of dead daemons
  connect [id]      attach an interactive REPL to this project's daemon,
                    or to any daemon by id/prefix (see `jld list`); outside a project
                    with no id, connects to the single running daemon
  eval-repl '<code>'  paste code into the attached `jld connect` REPL, exactly as if
                    typed there (echoed at the prompt, output shown, ans set)
  transcript [id] [-f]  print the session transcript: every input + output evaluated
                    in the daemon (jld eval/run and remote REPL), output truncated
                    per entry — lets an agent read the context of a running session
  stacks [id]       show task backtraces of what the daemon is currently executing
  logs [-f]         show daemon log
  setup             (re)install the daemon environment for the selected julia
  install           install the agent skill into ~/.agents/skills (cross-tool) and the
                    skills dirs of installed agents (~/.claude, ~/.codex);
                    plus a ~/.local/bin/jld symlink if jld is not on PATH

flags:
  --project=PATH    project to serve (default: JULIA_PROJECT, nearest Project.toml,
                    or the default environment — like plain julia)
  --name=NAME       distinct daemon for the same project (env: JLD_NAME)
  --id=ID           target an existing daemon by id/prefix (see `jld list`), any command
  --module=M        eval/run: evaluate in module Main.M instead of Main (created on demand)
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
                elseif k in ("project", "name", "julia", "threads", "timeout", "module", "id")
                    flags[String(k)] = String(v)
                else
                    die("unknown flag --$k")
                end
            else
                k = a[3:end]
                k in ("no-autostart", "print", "follow", "help") || die("unknown flag --$k")
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
    # --id targets an existing daemon directly, bypassing project resolution.
    byid = haskey(flags, "id")
    resolve(posid=nothing) = byid ? ctx_from_id(flags["id"]) :
                             posid !== nothing ? ctx_from_id(posid) : make_ctx(flags)
    outside_project() = !byid && find_project(get(flags, "project", nothing)) === nothing

    if cmd == "list"
        cmd_list(flags)
        return
    elseif cmd == "gc"
        cmd_gc()
        return
    elseif cmd == "install"
        cmd_install()
        return
    elseif cmd == "status"
        cmd_status(resolve())
        return
    elseif cmd == "connect"
        posid = length(pos) >= 2 ? pos[2] : nothing
        ctx = posid === nothing && outside_project() ?
              ctx_from_only_running(flags, c -> try_ping(c.dir) !== nothing) : resolve(posid)
        cmd_connect(ctx, flags)
        return
    elseif cmd == "eval-repl"
        ctx = byid ? ctx_from_id(flags["id"]) : ctx_for_eval_repl(flags)
        cmd_eval_repl(ctx, length(pos) >= 2 ? pos[2] : nothing)
        return
    elseif cmd == "transcript" || cmd == "stacks" || cmd == "logs"
        posid = length(pos) >= 2 ? pos[2] : nothing
        ctx = if posid === nothing && outside_project()
            exists = cmd == "transcript" ? (c -> isfile(joinpath(c.dir, "transcript.log"))) :
                     cmd == "logs" ? (c -> isfile(log_path(c))) :
                     (c -> try_ping(c.dir) !== nothing)
            ctx_from_only_running(flags, exists)
        else
            resolve(posid)
        end
        cmd == "transcript" ? cmd_transcript(ctx, flags) :
        cmd == "logs" ? cmd_logs(ctx, flags) : cmd_stacks(ctx)
        return
    elseif cmd in ("stop", "interrupt", "kill", "restart")
        # Outside a project, act on the unique running daemon when the
        # default-env identity has nothing to act on.
        ctx = if outside_project()
            exists = cmd == "restart" ? (c -> isfile(joinpath(c.dir, "config.toml"))) :
                                        (c -> try_ping(c.dir) !== nothing)
            ctx_from_only_running(flags, exists)
        else
            resolve()
        end
        cmd == "stop" ? cmd_stop(ctx) :
        cmd == "interrupt" ? cmd_interrupt(ctx) :
        cmd == "kill" ? cmd_kill(ctx) : cmd_restart(ctx, flags)
        return
    end
    ctx = resolve()
    if cmd == "eval"
        cmd_exec(ctx, "eval", length(pos) >= 2 ? pos[2] : nothing, flags)
    elseif cmd == "eval-scratch"
        flags["scratch"] = true
        cmd_exec(ctx, "eval", length(pos) >= 2 ? pos[2] : nothing, flags)
    elseif cmd == "run"
        cmd_exec(ctx, "include", length(pos) >= 2 ? pos[2] : nothing, flags)
    elseif cmd == "start"
        cmd_start(ctx, flags)
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
