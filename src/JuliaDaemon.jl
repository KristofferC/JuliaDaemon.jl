module JuliaDaemon

include("client.jl")

function (@main)(args)
    run_cli(collect(String, args))
    return 0
end

end
