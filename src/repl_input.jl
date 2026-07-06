# Paste injection for `jld eval-repl`, shared by the connect-REPL process and
# in-session servers. Requires REPL, Sockets, and protocol.jl in the
# including module.

# Feed data into the terminal input buffer, as if it arrived from the tty.
function inject_input(data::AbstractString)
    tty = stdin
    lock(tty.cond)
    try
        write(tty.buffer, data)
        notify(tty.cond)
    finally
        unlock(tty.cond)
    end
end

# If the user has a partial line typed at the prompt, take it out of the edit
# buffer (it is re-inserted at the fresh prompt after the paste runs), so the
# paste never splices into their in-progress input.
function stash_pending_input()
    try
        repl = Base.active_repl
        mistate = repl.mistate
        mistate === nothing && return ""
        ps = REPL.LineEdit.state(mistate)
        buf = REPL.LineEdit.buffer(ps)
        pending = String(buf.data[1:buf.size])
        isempty(pending) || take!(buf)
        return pending
    catch
        return ""
    end
end

function serve_input(sockpath)
    rm(sockpath, force=true)
    server = try
        Sockets.listen(sockpath)
    catch err
        @error "jld: cannot serve eval-repl requests" exception = err
        return
    end
    atexit(() -> rm(sockpath, force=true))
    while true
        conn = try
            Sockets.accept(server)
        catch
            return
        end
        @async begin
            try
                kind, payload = read_frame(conn)
                if kind == "paste"
                    # Bracketed-paste markers make LineEdit treat this exactly
                    # like a terminal paste: echoed at the prompt, evaluated,
                    # prompt redrawn. Any half-typed user input is stashed and
                    # re-inserted (without newline) at the prompt afterwards;
                    # byte order in the tty buffer guarantees the sequencing.
                    pending = stash_pending_input()
                    restore = isempty(pending) ? "" : "\e[200~" * pending * "\e[201~"
                    inject_input("\e[200~" * strip(payload, '\n') * "\e[201~\n" * restore)
                    write_frame(conn, "done", "status = \"ok\"\n")
                end
            catch
            end
            try
                close(conn)
            catch
            end
        end
    end
end
