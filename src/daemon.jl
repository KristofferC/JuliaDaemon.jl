module JLDDaemon

using Sockets
using TOML
import Logging
import Profile
import REPL
import SHA

# Optional in session mode (`JuliaDaemon.serve()` in an existing REPL);
# always present for spawned daemons via the stacked jld environment.
# JLD_NO_REVISE is set by the client for `--no-revise` (must be decided here,
# at include time); dropped from ENV so evals' subprocesses don't inherit it.
const REVISE_DISABLED = get(ENV, "JLD_NO_REVISE", "") == "1"
delete!(ENV, "JLD_NO_REVISE")
const HAVE_REVISE, REVISE_LOAD_ERROR = if REVISE_DISABLED
    (false, "")
else
    try
        @eval import Revise
        (true, "")
    catch e
        (false, sprint(showerror, e))
    end
end
include("protocol.jl")
include("repl_input.jl")

# Bounded output capture (transcript, --max-output): full head, ring-buffered tail.
const CAP_HEAD = 12 * 1024
const CAP_TAIL = 4 * 1024

mutable struct Capture
    head::Vector{UInt8}
    tail::Vector{UInt8}
    tstart::Int
    tcount::Int
    total::Int
    headmax::Int
end
Capture(headmax = CAP_HEAD, tailmax = CAP_TAIL) = Capture(UInt8[], zeros(UInt8, tailmax), 0, 0, 0, headmax)

function cap_write!(c::Capture, data::AbstractVector{UInt8})
    tailmax = length(c.tail)
    c.total += length(data)
    i = 1
    room = c.headmax - length(c.head)
    if room > 0
        n = min(room, length(data))
        append!(c.head, view(data, 1:n))
        i = n + 1
    end
    rem = length(data) - i + 1
    rem <= 0 && return
    # Only the final tailmax bytes can survive in the ring; for a large write
    # skip straight to them with one bulk copy instead of spinning per-byte.
    if rem >= tailmax
        copyto!(c.tail, 1, data, length(data) - tailmax + 1, tailmax)
        c.tstart = 0
        c.tcount = tailmax
        return
    end
    while i <= length(data)
        c.tail[(c.tstart + c.tcount) % tailmax + 1] = data[i]
        c.tcount == tailmax ? (c.tstart = (c.tstart + 1) % tailmax) : (c.tcount += 1)
        i += 1
    end
    return
end
cap_write!(c::Capture, s::AbstractString) = cap_write!(c, Vector{UInt8}(codeunits(s)))

cap_tail(c::Capture) = UInt8[c.tail[(c.tstart + k) % length(c.tail) + 1] for k in 0:(c.tcount - 1)]
cap_omitted(c::Capture) = c.total - length(c.head) - c.tcount

function cap_string(c::Capture)
    tailbytes = cap_tail(c)
    omitted = cap_omitted(c)
    head = String(copy(c.head))
    omitted <= 0 && return head * String(tailbytes)
    return string(head, "\n⋯ jld: ", omitted, " bytes of output omitted ⋯\n", String(tailbytes))
end

struct Request
    kind::String   # "eval" | "include"
    code::String   # code string or absolute file path
    cwd::String
    mod::String    # "" = Main; otherwise a module name under Main
    scratch::Bool  # evaluate in a throwaway module, release results after
    client::String # "" (agent CLI) | "repl" (attached REPL)
    color::Bool    # render results/errors with ANSI color
    sock::Any
    done::Ref{Bool}
    cancelled::Ref{Bool}
    broken::Ref{Bool}
    sendlock::ReentrantLock
    cap::Capture
    outcap::Union{Capture, Nothing}  # --max-output: nothing = stream everything
end

const CURRENT = Ref{Union{Request, Nothing}}(nothing)
const CURRENT_T0 = Ref(0.0)
const STARTED = Ref(0.0)
# True while --startup code runs: the socket already answers pings (so a
# second daemon is not spawned) but the client keeps waiting for readiness.
const BOOTING = Ref(false)
# The --startup snippet that failed at boot, if any; the daemon stays up.
const STARTUP_ERROR = Ref("")
const EVAL_TASK = Ref{Task}()
const STATE_DIR = Ref("")
const NAME = Ref("")
const CHECKOUT = Ref("")  # julia source checkout served by this daemon ("" if none)
# --testenv: activate the package's test environment at boot (jld --test).
const TESTENV = Ref(false)
# --idle-timeout: stop after this many seconds without requests (0 = never).
const IDLE_TTL = Ref(0.0)
const LAST_ACTIVITY = Ref(time())
# Whether any request has been served yet: until then the idle watcher applies
# a floor on the TTL, so a short --idle-timeout cannot stop the daemon in the
# boot-to-first-connection window on a slow machine.
const SEEN_REQUEST = Ref(false)

