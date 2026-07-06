# Drives `jld connect` through a real pty and checks the remote REPL end to
# end. Hermetic (temp XDG_CACHE_HOME). Run with: julia test/repl.jl
using Test

const JLD_HOME = dirname(@__DIR__)
const JLD = joinpath(JLD_HOME, "bin", "jld")

const work = mktempdir()
const cache = joinpath(work, "cache")
ENV["XDG_CACHE_HOME"] = cache

run(pipeline(`julia --startup-file=no -e "using Pkg; Pkg.generate(\"$work/ToyPkg\")"`, devnull))
write(joinpath(work, "ToyPkg", "src", "ToyPkg.jl"), """
module ToyPkg
greet() = print("Hello World!")
end
""")
const proj = joinpath(work, "ToyPkg")

# ---- pty plumbing (same approach as Base's FakePTYs test helper) ----

function open_pty()
    O_RDWR = Cint(2)
    O_NOCTTY = Sys.isapple() ? Cint(0x20000) : Cint(0x100)
    fdm = ccall(:posix_openpt, Cint, (Cint,), O_RDWR)
    fdm >= 0 || error("posix_openpt failed")
    ccall(:grantpt, Cint, (Cint,), fdm) == 0 || error("grantpt failed")
    ccall(:unlockpt, Cint, (Cint,), fdm) == 0 || error("unlockpt failed")
    slavename = unsafe_string(ccall(:ptsname, Cstring, (Cint,), fdm))
    fds = ccall(:open, Cint, (Cstring, Cint), slavename, O_RDWR | O_NOCTTY)
    fds >= 0 || error("cannot open pty slave")
    Base.TTY(RawFD(fdm)), RawFD(fds)
end

strip_ansi(s) = replace(s, r"\e\[[0-9;?]*[A-Za-z]" => "", r"\e\][0-9];[^\a]*\a?" => "", "\r" => "")

ptm, pts = open_pty()
const captured = IOBuffer()
reader = @async try
    while !eof(ptm)
        write(captured, readavailable(ptm))
    end
catch
end

send(s) = (write(ptm, s); flush(ptm))
output() = strip_ansi(String(copy(take!(copy(captured)))))

function expect(pattern; timeout=60, desc=pattern)
    t0 = time()
    while time() - t0 < timeout
        occursin(pattern, output()) && return true
        sleep(0.25)
    end
    @error "timed out waiting for $desc" tail = last(output(), 2000)
    false
end

env = copy(ENV)
env["TERM"] = "xterm"
env["COLUMNS"] = "200"
env["LINES"] = "40"
proc = run(setenv(ignorestatus(`$JLD --project=$proj connect`), env), pts, pts, pts; wait=false)

@testset "jld connect (pty)" begin
    # Daemon autostarts, mode installs, remote prompt entered automatically.
    @test expect(r"julia@ToyPkg-[0-9a-f]{8}> "; desc="remote prompt")

    send("using ToyPkg; ToyPkg.greet()\n")
    @test expect("Hello World!"; desc="package call at remote prompt")

    send("println(\"streamed!\"); 6 * 7\n")
    @test expect("streamed!"; desc="streamed print")
    @test expect("42"; desc="result display")

    send("error(\"kaboom\")\n")
    @test expect("kaboom"; desc="remote error shown")

    # TAB completion round-trips through the daemon (second TAB lists).
    send("prin\t")
    sleep(2)
    send("\t")
    @test expect("println"; desc="completion candidates")
    send("\x15")  # clear line

    # Back to the local prompt and into the remote mode again.
    send("\b")
    send("local_var = 5 + 6\n")
    @test expect("11"; desc="local eval after backspace")
    send(">remote_var = 11 * 2\n")
    @test expect("22"; desc="re-entered remote mode")

    # eval-repl paste preserves half-typed input.
    send("half_typed")
    sleep(1)
    runid = readdir(joinpath(cache, "julia-daemon"))[1]
    run(setenv(`$JLD --id=$runid eval-repl 'remote_var * 100'`, env))
    @test expect("2200"; desc="eval-repl paste executed")
    send(" = 2 + 3\n")  # completes the restored half-typed input
    @test expect(r"half_typed = 2 \+ 3\n5"; desc="half-typed input restored and evaluated")

    # The agent sees the REPL's state and the transcript recorded the session.
    agentout = read(setenv(`$JLD --id=$runid eval 'remote_var + 1'`, env), String)
    @test occursin("23", agentout)
    transcript = read(setenv(`$JLD --id=$runid transcript`, env), String)
    @test occursin("repl (ok", transcript)
    @test occursin("streamed!", transcript)

    send("\x04")  # Ctrl-D: exit the REPL
    t0 = time()
    while !process_exited(proc) && time() - t0 < 20
        sleep(0.25)
    end
    @test process_exited(proc)
end

run(setenv(ignorestatus(`$JLD --project=$proj kill`), env))
close(ptm)
rm(work; recursive=true, force=true)
