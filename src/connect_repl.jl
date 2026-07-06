# Run via `julia -i connect_repl.jl <port>`: attaches this REPL to a jld
# daemon's RemoteREPL server, entered with '>'.
import RemoteREPL, REPL

function jld_connect(repl, port)
    try
        # Wait for the interactive REPL to be fully up (startup.jl may be slow).
        t0 = time()
        while time() - t0 < 10
            isdefined(repl, :mistate) && repl.mistate !== nothing && break
            sleep(0.05)
        end
        # julia master removed LineEdit.setup_search_keymap (History refactor),
        # which ReplMaker still calls. Stub it out: the remote mode then simply
        # has no Ctrl-R search.
        if !isdefined(REPL.LineEdit, :setup_search_keymap)
            @eval REPL.LineEdit setup_search_keymap(hp) = (nothing, Dict{Any,Any}())
        end
        Base.invokelatest(RemoteREPL.connect_repl, port)
    catch err
        @error "jld: failed to set up the remote REPL mode. Falling back: use `RemoteREPL.@remote <expr>` here, or `jld eval` from the shell." exception =
            (err, catch_backtrace())
    end
    nothing
end

let port = parse(Int, ARGS[1])
    atreplinit(repl -> @async jld_connect(repl, port))
end
