module JLDDaemon

using Sockets
using TOML
import REPL
import Revise
import RemoteREPL

include("protocol.jl")

struct Request
    kind::String   # "eval" | "include"
    code::String   # code string or absolute file path
    cwd::String
    sock::Any
    done::Ref{Bool}
    cancelled::Ref{Bool}
    broken::Ref{Bool}
    sendlock::ReentrantLock
end

const CURRENT = Ref{Union{Request,Nothing}}(nothing)
const CURRENT_T0 = Ref(0.0)
const STARTED = Ref(0.0)
const EVAL_TASK = Ref{Task}()

# Soft interrupt, RemoteREPL-style: only lands when the eval task is at a
# yield point. CPU-bound code that never yields cannot be interrupted this
# way; `jld kill` is the fallback.
function interrupt_eval()
    CURRENT[] === nothing && return false
    try
        schedule(EVAL_TASK[], InterruptException(); error=true)
        return true
    catch
        return false
    end
end

logmsg(msg) = (println(stderr, "[jld ", Libc.strftime("%T", time()), "] ", msg); flush(stderr))

function main(args::Vector{String})
    dir = ""
    startup = String[]
    for a in args
        if startswith(a, "--dir=")
            dir = a[length("--dir=")+1:end]
        elseif startswith(a, "--startup=")
            push!(startup, a[length("--startup=")+1:end])
        end
    end
    isempty(dir) && error("missing --dir")

    STARTED[] = time()
    logmsg("starting daemon, project = $(Base.active_project())")

    sockpath = joinpath(dir, "sock")
    server = listen_or_yield(sockpath)
    server === nothing && return

    repl_port = start_remoterepl()
    write_state(dir, repl_port)

    Core.eval(Main, :(import Revise))

    requests = Channel{Request}(32)
    @async accept_loop(server, requests)

    for code in startup
        logmsg("running startup code: $(first(code, 200))")
        run_startup(code) || (logmsg("startup code failed, exiting"); exit(1))
    end

    logmsg("ready (pid $(Libc.getpid()), REPL port $repl_port)")
    EVAL_TASK[] = @async eval_loop(requests)
    wait(EVAL_TASK[])
end

function listen_or_yield(sockpath)
    try
        return listen(sockpath)
    catch
    end
    # Socket file exists: either a live daemon (lost race) or a stale file.
    try
        close(connect(sockpath))
        logmsg("another daemon is already serving $sockpath, exiting")
        return nothing
    catch
    end
    rm(sockpath, force=true)
    listen(sockpath)
end

function start_remoterepl()
    port, server = listenany(Sockets.localhost, 27754)
    @async begin
        try
            RemoteREPL.serve_repl(server)
        catch e
            e isa InterruptException || logmsg("RemoteREPL server died: $(sprint(showerror, e))")
        end
    end
    Int(port)
end

function write_state(dir, repl_port)
    d = Dict{String,Any}(
        "pid" => Libc.getpid(),
        "repl_port" => repl_port,
        "julia_version" => string(VERSION),
        "julia_bindir" => Sys.BINDIR,
        "project" => something(Base.active_project(), ""),
        "started" => STARTED[],
    )
    tmp = joinpath(dir, ".daemon.toml.tmp")
    open(tmp, "w") do io
        TOML.print(io, d)
    end
    mv(tmp, joinpath(dir, "daemon.toml"), force=true)
end

function state_toml()
    cur = CURRENT[]
    d = Dict{String,Any}(
        "pid" => Libc.getpid(),
        "busy" => cur !== nothing,
        "uptime" => round(time() - STARTED[], digits=1),
        "julia_version" => string(VERSION),
        "project" => something(Base.active_project(), ""),
    )
    if cur !== nothing
        d["current"] = first(cur.code, 120)
        d["current_elapsed"] = round(time() - CURRENT_T0[], digits=1)
    end
    sprint(io -> TOML.print(io, d))
end

function accept_loop(server, requests)
    while true
        conn = try
            accept(server)
        catch e
            e isa InterruptException && continue
            logmsg("accept loop terminated: $(sprint(showerror, e))")
            return
        end
        @async handle_connection(conn, requests)
    end
end

function handle_connection(conn, requests)
    try
        kind, payload = read_frame(conn)
        if kind == "ping"
            write_frame(conn, "pong", state_toml())
            close(conn)
        elseif kind == "shutdown"
            logmsg("shutdown requested")
            write_frame(conn, "done", "status = \"ok\"\n")
            close(conn)
            exit(0)
        elseif kind == "interrupt"
            ok = interrupt_eval()
            write_frame(conn, "done", "status = \"$(ok ? "ok" : "noop")\"\n")
            close(conn)
        elseif kind == "req"
            d = TOML.parse(payload)
            req = Request(d["kind"], d["code"], get(d, "cwd", ""),
                          conn, Ref(false), Ref(false), Ref(false), ReentrantLock())
            cur = CURRENT[]
            if cur !== nothing
                write_frame(conn, "warn",
                    "daemon busy ($(round(time() - CURRENT_T0[], digits=1))s into `$(first(cur.code, 60))`), request queued")
            end
            put!(requests, req)
            request_reader(req)
        else
            close(conn)
        end
    catch e
        e isa InterruptException || logmsg("connection error: $(sprint(showerror, e))")
        try close(conn) catch end
    end
end

