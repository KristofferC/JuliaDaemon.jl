module JuliaDaemon

include("client.jl")

function (@main)(args)
    run_cli(collect(String, args))
    return 0
end

precompile(main, (Vector{String},))
precompile(run_cli, (Vector{String},))
precompile(stream_response, (Ctx, Base.PipeEndpoint, Dict{String,Any}))
precompile(try_ping, (String,))
precompile(cmd_start, (Ctx, Dict{String,Any}))

end