# In-session introspection, e.g. `Main.JLDDaemon.id()` from an eval or the
# attached REPL.
id() = basename(STATE_DIR[])
name() = NAME[]
statedir() = STATE_DIR[]
transcript_path() = TRANSCRIPT_PATH[]

# Runs on the interactive thread: profiling is process-wide, so this samples
# whatever the eval thread is doing, even a non-yielding loop.
function collect_stacks()
    Profile.clear()
    Profile.@profile sleep(0.7)
    iob = IOBuffer()
    Profile.print(IOContext(iob, :displaysize => (200, 240)); groupby = [:thread, :task], C = false)
    Profile.clear()
    return String(take!(iob))
end

# Soft interrupt: only lands when the eval task is at a
# yield point. CPU-bound code that never yields cannot be interrupted this
# way; the client escalates (--timeout, `jld interrupt --force`) by killing
# the daemon after a grace period.
function interrupt_eval()
    CURRENT[] === nothing && return false
    try
        schedule(EVAL_TASK[], InterruptException(); error = true)
        return true
    catch
        return false
    end
end

# `exit(n)` evaluated in a request must not take the daemon down: a hooked
# Base.exit turns it into EvalExit, which run_request maps to the client's
# exit code. Outside a request (daemon shutdown, a served session's own REPL)
# it exits the process as usual.
struct EvalExit <: Exception
    code::Int
end

@static if isdefined(Base, :ScopedValues)
    const IN_EVAL = Base.ScopedValues.ScopedValue(false)
    with_in_eval(f) = Base.ScopedValues.with(f, IN_EVAL => true)
else
    const IN_EVAL = Ref(false)
    function with_in_eval(f)
        IN_EVAL[] = true
        try
            f()
        finally
            IN_EVAL[] = false
        end
    end
end

exit_hook(n::Integer) = IN_EVAL[] ? throw(EvalExit(Int(n))) : ccall(:jl_exit, Cvoid, (Int32,), n % Int32)
install_exit_hook() = @eval Base exit(n::Integer) = $(exit_hook)(n)

unwrap_exit(e) = e isa EvalExit ? e : e isa LoadError ? unwrap_exit(e.error) : nothing

# Spawned daemons log to stderr (redirected to the log file by the client);
# session servers open the log file themselves. Captured once so per-request
# stream redirection never leaks log lines into a client's output.
const LOG_IO = Ref{IO}(stderr)
const SESSION = Ref(false)

logmsg(msg) = (println(LOG_IO[], "[jld ", Libc.strftime("%Y-%m-%d %H:%M:%S", time()), "] ", msg); flush(LOG_IO[]))

# ---- session transcript (input + output of everything evaluated in Main) ----

const TRANSCRIPT_PATH = Ref("")
const TRANSCRIPT_LOCK = ReentrantLock()

const TRANSCRIPT_MAX = 8 * 1024 * 1024

function transcript_raw(s::AbstractString)
    isempty(TRANSCRIPT_PATH[]) && return
    return lock(TRANSCRIPT_LOCK) do
        try
            path = TRANSCRIPT_PATH[]
            # Rotate rather than grow without bound; one generation kept.
            if isfile(path) && filesize(path) > TRANSCRIPT_MAX
                mv(path, path * ".1", force = true)
            end
            open(io -> write(io, s), path, "a")
        catch
        end
    end
end

trunc_middle(s, h, t) = sizeof(s) <= h + t + 64 ? s :
    string(first(s, h), "\n⋯ jld: ", sizeof(s) - h - t, " bytes omitted ⋯\n", last(s, t))

function transcript_entry(source, input, output; status = "ok", elapsed = nothing)
    isempty(TRANSCRIPT_PATH[]) && return
    hdr = string(
        "#= ", Libc.strftime("%Y-%m-%d %H:%M:%S", time()), " ", source, " (", status,
        elapsed === nothing ? "" : string(", ", round(elapsed, digits = 2), "s"), ") =#"
    )
    input = trunc_middle(input, 4096, 1024)
    # Keep the transcript readable for agents: no ANSI escapes (colored REPL
    # results and errors flow through the same capture).
    output = replace(output, r"\e\[[0-9;]*[A-Za-z]" => "")
    output = trunc_middle(output, CAP_HEAD, CAP_TAIL)
    body = isempty(strip(output)) ? "" : endswith(output, '\n') ? output : output * "\n"
    return transcript_raw(string(hdr, "\njulia> ", input, "\n", body, "\n"))
