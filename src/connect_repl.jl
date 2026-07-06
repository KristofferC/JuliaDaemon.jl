# Run via `julia -i connect_repl.jl <daemon-sock> [input-sock] [daemon-id]`:
# installs a REPL mode (prompt `julia@<id]>`) whose input is evaluated in a
# jld daemon over its framed text protocol. No serialization: any julia
# version can attach to any daemon, and completions use their own connection,
# so a slow reply can never desynchronize the eval stream.
module JLDConnect

import REPL
import REPL.LineEdit
import Sockets
import TOML

include("protocol.jl")
include("repl_input.jl")

const SOCKPATH = Ref("")
const DAEMON_ID = Ref("daemon")

# ---- remote evaluation over the daemon socket ----

function remote_eval(out::IO, code::AbstractString)
    conn = try
        Sockets.connect(SOCKPATH[])
    catch
        println(out, "jld: cannot reach the daemon (see `jld status`)")
        return
    end
    req = Dict{String,Any}("kind" => "eval", "code" => String(code), "cwd" => pwd(),
                           "client" => "repl", "color" => true)
    try
        write_frame(conn, "req", sprint(io -> TOML.print(io, req)))
    catch
        println(out, "jld: failed to send to the daemon")
        try close(conn) catch end
        return
    end
    lost = Ref(false)
    reader = @async begin
        while true
            kind, payload = read_frame(conn)
            if kind == "out" || kind == "err"
                write(out, payload)
                flush(out)
            elseif kind == "result"
                write(out, payload)
                endswith(payload, '\n') || write(out, '\n')
                flush(out)
            elseif kind == "warn"
                println(out, "jld: ", payload)
            elseif kind == "done"
                return
            elseif kind == "eof"
                lost[] = true
                return
            end
        end
    end
    # Ctrl-C while waiting forwards an interrupt to the daemon; the reader
    # task keeps the frame stream aligned.
    while !istaskdone(reader)
        try
            wait(reader)
        catch e
            if e isa InterruptException
                try
                    write_frame(conn, "interrupt")
                catch
                end
                continue
            end
            lost[] = true
            break
        end
    end
    lost[] && println(out, "jld: connection to the daemon lost (see `jld logs`)")
    try
        close(conn)
    catch
    end
    nothing
end

# ---- completions: one short-lived connection per TAB ----

struct RemoteCompletions <: LineEdit.CompletionProvider end

function LineEdit.complete_line(::RemoteCompletions, s::LineEdit.PromptState; hint::Bool=false)
    # No per-keystroke round-trips for autosuggest hints.
    hint && return (String[], "", false)
    buf = LineEdit.buffer(s)
    partial = String(buf.data[1:buf.ptr-1])
    full = LineEdit.input_string(s)
    empty = (String[], "", false)
    conn = try
        Sockets.connect(SOCKPATH[])
    catch
        return empty
    end
    result = empty
    try
        write_frame(conn, "complete",
                    sprint(io -> TOML.print(io, Dict("partial" => partial, "full" => full))))
        t = @async read_frame(conn)
        if timedwait(() -> istaskdone(t), 3.0; pollint=0.05) === :ok
            kind, payload = fetch(t)
            if kind == "completions"
                d = TOML.parse(payload)
                result = (Vector{String}(d["completions"]), String(d["partial"]), Bool(d["should"]))
            end
        end
    catch
    finally
        try
            close(conn)
        catch
        end
    end
    result
end

# ---- the REPL mode ----

function buffer_empty()
    try
        ps = LineEdit.state(Base.active_repl.mistate)
        return LineEdit.buffer(ps).size == 0
    catch
        return false
    end
end

function install_mode(repl)
    main_mode = repl.interface.modes[1]
    hp = main_mode.hist

    mode = LineEdit.Prompt(() -> string("julia@", DAEMON_ID[], "> ");
        prompt_prefix = repl.hascolor ? Base.text_colors[:magenta] : "",
        prompt_suffix = repl.hascolor ?
            (repl.envcolors ? Base.input_color : repl.input_color()) : "",
        complete = RemoteCompletions(),
        on_enter = isdefined(REPL, :return_callback) ? REPL.return_callback : Returns(true),
        sticky = true)
    mode.on_done = REPL.respond(repl, mode; pass_empty=false) do line
        remote_eval(REPL.outstream(repl), line)
        nothing
    end

    hp.mode_mapping[:jld_remote] = mode
    mode.hist = hp

    keymaps = Dict{Any,Any}[
        REPL.mode_keymap(main_mode),          # backspace on empty: back to julia>
        LineEdit.setup_prefix_keymap(hp, mode)[2],
        LineEdit.history_keymap,
        LineEdit.default_keymap,
        LineEdit.escape_defaults,
    ]
    if isdefined(LineEdit, :setup_search_keymap)  # removed on julia ≥1.13
        pushfirst!(keymaps, LineEdit.setup_search_keymap(hp)[2])
    end
    mode.keymap_dict = LineEdit.keymap(keymaps)

    push!(repl.interface.modes, mode)

    enter_key = Dict{Any,Any}(
        '>' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, mode) do
                    LineEdit.state(s, mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, '>')
            end
        end)
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, enter_key)
    nothing
end

function setup(repl)
    try
        # Wait for the interactive REPL to be fully up (startup.jl may be slow).
        t0 = time()
        while time() - t0 < 10
            isdefined(repl, :mistate) && repl.mistate !== nothing && break
            sleep(0.05)
        end
        install_mode(repl)
        # Land the user at the remote prompt, unless they already typed.
        buffer_empty() && inject_input(">")
    catch err
        @error "jld: failed to set up the remote REPL mode; use `jld eval` from the shell" exception =
            (err, catch_backtrace())
    end
    nothing
end

end # module

let sockpath = ARGS[1],
    inputsock = length(ARGS) >= 2 ? ARGS[2] : "",
    daemonid = length(ARGS) >= 3 ? ARGS[3] : "daemon"

    JLDConnect.SOCKPATH[] = sockpath
    JLDConnect.DAEMON_ID[] = daemonid
    atreplinit(repl -> @async JLDConnect.setup(repl))
    isempty(inputsock) || @async JLDConnect.serve_input(inputsock)
end
