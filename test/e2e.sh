#!/usr/bin/env bash
# End-to-end test for jld. Requires a working `julia` on PATH (or JLD_JULIA).
# Hermetic: daemon state lives in a temp XDG_CACHE_HOME.
set -uo pipefail

JLD_HOME="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
WORK="$(mktemp -d)"
# On Windows (Git Bash), use mixed-form paths (C:/...) that both bash and
# native julia understand.
if command -v cygpath >/dev/null 2>&1; then
    JLD_HOME="$(cygpath -m "$JLD_HOME")"
    WORK="$(cygpath -m "$WORK")"
fi
JLD="$JLD_HOME/bin/jld"
export XDG_CACHE_HOME="$WORK/cache"
NAME="e2e$$"
FAILS=0
SESSPID=""

check() { # check <desc> <expected-exit> <actual-exit>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected exit $2, got $3)"; FAILS=$((FAILS+1)); fi
}
checkout() { # checkout <desc> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then echo "ok: $1"; else echo "FAIL: $1 (missing: $2)"; echo "$3"; FAILS=$((FAILS+1)); fi
}

cleanup() {
    for n in $NAME iso; do
        "$JLD" --project="$WORK/ToyPkg" --name=$n kill >/dev/null 2>&1
    done
    [ -n "$SESSPID" ] && kill -9 $SESSPID >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

julia --startup-file=no -e "using Pkg; Pkg.generate(\"$WORK/ToyPkg\")" >/dev/null 2>&1
# Pkg.generate's template varies across julia versions; use known content.
cat > "$WORK/ToyPkg/src/ToyPkg.jl" <<'EOF'
module ToyPkg
greet() = print("Hello World!")
end
EOF
cd "$WORK/ToyPkg"
J="$JLD --name=$NAME"

# ---- basic eval / revise / errors ----

out=$($J eval 'using ToyPkg; ToyPkg.greet()' 2>/dev/null)
check "autostart+load" 0 $?
checkout "greet output" "Hello World!" "$out"

out=$($J eval '1 + 1' 2>/dev/null)
checkout "result display" "2" "$out"

cat > src/ToyPkg.jl <<'EOF'
module ToyPkg
greet() = print("Hello World!")
double(x) = 2x
end
EOF
out=$($J eval 'ToyPkg.double(21)' 2>/dev/null)
checkout "revise picks up new function" "42" "$out"

$J eval 'error("boom")' >/dev/null 2>&1
check "error exit code" 1 $?

out=$($J eval 'sqrt(-1)' 2>&1)
checkout "backtrace shown" "DomainError" "$out"

# ---- interrupts ----

$J --timeout=2 eval 'sleep(60)' >/dev/null 2>&1
check "timeout interrupt" 124 $?

$J eval 'sleep(30)' >/dev/null 2>&1 &
EVPID=$!
sleep 2
$J interrupt >/dev/null 2>&1
wait $EVPID
check "jld interrupt aborts the eval" 130 $?

out=$($J eval '1 + 2' 2>/dev/null)
check "daemon survived interrupts" 0 $?
checkout "daemon state intact" "3" "$out"

# ---- busy behavior ----

$J eval 'sleep(3); "first"' >/dev/null 2>&1 &
sleep 1
out=$($J eval '"second"' 2>&1)
check "queued eval succeeds" 0 $?
checkout "queueing is reported" "queued" "$out"
wait

$J eval 'Libc.systemsleep(5)' >/dev/null 2>&1 &
sleep 1.5
out=$($J status 2>/dev/null)
checkout "status answers during CPU-bound eval" "busy" "$out"
wait

# ---- files, modules, scratch ----

echo 'scratch_result = sum(1:10)' > "$WORK/scratch.jl"
out=$($J run "$WORK/scratch.jl" 2>/dev/null; $J eval 'scratch_result' 2>/dev/null)
checkout "run file + state persists" "55" "$out"

out=$($J --module=Wk eval 'wk_x = 7; wk_x' 2>/dev/null; $J eval 'Main.Wk.wk_x * 2, isdefined(Main, :wk_x)' 2>/dev/null)
checkout "module workspace" "(14, false)" "$out"

out=$($J eval 'sc_ref = 5;' 2>/dev/null; $J eval-scratch 'sc_tmp = sc_ref * 3' 2>/dev/null; $J eval 'isdefined(Main, :sc_tmp)' 2>/dev/null)
checkout "eval-scratch sees Main, keeps nothing" "15
false" "$out"

# ---- introspection ----

out=$($J stacks 2>/dev/null)
check "stacks" 0 $?
checkout "stacks reports threads" "Thread" "$out"

out=$($J eval 'Main.JLDDaemon.id()' 2>/dev/null)
checkout "daemon knows its id" "ToyPkg-$NAME" "$out"

# ---- targeting ----

out=$($JLD --id=ToyPkg-$NAME eval '"by id"' 2>/dev/null)
checkout "eval by --id prefix" "by id" "$out"

out=$($JLD --project="$WORK/ToyPkg" --name=iso eval 'iso_var = 1; "iso ok"' 2>/dev/null)
checkout "second named daemon" "iso ok" "$out"
out=$($J eval 'isdefined(Main, :iso_var)' 2>/dev/null)
checkout "named daemons are isolated" "false" "$out"

out=$($JLD --project="$WORK/ToyPkg" list 2>/dev/null)
checkout "list shows both daemons" "ToyPkg-iso" "$out"

# ---- transcript ----

$J eval 'for i in 1:5000; println("spam ", i); end; "spammed"' >/dev/null 2>&1
out=$($J transcript 2>/dev/null)
checkout "transcript records inputs" "scratch_result = sum(1:10)" "$out"
checkout "transcript records outputs" "Hello World!" "$out"
checkout "transcript truncates big output" "bytes of output omitted" "$out"

# ---- completion protocol (what the attached REPL uses) ----

out=$(julia --startup-file=no -e "
using Sockets
include(\"$JLD_HOME/src/protocol.jl\")
root = \"$XDG_CACHE_HOME/julia-daemon\"
conn = connect(daemon_sock(joinpath(root, filter(startswith(\"ToyPkg-$NAME\"), readdir(root))[1])))
write_frame(conn, \"complete\", \"partial = \\\"prin\\\"\nfull = \\\"prin\\\"\n\")
kind, payload = read_frame(conn)
print(kind, \": \", payload)" 2>/dev/null)
checkout "completion frame answers" "println" "$out"

# ---- session mode ----

julia --startup-file=no --project="$WORK/ToyPkg" -e "
include(\"$JLD_HOME/src/daemon.jl\")
sess_var = 1234
Main.JLDDaemon.serve_session(name=\"ci\")
sleep(120)" > "$WORK/session.out" 2>&1 &
SESSPID=$!
for i in $(seq 1 120); do
    $JLD --id=ToyPkg-ci eval '1' >/dev/null 2>&1 && break
    sleep 0.5
done
out=$($JLD --id=ToyPkg-ci eval 'sess_var + 1' 2>/dev/null)
checkout "eval into a served session" "1235" "$out"
stopout=$($JLD --id=ToyPkg-ci stop 2>&1)
rc=$?
check "stop refused for sessions" 2 $rc
[ $rc -ne 2 ] && echo "stop said: $stopout"
out=$($JLD --id=ToyPkg-ci eval '"session alive"' 2>/dev/null)
checkout "session survived stop" "session alive" "$out"
kill -9 $SESSPID >/dev/null 2>&1
SESSPID=""

# ---- gc / shutdown ----

$JLD --project="$WORK/ToyPkg" --name=iso kill >/dev/null 2>&1
sleep 0.5
out=$($JLD --project="$WORK/ToyPkg" gc 2>&1)
checkout "gc removes dead daemons" "removed" "$out"
out=$($J eval '"still here"' 2>/dev/null)
checkout "gc keeps live daemons" "still here" "$out"

$J stop >/dev/null 2>&1
$J --no-autostart eval '1' >/dev/null 2>&1
check "stopped daemon unreachable" 3 $?

echo
if [ $FAILS -eq 0 ]; then
    echo "PASS (all checks)"
else
    echo "FAIL ($FAILS checks)"
    echo "===== diagnostics ====="
    "$JLD" --project="$WORK/ToyPkg" list 2>&1
    [ -f "$WORK/session.out" ] && { echo "--- session output ---"; cat "$WORK/session.out"; }
    for d in "$XDG_CACHE_HOME"/julia-daemon/*/; do
        echo "--- $d daemon.log (tail) ---"
        tail -30 "$d/daemon.log" 2>/dev/null
    done
    exit 1
fi