end

function exprstring(ex)
    return try
        if ex isa Expr && ex.head === :toplevel
            join((string(a) for a in ex.args if !(a isa LineNumberNode)), "\n")
        else
            string(ex)
        end
    catch
        "«unprintable expression»"
    end
end

# Tab completion for the attached REPL: computed against Main on the
# interactive thread, over its own connection — never queued behind evals.
function remote_completions(partial::AbstractString, full::AbstractString)
    ret, range, should = REPL.completions(full, lastindex(partial), Main)
    return Dict{String, Any}(
        "completions" => unique!(map(REPL.completion_text, ret)),
        "partial" => partial[range],
        "should" => should,
    )
end

function main(args::Vector{String})
    dir = ""
    startup = String[]
    logfile = ""
    for a in args
        if startswith(a, "--dir=")
            dir = a[(length("--dir=") + 1):end]
        elseif startswith(a, "--startup=")
            push!(startup, a[(length("--startup=") + 1):end])
        elseif startswith(a, "--log=")
            logfile = a[(length("--log=") + 1):end]
        elseif startswith(a, "--idle-timeout=")
            IDLE_TTL[] = something(tryparse(Float64, a[(length("--idle-timeout=") + 1):end]), 0.0)
        elseif a == "--testenv"
            TESTENV[] = true
        end
    end
    isempty(dir) && error("missing --dir")

    # On Windows the daemon is spawned without any inherited stdio (handle
    # inheritance leaks the caller's pipes); it opens its own log instead.
    if !isempty(logfile)
        logio = open(logfile, "a")
        redirect_stdout(logio)
        redirect_stderr(logio)
        LOG_IO[] = logio
    end

    # Pin logging to the log file now; resolving `stderr` at log time would
    # hit the per-request redirection.
    Logging.global_logger(Logging.ConsoleLogger(stderr))
    # Same for the SIGUSR1/SIGINFO profile peek (`jld stacks`): its report must
    # land in the log even while a request has the streams redirected.
    let logio = stderr
        Profile.peek_report[] = function ()
            iob = IOBuffer()
            try
                Profile.print(IOContext(iob, :displaysize => (200, 200)); groupby = [:thread, :task])
            catch e
                print(iob, "profile report failed: ", sprint(showerror, e), "\n")
            end
            write(logio, take!(iob))
            return flush(logio)
        end
    end
    logmsg("starting daemon, project = $(Base.active_project())")
    if REVISE_DISABLED
        logmsg("Revise disabled (--no-revise) — source edits will not auto-apply")
    elseif !HAVE_REVISE
        logmsg("Revise FAILED TO LOAD — running without auto-revision: " * first(REVISE_LOAD_ERROR, 500))
    end

    requests = setup_server(dir)
    requests === nothing && return

    HAVE_REVISE && Core.eval(Main, :(import Revise))

    if TESTENV[] || !isempty(startup)
        BOOTING[] = true
        TESTENV[] && activate_testenv()
        for code in startup
            logmsg("running startup code: $(first(code, 200))")
            if !run_startup(code)
                STARTUP_ERROR[] = first(code, 120)
                logmsg("startup code failed; daemon continues without it (rerun via `jld eval`, or fix and `jld restart`)")
                break
            end
        end
        BOOTING[] = false
    end

    # Warm up the completion machinery so the attached REPL's first TAB is
    # instant rather than a multi-second compile.
    Threads.@spawn :default try
        Base.invokelatest(remote_completions, "prin", "prin")
    catch
    end

    logmsg("ready (pid $(Libc.getpid()))")
    # Evals run on the default pool; this (root) task and everything @async'd
    # from it — accept loop, connection handlers, completions — live on the
    # interactive thread, so ping/status/queueing/REPL stay responsive even
    # while an eval is compute-bound and never yields.
    EVAL_TASK[] = Threads.@spawn :default eval_loop(requests)
    IDLE_TTL[] > 0 && @async idle_watcher(requests)
    return wait(EVAL_TASK[])
end

