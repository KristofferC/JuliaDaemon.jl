using Aqua
using JuliaDaemon

Aqua.test_all(
    JuliaDaemon;
    deps_compat = (
        ignore = [:SHA, :Sockets, :TOML],
    ),
)
