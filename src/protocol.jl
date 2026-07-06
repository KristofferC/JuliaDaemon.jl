# Wire protocol shared by client and daemon: "TYPE LEN\n" header, then LEN payload bytes.
# Plain strings only, so client and daemon can run different Julia versions.

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
    len === nothing && return ("eof", "")
    data = read(io, len)
    length(data) == len || return ("eof", "")
    (String(parts[1]), String(data))
end