# Stop a daemon nobody has used for --idle-timeout seconds: agent workflows
# leak warm daemons otherwise. Runs on the interactive thread; never installed
# for interactive sessions (serve_session does not parse the flag).
function idle_watcher(requests)
    while true
        sleep(clamp(IDLE_TTL[] / 4, 0.5, 60))
        CURRENT[] === nothing || continue
        (isready(requests) || BOOTING[]) && continue
        ttl = SEEN_REQUEST[] ? IDLE_TTL[] : max(IDLE_TTL[], 30.0)
        time() - LAST_ACTIVITY[] > ttl || continue
        logmsg("no requests for more than $(round(Int, IDLE_TTL[]))s, stopping (--idle-timeout)")
        Sys.iswindows() || rm(daemon_sock(STATE_DIR[]), force = true)
        exit(0)
    end
    return
end

# Everything shared between spawned daemons and in-session servers: socket,
# transcript, state file, accept loop. Returns the request
# channel, or nothing if another daemon already serves this state dir.
function setup_server(dir)
    STARTED[] = time()
    STATE_DIR[] = dir
    cfg = try
        TOML.parsefile(joinpath(dir, "config.toml"))
    catch
        Dict{String, Any}()
    end
    NAME[] = string(get(cfg, "name", ""))
    CHECKOUT[] = string(get(cfg, "checkout", ""))
    install_exit_hook()

    server = listen_or_yield(daemon_sock(dir))
    server === nothing && return nothing

    TRANSCRIPT_PATH[] = joinpath(dir, "transcript.log")
    transcript_raw(
        string(
            "#= ", Libc.strftime("%Y-%m-%d %H:%M:%S", time()),
            SESSION[] ? " interactive session serving: project=" : " daemon started: project=",
            something(Base.active_project(), "?"), ", julia ", VERSION,
            ", pid ", Libc.getpid(), " =#\n\n"
        )
    )
    write_state(dir)

    requests = Channel{Request}(32)
    @async accept_loop(server, requests)
    return requests
end

cache_root() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "julia-daemon")

"""
    serve_session(; name = "repl")

Serve the current interactive julia session as a jld daemon: it appears in
`jld list`, and agents can evaluate into it, read its transcript, inspect its
stacks, and paste into its REPL. Revise is used if available in the session.
"""
function serve_session(; name::AbstractString = "repl")
    isempty(STATE_DIR[]) || error("this session is already serving as $(id())")
    proj = Base.active_project()
    proj === nothing && error("no active project")
    project = realpath(dirname(proj))
    slug = replace(basename(project), r"[^A-Za-z0-9_.-]" => "-")
    namesan = replace(name, r"[^A-Za-z0-9_.-]" => "-")
    isempty(namesan) && error("name must be non-empty")
    sid = string(slug, "-", namesan, "-", bytes2hex(SHA.sha1(project * "\0" * namesan))[1:8])
    dir = joinpath(cache_root(), sid)
    mkpath(dir)
    chmod(dirname(dir), 0o700)
    chmod(dir, 0o700)  # the socket grants code execution as this user
    open(joinpath(dir, "config.toml"), "w") do io
        TOML.print(
            io, Dict{String, Any}(
                "project" => project, "name" => namesan, "kind" => "session",
                "julia" => joinpath(Sys.BINDIR, "julia"), "startup" => String[]
            )
        )
    end
    atexit() do
        Sys.iswindows() || rm(daemon_sock(dir), force = true)
    end
    LOG_IO[] = open(joinpath(dir, "daemon.log"), "a")
    SESSION[] = true
    requests = setup_server(dir)
    if requests === nothing
        SESSION[] = false
        error("a daemon is already serving as $sid; pass a different name")
    end
    EVAL_TASK[] = Base.errormonitor(Threads.@spawn :default eval_loop(requests))
    if isinteractive()
        @async serve_input(input_sock(dir))  # `jld eval-repl` paste target
        try
            install_session_input_transcript()
        catch e
            logmsg("could not hook REPL input into the transcript: $(sprint(showerror, e))")
        end
    end
    println("jld: serving this session as ", sid)
    println("     agents: jld --id=$sid eval '<code>' | transcript | stacks | eval-repl")
    HAVE_REVISE || println("     note: Revise is not loaded, source edits will not auto-apply")
    return sid
end

