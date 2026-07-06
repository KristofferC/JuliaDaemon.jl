# Wire protocol shared by client and daemon: "TYPE LEN\n" header, then LEN payload bytes.
# Plain strings only, so client and daemon can run different Julia versions.

# Bumped when behavior changes enough that a daemon still running older code
# should be restarted; the client warns on mismatch.
const JLD_PROTO = 1

# A stray writer on the socket must not make us allocate unboundedly from a
# garbage length header.
const MAX_FRAME = 128 * 1024 * 1024

# Rendezvous endpoints: unix domain sockets on posix; named pipes on Windows
# (same Sockets API, but they live in the pipe namespace, not the filesystem).
# Unix socket paths are limited to ~104 bytes (macOS), so sockets live in a
# short per-user runtime dir under a name derived from the state dir — never
# inside the (arbitrarily deep) state dir itself.
import SHA as JLD_SHA

function sock_runtime_dir()
    base = get(ENV, "XDG_RUNTIME_DIR", "")
    if isempty(base) || !isdir(base)
        uid = ccall(:getuid, Cuint, ())
        base = joinpath(tempdir(), "jld-$uid")
    else
        base = joinpath(base, "jld")
    end
    isdir(base) || (mkpath(base); chmod(base, 0o700))
    base
end

sock_tag(dir) = bytes2hex(JLD_SHA.sha1(abspath(dir)))[1:16]

daemon_sock(dir) = Sys.iswindows() ? "\\\\.\\pipe\\jld-" * sock_tag(dir) :
                   joinpath(sock_runtime_dir(), sock_tag(dir) * ".sock")
input_sock(dir) = Sys.iswindows() ? "\\\\.\\pipe\\jld-" * sock_tag(dir) * "-r" :
                  joinpath(sock_runtime_dir(), sock_tag(dir) * "-r.sock")

# Whether something serves the endpoint right now (pipes have no fs entry, so
# probing means connecting).
function sock_serving(path)
    conn = try
        Sockets.connect(path)
    catch
        return false
    end
    close(conn)
    true
end

function write_frame(io::IO, kind::AbstractString, payload::AbstractString="")
    data = codeunits(payload)
    buf = IOBuffer(sizehint=length(data) + 16)
    write(buf, kind, ' ', string(length(data)), '\n', data)
    write(io, take!(buf))
    flush(io)
    nothing
end

function read_frame(io::IO)
    header = readline(io)
    isempty(header) && return ("eof", "")
    parts = split(header, ' ')
    length(parts) == 2 || return ("eof", "")
    len = tryparse(Int, parts[2])
    (len === nothing || len < 0 || len > MAX_FRAME) && return ("eof", "")
    data = read(io, len)
    length(data) == len || return ("eof", "")
    (String(parts[1]), String(data))
end
