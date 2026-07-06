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
        nd == d && die("no Project.toml found upwards from $(pwd()); pass --project=<path>")
        d = nd
    end
end

function make_ctx(flags)
    project = find_project(get(flags, "project", nothing))
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

function julia_version_of(julia)
    out = try
        readchomp(`$julia --version`)
    catch
        die("failed to run $julia --version")
    end
    m = match(r"(\d+)\.(\d+)\.", out)
    m === nothing && die("cannot parse julia version from \"$out\"")
    "$(m[1]).$(m[2])"
end

function ensure_env(julia; force=false)
    ver = julia_version_of(julia)
    envdir = joinpath(JLD_HOME, "envs", "v$ver")
    if force || !isfile(joinpath(envdir, "Manifest.toml"))
        mkpath(envdir)
        info("setting up daemon environment for Julia $ver (one-time, installs $(join(DAEMON_DEPS, ", ")))...")
        code = "using Pkg; Pkg.add($(repr(DAEMON_DEPS)))"
        run(pipeline(`$julia --startup-file=no --project=$envdir -e $code`, stdout=stderr, stderr=stderr))
    end
    envdir
end

# ---- daemon state ----

function try_ping(dir)
    sockpath = joinpath(dir, "sock")
    issocket(sockpath) || return nothing
    conn = try
        connect(sockpath)
    catch
        return nothing
    end
    try
        write_frame(conn, "ping")
        kind, payload = read_frame(conn)
        kind == "pong" || return nothing
        return TOML.parse(payload)
    catch
        return nothing
    finally
        close(conn)
    end
end

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
        info("daemon already running (id $(ctx.id)); use `jld restart` to reload")
        return
    end
    mkpath(ctx.dir)
    rm(joinpath(ctx.dir, "sock"), force=true)
    rm(joinpath(ctx.dir, "daemon.toml"), force=true)
    envdir = ensure_env(ctx.julia)

    startup = get(flags, "startup", String[])
    threads = get(flags, "threads", nothing)
    cfg = Dict{String,Any}(
        "project" => ctx.project, "name" => ctx.name, "julia" => ctx.julia,
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
    threads !== nothing && push!(jargs, "--threads=$threads")
    dargs = ["--dir=$(ctx.dir)"]
    append!(dargs, ["--startup=$s" for s in startup])

    cmd = `$(ctx.julia) $jargs $(joinpath(JLD_HOME, "src", "daemon_main.jl")) $dargs`
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
        if st !== nothing
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

function ensure_running(ctx, flags)
    try_ping(ctx.dir) !== nothing && return
    get(flags, "no-autostart", false) && die("daemon not running (autostart disabled)", 3)
    # Reuse recorded startup code/threads from a previous `jld start` if present.
    cfg = config_toml(ctx)
    if cfg !== nothing
        haskey(flags, "startup") || (flags["startup"] = get(cfg, "startup", String[]))
        !haskey(flags, "threads") && haskey(cfg, "threads") && (flags["threads"] = cfg["threads"])
    end
    cmd_start(ctx, flags)
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
    reader = @async begin
        while true
            kind, payload = read_frame(conn)
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
            else # eof
                lost[] = true
                return
            end
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
    if cfg !== nothing
        haskey(flags, "startup") || (flags["startup"] = get(cfg, "startup", String[]))
        !haskey(flags, "threads") && haskey(cfg, "threads") && (flags["threads"] = cfg["threads"])
    end
    cmd_start(ctx, flags)
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
        info("interrupt delivered")
    else
        info("nothing to interrupt (daemon idle, or eval not at a yield point)")
    end
end

function cmd_status(ctx)
    st = try_ping(ctx.dir)
    dt = daemon_toml(ctx)
    println("id:       ", ctx.id)
    println("project:  ", ctx.project)
    if st === nothing
        pid = dt === nothing ? nothing : get(dt, "pid", nothing)
        if pid !== nothing && pid_alive(pid)
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
        state = st === nothing ? "dead" : (st["busy"] ? "busy" : "idle")
        dt = read_toml(joinpath(dir, "daemon.toml"))
        pid = st !== nothing ? string(st["pid"]) : "-"
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

function cmd_connect(ctx, flags)
    st = try_ping(ctx.dir)
    st === nothing && die("daemon not running; start it with `jld start`", 3)
    dt = daemon_toml(ctx)
    port = dt["repl_port"]
    dver = get(dt, "julia_version", "?")
    envdir = ensure_env(ctx.julia)
    if get(flags, "print", false)
        println("RemoteREPL server: localhost:$port (daemon julia $dver)")
        println("From a Julia $dver REPL with RemoteREPL installed:")
        println("  using RemoteREPL; connect_repl($port)")
        return
    end
    cver = julia_version_of(ctx.julia)
    startswith(dver, cver) || info("warning: REPL julia $cver != daemon julia $dver; RemoteREPL may fail (pass --julia to match)")
    info("connecting to $(ctx.id) on port $port (remote prompt: press '>', exit REPL with Ctrl-D)")
    env = copy(ENV)
    env["JULIA_LOAD_PATH"] = "@:$envdir:@stdlib"
    code = "atreplinit(_ -> @async(begin sleep(0.1); import RemoteREPL; RemoteREPL.connect_repl($port) end))"
    run(setenv(`$(ctx.julia) --project=$(ctx.project) -i -e $code`, env))
end

function cmd_logs(ctx, flags)
    isfile(log_path(ctx)) || die("no log file at $(log_path(ctx))")
    if get(flags, "follow", false)
        run(`tail -n 40 -f $(log_path(ctx))`)
    else
        print(log_tail(ctx, 100))
    end
end

function cmd_setup(ctx)
    ensure_env(ctx.julia, force=true)
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
  interrupt         send SIGINT to interrupt the current eval, daemon survives
  status            show daemon state for this project
  list              list all daemons
  connect           attach an interactive REPL (RemoteREPL) to the daemon
  logs [-f]         show daemon log
  setup             (re)install the daemon environment for the selected julia

flags:
  --project=PATH    project to serve (default: JULIA_PROJECT or nearest Project.toml)
  --name=NAME       distinct daemon for the same project (env: JLD_NAME)
  --julia=BIN       julia executable for the daemon (env: JLD_JULIA, default: julia)
  --startup=CODE    code to run at daemon boot (repeatable; with start/restart)
  --threads=N       daemon thread count (interrupts are less reliable with N>1)
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
                k in ("no-autostart", "print", "follow", "help") || die("unknown flag --$k")
                flags[k] = true
            end
        else
            push!(pos, a)
        end
    end
    (flags, pos)
end

function main()
    flags, pos = parse_cli(ARGS)
    if isempty(pos) || get(flags, "help", false) || (length(pos) == 1 && pos[1] == "help")
        print(HELP)
        return
    end
    cmd = pos[1]
    if cmd == "list"
        cmd_list()
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
    elseif cmd == "status"
        cmd_status(ctx)
    elseif cmd == "connect"
        cmd_connect(ctx, flags)
    elseif cmd == "logs"
        cmd_logs(ctx, flags)
    elseif cmd == "setup"
        cmd_setup(ctx)
    else
        die("unknown command \"$cmd\" (see jld --help)")
    end
end

main()