# Record the session's own REPL inputs in the transcript (their outputs render
# through the REPL display path and are not captured). The REPL backend may
# not exist yet when serve_session runs from -e or startup.jl — poll for it.
function install_session_input_transcript()
    @async begin
        t0 = time()
        while time() - t0 < 30
            backend = isdefined(Base, :active_repl_backend) ? Base.active_repl_backend : nothing
            if backend !== nothing
                # First in the chain: record the raw input, not Revise's or
                # softscope's wrapped version of it.
                pushfirst!(
                    backend.ast_transforms, function (ex)
                        try
                            transcript_entry("repl (this session)", exprstring(ex), ""; status = "input")
                        catch
                        end
                        return ex
                    end
                )
                return
            end
            sleep(0.2)
        end
        logmsg("REPL backend never appeared; session inputs will not be recorded")
    end
    return nothing
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
    Sys.iswindows() || rm(sockpath, force = true)
    return listen(sockpath)
end

function write_state(dir)
    d = Dict{String, Any}(
        "pid" => Libc.getpid(),
        "julia_version" => string(VERSION),
        "julia_bindir" => Sys.BINDIR,
        "project" => something(Base.active_project(), ""),
        "started" => STARTED[],
        "kind" => SESSION[] ? "session" : "daemon",
    )
    tmp = joinpath(dir, ".daemon.toml.tmp")
    open(tmp, "w") do io
        TOML.print(io, d)
    end
    return mv(tmp, joinpath(dir, "daemon.toml"), force = true)
end

function state_toml()
    cur = CURRENT[]
    d = Dict{String, Any}(
        "pid" => Libc.getpid(),
        "busy" => cur !== nothing,
        "uptime" => round(time() - STARTED[], digits = 1),
        "julia_version" => string(VERSION),
        "project" => something(Base.active_project(), ""),
        "id" => id(),
        "name" => NAME[],
        "transcript" => TRANSCRIPT_PATH[],
        "kind" => SESSION[] ? "session" : "daemon",
        "proto" => JLD_PROTO,
        "revise" => HAVE_REVISE,
        "revise_disabled" => REVISE_DISABLED,
        "booting" => BOOTING[],
        "startup_failed" => STARTUP_ERROR[],
        "idle_timeout" => IDLE_TTL[],
        # Time since the last request was received or finished (= uptime until
        # the first one); pings and `jld list` do not reset it.
        "idle_for" => max(0.0, round(time() - LAST_ACTIVITY[], digits = 1)),
        "seen_request" => SEEN_REQUEST[],
    )
    if cur !== nothing
        d["current"] = first(cur.code, 120)
        d["current_elapsed"] = round(time() - CURRENT_T0[], digits = 1)
    end
    return sprint(io -> TOML.print(io, d))
end

function accept_loop(server, requests)
    while true
        conn = try
            accept(server)
        catch e
            e isa InterruptException && continue
            # A deaf daemon is worse than a noisy one: only give up when the
            # server itself is gone; transient errors (e.g. fd exhaustion)
            # are retried.
            if !isopen(server)
                logmsg("accept loop terminated: $(sprint(showerror, e))")
                return
            end
            logmsg("accept error (retrying): $(sprint(showerror, e))")
            sleep(0.1)
            continue
        end
        @async handle_connection(conn, requests)
    end
    return
end