# Reads frames from the client while its request runs: "interrupt" frames,
# and EOF, which means the client is gone (Ctrl-C fallthrough, Bash timeout,
# kill) — cancel the request, interrupting it if it is the one running.
function request_reader(req)
    while true
        kind, _ = try
            read_frame(req.sock)
        catch
            ("eof", "")
        end
        if kind == "interrupt"
            req.done[] && continue
            if CURRENT[] === req
                interrupt_eval() || safe_send(req, "warn", "eval not at a yield point; cannot interrupt now")
            else
                req.cancelled[] = true
            end
        elseif kind == "eof"
            if !req.done[]
                req.cancelled[] = true
                if CURRENT[] === req
                    logmsg("client disconnected, interrupting current eval")
                    interrupt_eval()
                end
            end
            return
        end
    end
end

# Runs on the main (root) task so that SIGINT-delivered InterruptExceptions
# land in the evaluating code.
function eval_loop(requests)
    while true
        req = try
            take!(requests)
        catch e
            e isa InterruptException && continue
            rethrow()
        end
        if req.cancelled[]
            safe_send(req, "done", "status = \"interrupted\"\n")
            req.done[] = true
            try close(req.sock) catch end
            continue
        end
        CURRENT[] = req
        CURRENT_T0[] = time()
        try
            run_request(req)
        catch e
            e isa InterruptException || logmsg("request failed internally: $(sprint(showerror, e, catch_backtrace()))")
        finally
            CURRENT[] = nothing
            req.done[] = true
            try close(req.sock) catch end
        end
    end
end

function safe_send(req, kind, payload)
    req.broken[] && return
    try
        lock(req.sendlock) do
            write_frame(req.sock, kind, payload)
        end
    catch
        req.broken[] = true
    end
end

function pump(rd, kind, req)
    while true
        try
            eof(rd) && return
            safe_send(req, kind, String(readavailable(rd)))
        catch e
            e isa InterruptException && continue
            return
        end
    end
end

function run_request(req)
    t0 = time()
    orig_stdout, orig_stderr = stdout, stderr
    rd_out, wr_out = redirect_stdout()
    rd_err, wr_err = redirect_stderr()
    pump_out = @async pump(rd_out, "out", req)
    pump_err = @async pump(rd_err, "err", req)

    status = "ok"
    resultstr = nothing
    try
        try
            Revise.revise()
        catch e
            is_interrupt(e) && rethrow()
            safe_send(req, "warn", "Revise.revise() threw: $(sprint(showerror, e))")
        end
        for w in revise_warnings()
            safe_send(req, "warn", w)
        end

        result = withcwd(req.cwd) do
            if req.kind == "include"
                Base.include(REPL.softscope, Main, req.code)
            else
                include_string(REPL.softscope, Main, req.code, "jld-eval")
            end
        end
        setglobal!(Base.MainInclude, :ans, result)
        if result !== nothing && req.kind == "eval" && !endswith(rstrip(req.code), ';')
            # invokelatest: rendering may hit methods/bindings defined by this request
            resultstr = Base.invokelatest(render, result)
        end
    catch e
        if is_interrupt(e)
            status = "interrupted"
        else
            status = "error"
            print(stderr, Base.invokelatest(format_error, e, catch_backtrace())::String)
        end
    finally
        try
            flush(stdout); flush(stderr)
        catch
        end
        redirect_stdout(orig_stdout); redirect_stderr(orig_stderr)
        close(wr_out); close(wr_err)
        try
            wait(pump_out); wait(pump_err)
        catch
        end
    end

    resultstr !== nothing && safe_send(req, "result", resultstr)
    safe_send(req, "done", "status = \"$status\"\nelapsed = $(round(time() - t0, digits=3))\n")
    logmsg("request finished: $status ($(round(time() - t0, digits=2))s) `$(first(req.code, 80))`")
end

withcwd(f, dir) = (isempty(dir) || !isdir(dir)) ? f() : cd(f, dir)

is_interrupt(e) = e isa InterruptException || (e isa LoadError && is_interrupt(e.error))

function revise_warnings()
    out = String[]
    try
        for ((pkgdata, file), (err, _)) in Revise.queue_errors
            msg = first(split(sprint(showerror, err), '\n'))
            push!(out, "Revise failed to apply changes to $file: $msg")
        end
        if !isempty(out)
            push!(out, "the daemon may be running STALE code; if you changed a struct definition or the error above persists after fixing the file, run `jld restart`")
        end
    catch
    end
    out
end

function render(x)
    try
        sprint() do io
            show(IOContext(io, :limit => true, :displaysize => (30, 120)), MIME"text/plain"(), x)
        end
    catch e
        "«error showing value of type $(typeof(x)): $(sprint(showerror, e))»"
    end
end

function format_error(e, bt)
    st = Base.stacktrace(bt)
    n = findfirst(fr -> String(fr.file) == @__FILE__, st)
    n !== nothing && (st = st[1:n-1])
    # Drop include machinery frames between user code and the daemon.
    while !isempty(st) && (endswith(String(st[end].file), "loading.jl") || endswith(String(st[end].file), "Base_compiler.jl"))
        pop!(st)
    end
    sprint() do io
        ioc = IOContext(io, :limit => true)
        print(ioc, "ERROR: ")
        showerror(ioc, e, st)
        println(ioc)
    end
end

function run_startup(code)
    try
        include_string(REPL.softscope, Main, code, "jld-startup")
        true
    catch e
        logmsg("startup error: $(sprint(showerror, e, catch_backtrace()))")
        false
    end
end

end # module
