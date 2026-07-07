module JuliaDaemon

include("client.jl")

"""
    JuliaDaemon.serve(; name="repl")

Turn the current interactive julia session into a jld server: it appears in
`jld list`, and agents can `jld --id=<id> eval` into it, read its transcript,
inspect its stacks, and paste into its REPL with `jld eval-repl`. Uses Revise
and RemoteREPL when they are loadable in this session.

The daemon code is loaded on first call (into `Main.JLDDaemon`), keeping
`using JuliaDaemon` itself lightweight.
"""
function serve(; name::AbstractString="repl")
    if !isdefined(Main, :JLDDaemon)
        Base.include(Main, joinpath(@__DIR__, "daemon.jl"))
    end
    # Both binding lookups must also happen in the latest world: Main.JLDDaemon
    # was created by the include above (julia 1.12 binding world-age).
    Base.invokelatest() do
        Main.JLDDaemon.serve_session(; name)
    end
end

function (@main)(args)
    cli_main(collect(String, args))
    return 0
end

precompile(main, (Vector{String},))
precompile(run_cli, (Vector{String},))
precompile(stream_response, (Ctx, Base.PipeEndpoint, Dict{String,Any}))
precompile(try_ping, (String,))
precompile(cmd_start, (Ctx, Dict{String,Any}))

end