function handle_connection(conn, requests)
    return try
        kind, payload = read_frame(conn)
        if kind == "ping"
            write_frame(conn, "pong", state_toml())
            close(conn)
        elseif kind == "shutdown"
            if SESSION[]
                write_frame(conn, "warn", "this daemon is an interactive julia session; exit it from its REPL")
                write_frame(conn, "done", "status = \"refused\"\n")
                close(conn)
            else
                logmsg("shutdown requested")
                write_frame(conn, "done", "status = \"ok\"\n")
                close(conn)
                exit(0)
            end
        elseif kind == "interrupt"
            ok = interrupt_eval()
            write_frame(conn, "done", "status = \"$(ok ? "ok" : "noop")\"\n")
            close(conn)
        elseif kind == "stacks"
            out = try
                Base.invokelatest(collect_stacks)::String
            catch e
                "collecting stacks failed: " * sprint(showerror, e) * "\n"
            end
            write_frame(conn, "out", out)
            write_frame(conn, "done", "status = \"ok\"\n")
            close(conn)
        elseif kind == "complete"
            LAST_ACTIVITY[] = time()
            SEEN_REQUEST[] = true
            d = try
                TOML.parse(payload)
            catch
                Dict{String, Any}()
            end
            reply = try
                Base.invokelatest(
                    remote_completions,
                    string(get(d, "partial", "")), string(get(d, "full", ""))
                )
            catch
                Dict{String, Any}("completions" => String[], "partial" => "", "should" => false)
            end
            write_frame(conn, "completions", sprint(io -> TOML.print(io, reply)))
            close(conn)
        elseif kind == "req"
            LAST_ACTIVITY[] = time()
            SEEN_REQUEST[] = true
            d = TOML.parse(payload)
            mo = Int(get(d, "max_output", 0))
            outcap = if mo > 0
                tailmax = clamp(mo ÷ 4, 256, CAP_TAIL)
                Capture(max(mo - tailmax, 256), tailmax)
            else
                nothing
            end
            req = Request(
                d["kind"], d["code"], get(d, "cwd", ""),
                get(d, "module", ""), get(d, "scratch", false),
                string(get(d, "client", "")), get(d, "color", false),
                conn, Ref(false), Ref(false), Ref(false), ReentrantLock(), Capture(), outcap
            )
            cur = CURRENT[]
            if cur !== nothing
                write_frame(
                    conn, "warn",
                    "daemon busy ($(round(time() - CURRENT_T0[], digits = 1))s into `$(first(cur.code, 60))`), request queued"
                )
            end
            put!(requests, req)
            request_reader(req)
        else
            close(conn)
        end
    catch e
        e isa InterruptException || logmsg("connection error: $(sprint(showerror, e))")
        try
            close(conn)
        catch end
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
                # Queued, not running: cancel and answer now — the client may
                # be enforcing --timeout and must not wait behind the queue
                # (or worse, escalate to killing the daemon over it).
                req.cancelled[] = true
                req.done[] = true
                safe_send(req, "done", "status = \"interrupted\"\n")
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
    return
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
        # Nothing per-request may escape this loop: if EVAL_TASK dies the whole
        # daemon goes with it (serve waits on it), silently dropping the session
        # and its state. In particular a stray InterruptException — a
        # disconnect-race interrupt that lands after its eval already finished —
        # must be swallowed here rather than propagate.
        try
            if req.cancelled[]
                req.done[] || safe_send(req, "done", "status = \"interrupted\"\n")
            else
                CURRENT[] = req
                CURRENT_T0[] = time()
                run_request(req)
            end
        catch e
            e isa InterruptException || logmsg("request failed internally: $(sprint(showerror, e, catch_backtrace()))")
        finally
            CURRENT[] = nothing
            LAST_ACTIVITY[] = time()
            SEEN_REQUEST[] = true
            req.done[] = true
            try
                close(req.sock)
            catch end
        end
    end
    return
end

function safe_send(req, kind, payload)
    req.broken[] && return
    return try
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
            data = readavailable(rd)
            cap_write!(req.cap, data)
            if req.outcap === nothing
                safe_send(req, kind, String(data))
            else
                stream_capped(req, kind, data)
            end
        catch e
            e isa InterruptException && continue
            return
        end
    end
    return
end

# --max-output: stream only what fits the head budget live; the rest goes
# into the ring, and flush_capped delivers the tail (plus an omission marker
# if the middle overflowed the ring) when the request finishes. cap_write!
# fills the head from the front of `data`, so the streamed bytes are exactly
# the head growth.
function stream_capped(req, kind, data)
    oc = req.outcap
    before = length(oc.head)
    cap_write!(oc, data)
    n = length(oc.head) - before
    return n > 0 && safe_send(req, kind, String(data[1:n]))
end

# stdout and stderr share the budget, so the withheld tail is interleaved in
# arrival order; it is delivered as stdout.
function flush_capped(req)
    oc = req.outcap
    oc === nothing && return
    oc.total > length(oc.head) || return
    omitted = cap_omitted(oc)
    tail = String(cap_tail(oc))
    marker = omitted > 0 ? "\n⋯ jld: $omitted bytes of output omitted (--max-output) ⋯\n" : ""
    return safe_send(req, "out", marker * tail)
end

