using JET
using Test
using JuliaDaemon

@testset "JET.jl" begin
    JET.test_package(JuliaDaemon; target_modules = (JuliaDaemon,), toplevel_logger = nothing)
end