function run_request(req)
    t0 = time()
    safe_send(req, "ack", "")
    orig_stdout, orig_stderr = stdout, stderr
    rd_out, wr_out = redirect_stdout()
    rd_err, wr_err = redirect_stderr()
    # Pump on the interactive thread so output streams while the eval computes.
    pump_out = Threads.@spawn :interactive pump(rd_out, "out", req)
    pump_err = Threads.@spawn :interactive pump(rd_err, "err", req)

    status = "ok"
    exitcode = 0
    resultstr = nothing
    evalmod = nothing
    try
        if HAVE_REVISE
            try
                Revise.revise()
            catch e
                is_interrupt(e) && rethrow()
                safe_send(req, "warn", "Revise.revise() threw: $(sprint(showerror, e))")
            end
            for w in revise_warnings()
                cap_write!(req.cap, "jld: " * w * "\n")
                safe_send(req, "warn", w)
            end
        end

        # invokelatest: these reflect over bindings created by earlier requests
        evalmod = req.scratch ? Base.invokelatest(scratch_module) :
            Base.invokelatest(eval_module, req.mod)::Module
        result = with_in_eval() do
            withcwd(req.cwd) do
                if req.kind == "include"
                    Base.include(REPL.softscope, evalmod, req.code)
                else
                    include_string(REPL.softscope, evalmod, req.code, "jld-eval")
                end
            end
        end
        evalmod === Main && setglobal!(Base.MainInclude, :ans, result)
        if result !== nothing && req.kind == "eval" && !endswith(rstrip(req.code), ';')
            # invokelatest: rendering may hit methods/bindings defined by this request
            resultstr = Base.invokelatest(render, result, req.color)
        end
        result = nothing
    catch e
        ee = unwrap_exit(e)
        if is_interrupt(e)
            status = "interrupted"
        elseif ee !== nothing
            status = "exit"
            exitcode = ee.code
        else
            status = "error"
            bt = catch_backtrace()
            print(stderr, Base.invokelatest(format_error, e, bt, req.color)::String)
            Base.invokelatest(save_full_error, e, bt)
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

    req.scratch && evalmod isa Module && Base.invokelatest(scrub_module, evalmod)

    flush_capped(req)
    if resultstr !== nothing
        cap_write!(req.cap, endswith(resultstr, '\n') ? resultstr : resultstr * "\n")
        safe_send(req, "result", resultstr)
    end
    donepayload = "status = \"$status\"\nelapsed = $(round(time() - t0, digits = 3))\n"
    status == "exit" && (donepayload *= "exitcode = $exitcode\n")
    # Mark done before sending, not after: the client closes its end the instant
    # it reads the done frame, and the request reader must not mistake that close
    # for a disconnect-during-eval and fire a (now stray) interrupt.
    req.done[] = true
    safe_send(req, "done", donepayload)
    # For files, record the contents: scratch scripts get rewritten between
    # runs, so the path alone would lose the session history.
    if req.kind == "include"
        source = (req.scratch ? "jld run --scratch " : "jld run ") * req.code
        input = try
            read(req.code, String)
        catch
            "include($(repr(req.code)))"
        end
    else
        source = req.client == "repl" ? "repl" :
            req.scratch ? "jld eval --scratch" : "jld eval"
        input = req.code
    end
    isempty(req.mod) || (source *= " in Main.$(req.mod)")
    status == "exit" && (status = "exit($exitcode)")
    transcript_entry(source, rstrip(input), cap_string(req.cap); status, elapsed = time() - t0)
    return logmsg("request finished: $status ($(round(time() - t0, digits = 2))s) `$(first(req.code, 80))`")
end

withcwd(f, dir) = (isempty(dir) || !isdir(dir)) ? f() : cd(f, dir)

# Get-or-create a named module under Main (a persistent workspace).
function eval_module(name::AbstractString)
    isempty(name) && return Main
    Base.isidentifier(name) || error("--module must be a simple identifier, got \"$name\"")
    s = Symbol(name)
    if isdefined(Main, s)
        m = getglobal(Main, s)
        m isa Module || error("Main.$name exists and is not a module")
        return m
    end
    return Core.eval(Main, Expr(:module, true, s, Expr(:block)))
end

# Fresh throwaway module that can see Main: every current Main binding is
# imported (aliases — they retain nothing beyond what Main already holds).
function scratch_module()
    m = Module(gensym("jld_scratch"))
    Core.eval(m, :(eval(x) = Core.eval($m, x)))
    Core.eval(m, :(include(f) = Base.include($m, f)))
    for n in names(Main; all = true, imported = true)
        (startswith(String(n), "#") || n in (:Main, :Base, :Core, :eval, :include)) && continue
        isdefined(Main, n) || continue
        try
            Core.eval(m, Expr(:import, Expr(:(:), Expr(:., :Main), Expr(:., n))))
        catch
        end
    end
    return m
end

# Release everything a scratch eval created, so no strong references are kept.
# Imported aliases reject assignment and are skipped, which is exactly right.
function scrub_module(m::Module)
    for n in names(m; all = true)
        startswith(String(n), "#") && continue
        isdefined(m, n) || continue
        v = getglobal(m, n)
        (v === m || v === nothing) && continue
        try
            setglobal!(m, n, nothing)
        catch
            try
                Core.eval(m, :(const $n = nothing))
            catch
            end
        end
    end
    return
end

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
    return out
end

function render(x, color::Bool = false)
    return try
        sprint() do io
            show(
                IOContext(io, :limit => true, :displaysize => (30, 120), :color => color),
                MIME"text/plain"(), x
            )
        end
    catch e
        "«error showing value of type $(typeof(x)): $(sprint(showerror, e))»"
    end
end

# Frames from Base/stdlib or installed packages, i.e. not code the user can
# edit. In a checkout daemon the checkout (Base and stdlib included) IS the
# user's code, so anything under it stays visible.
function is_internal_frame(fr)
    fr.from_c && return true
    f = String(fr.file)
    !isempty(CHECKOUT[]) && startswith(f, CHECKOUT[]) && return false
    # Base's build-relative source paths: "./abstractarray.jl" on 1.12 unix,
    # ".\abstractarray.jl" on windows, bare "abstractarray.jl" on nightly.
    isabspath(f) || return true
    startswith(f, Sys.STDLIB) && return true
    any(d -> startswith(f, joinpath(d, "packages")), Base.DEPOT_PATH) && return true
    return false
end

# Collapse runs of internal frames: the innermost frame of a run names the
# throw site and is kept; the frames above it are machinery between there and
# the user's code, which `jld trace` can show in full.
function collapse_stack(st)
    kept = eltype(st)[]
    hidden = 0
    i = firstindex(st)
    while i <= lastindex(st)
        if !is_internal_frame(st[i])
            push!(kept, st[i])
            i += 1
            continue
        end
        j = i
        while j < lastindex(st) && is_internal_frame(st[j + 1])
            j += 1
        end
        push!(kept, st[i])
        # Hiding one or two frames saves less than the marker line costs.
        j - i >= 2 ? (hidden += j - i) : append!(kept, st[(i + 1):j])
        i = j + 1
    end
    return kept, hidden
end

function format_error(e, bt, color::Bool = false; collapse::Bool = true)
    st = Base.stacktrace(bt)
    n = findfirst(fr -> String(fr.file) == @__FILE__, st)
    n !== nothing && (st = st[1:(n - 1)])
    # Drop include machinery frames between user code and the daemon.
    while !isempty(st) && (endswith(String(st[end].file), "loading.jl") || endswith(String(st[end].file), "Base_compiler.jl"))
        pop!(st)
    end
    hidden = 0
    collapse && ((st, hidden) = collapse_stack(st))
    return sprint() do io
        ioc = IOContext(io, :limit => true, :color => color)
        print(ioc, "ERROR: ")
        showerror(ioc, e, st)
        println(ioc)
        hidden > 0 && println(ioc, "⋯ $hidden internal frames hidden; `jld trace` shows the full backtrace ⋯")
    end
end

# The uncollapsed backtrace of the last eval error, for `jld trace`. Evals are
# serialized, so plain overwrite is safe.
function save_full_error(e, bt)
    isempty(STATE_DIR[]) && return
    return try
        open(joinpath(STATE_DIR[], "lasterror.log"), "w") do io
            println(
                io, "#= ", Libc.strftime("%Y-%m-%d %H:%M:%S", time()),
                " full backtrace of the last eval error =#"
            )
            write(io, format_error(e, bt, false; collapse = false))
        end
    catch
    end
end

# The test env replaces the active project, so it must be in place before any
# --startup code or eval loads the package. Unlike failing --startup code this
# is fatal: a --test daemon without the test environment would silently serve
# the wrong dependencies, so exit and let the client surface the log.
function activate_testenv()
    logmsg("activating the test environment (TestEnv.activate())")
    return try
        Core.eval(@__MODULE__, :(import TestEnv))
        Base.invokelatest() do
            TestEnv.activate()
        end
        logmsg("test environment active: $(something(Base.active_project(), "?"))")
    catch e
        logmsg("TestEnv.activate() failed: $(sprint(showerror, e, catch_backtrace()))")
        exit(1)
    end
end

function run_startup(code)
    return try
        include_string(REPL.softscope, Main, code, "jld-startup")
        true
    catch e
        logmsg("startup error: $(sprint(showerror, e, catch_backtrace()))")
        false
    end
end

end # module
