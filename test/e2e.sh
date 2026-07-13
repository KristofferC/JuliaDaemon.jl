#!/usr/bin/env bash
# End-to-end test for jld. Requires a working `julia` on PATH (or JLD_JULIA).
# Hermetic: daemon state lives in a temp XDG_CACHE_HOME.
set -uo pipefail
# fd 8: where per-check stderr goes (the step log under trace, else discarded).
if [ -n "${JLD_E2E_TRACE:-}" ]; then set -x; exec 8>&2; else exec 8>/dev/null; fi

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
    for n in $NAME iso idle; do
        "$JLD" --project="$WORK/ToyPkg" --name=$n kill >/dev/null 2>&1
    done
    "$JLD" --project="$WORK/ToyPkg" --name=$NAME --test kill >/dev/null 2>&1
    "$JLD" --project="$WORK/WsPkg" --name=$NAME --test kill >/dev/null 2>&1
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
# Classic test target, for the --test (TestEnv mode) checks.
cat >> "$WORK/ToyPkg/Project.toml" <<'EOF'

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
EOF
cd "$WORK/ToyPkg"
J="$JLD --name=$NAME"

# ---- basic eval / revise / errors ----

out=$($J eval 'using ToyPkg; ToyPkg.greet()' 2>&8)
check "autostart+load" 0 $?
checkout "greet output" "Hello World!" "$out"

out=$($J eval '1 + 1' 2>&8)
checkout "result display" "2" "$out"

cat > src/ToyPkg.jl <<'EOF'
module ToyPkg
greet() = print("Hello World!")
double(x) = 2x
end
EOF
out=$($J eval 'ToyPkg.double(21)' 2>&8)
checkout "revise picks up new function" "42" "$out"

$J eval 'error("boom")' >/dev/null 2>&1
check "error exit code" 1 $?

out=$($J eval 'sqrt(-1)' 2>&1)
checkout "backtrace shown" "DomainError" "$out"

# ---- exit propagation ----

$J eval 'exit(7)' >/dev/null 2>&1
check "exit(N) propagates as exit code" 7 $?
$J eval 'exit()' >/dev/null 2>&1
check "exit() propagates 0" 0 $?
out=$($J eval '"alive after exit"' 2>&8)
checkout "daemon survives exit()" "alive after exit" "$out"

# ---- collapsed backtraces + trace ----

out=$($J eval 'sum(i -> i == 2 ? error("deep boom") : i, 1:3)' 2>&1)
check "deep error exit code" 1 $?
checkout "deep error message shown" "deep boom" "$out"
checkout "internal frames collapsed" "internal frames hidden" "$out"
out=$($J trace 2>&8)
checkout "trace has the error" "deep boom" "$out"
if [[ "$out" == *"internal frames hidden"* ]]; then
    check "trace is uncollapsed" 0 1
else
    check "trace is uncollapsed" 0 0
fi

# ---- --max-output ----

out=$($J --max-output=4k eval 'for i in 1:3000; println("cap ", i); end; "capped"' 2>&8)
check "max-output eval succeeds" 0 $?
checkout "max-output keeps the head" "cap 1
cap 2" "$out"
checkout "max-output keeps the tail" "cap 3000" "$out"
checkout "max-output drops the middle" "bytes of output omitted (--max-output)" "$out"

# Wait until the daemon reports busy (a background eval has landed).
wait_busy() {
    for i in $(seq 1 80); do
        [[ "$($J status 2>&8)" == *busy* ]] && return 0
        sleep 0.25
    done
    return 1
}

# ---- interrupts ----

$J --timeout=2 eval 'sleep(60)' >/dev/null 2>&1
check "timeout interrupt" 124 $?

$J eval 'sleep(30)' >/dev/null 2>&1 &
EVPID=$!
wait_busy
$J interrupt >/dev/null 2>&1
wait $EVPID
check "jld interrupt aborts the eval" 130 $?

out=$($J eval '1 + 2' 2>&8)
check "daemon survived interrupts" 0 $?
checkout "daemon state intact" "3" "$out"

# ---- busy behavior ----

$J eval 'sleep(8); "first"' >/dev/null 2>&1 &
wait_busy
out=$($J eval '"second"' 2>&1)
check "queued eval succeeds" 0 $?
checkout "queueing is reported" "queued" "$out"
wait

$J eval 'Libc.systemsleep(10)' >/dev/null 2>&1 &
if wait_busy; then busyres="busy"; else busyres="never busy"; fi
checkout "status answers during CPU-bound eval" "busy" "$busyres"
wait

# ---- timeout while queued ----

$J eval 'sleep(6); "blocker"' >/dev/null 2>&1 &
BPID=$!
wait_busy
$J --timeout=1 eval '"queued victim"' >/dev/null 2>&1
check "queued eval times out promptly" 124 $?
wait $BPID
out=$($J eval '"queue survivor"' 2>&8)
checkout "daemon survived a queued timeout" "queue survivor" "$out"

# ---- files, modules, scratch ----

echo 'scratch_result = sum(1:10)' > "$WORK/scratch.jl"
out=$($J run "$WORK/scratch.jl" 2>&8; $J eval 'scratch_result' 2>&8)
checkout "run file + state persists" "55" "$out"

out=$($J --module=Wk eval 'wk_x = 7; wk_x' 2>&8; $J eval 'Main.Wk.wk_x * 2, isdefined(Main, :wk_x)' 2>&8)
checkout "module workspace" "(14, false)" "$out"

out=$($J eval 'sc_ref = 5;' 2>&8; $J eval --scratch 'sc_tmp = sc_ref * 3' 2>&8; $J eval 'isdefined(Main, :sc_tmp)' 2>&8)
checkout "eval --scratch sees Main, keeps nothing" "15
false" "$out"

echo 'rs_tmp = sc_ref + 100; println("run-scratch saw ", rs_tmp)' > "$WORK/rscratch.jl"
out=$($J run --scratch "$WORK/rscratch.jl" 2>&8; $J eval 'isdefined(Main, :rs_tmp)' 2>&8)
checkout "run --scratch sees Main, keeps nothing" "run-scratch saw 105
false" "$out"

# ---- introspection ----

out=$($J stacks 2>&8)
check "stacks" 0 $?
checkout "stacks reports threads" "Thread" "$out"

out=$($J eval 'Main.JLDDaemon.id()' 2>&8)
checkout "daemon knows its id" "ToyPkg-$NAME" "$out"

# ---- targeting ----

out=$($JLD --id=ToyPkg-$NAME eval '"by id"' 2>&8)
checkout "eval by --id prefix" "by id" "$out"

out=$($JLD --project="$WORK/ToyPkg" --name=iso --no-revise eval 'iso_var = 1; "iso ok"' 2>&8)
checkout "second named daemon" "iso ok" "$out"
out=$($J eval 'isdefined(Main, :iso_var)' 2>&8)
checkout "named daemons are isolated" "false" "$out"

# ---- --no-revise (the iso daemon autostarted with it) ----

out=$($JLD --project="$WORK/ToyPkg" --name=iso eval 'isdefined(Main, :Revise)' 2>&8)
checkout "no-revise: Revise not loaded" "false" "$out"
# A ping right after boot can transiently fail on slow runners, and a daemon
# can be lost to OS memory pressure under load; re-ensure it each iteration
# (autostart re-reads the recorded --no-revise) and retry briefly.
for i in 1 2 3 4 5; do
    $JLD --project="$WORK/ToyPkg" --name=iso eval '1' >/dev/null 2>&8
    out=$($JLD --project="$WORK/ToyPkg" --name=iso status 2>&8)
    [[ "$out" == *"revise:"* ]] && break
    sleep 1
done
checkout "no-revise: status shows disabled" "disabled (--no-revise)" "$out"
$JLD --project="$WORK/ToyPkg" --name=iso restart >/dev/null 2>&8
out=$($JLD --project="$WORK/ToyPkg" --name=iso eval 'isdefined(Main, :Revise)' 2>&8)
checkout "no-revise: restart keeps it" "false" "$out"
$JLD --project="$WORK/ToyPkg" --name=iso restart --revise >/dev/null 2>&8
out=$($JLD --project="$WORK/ToyPkg" --name=iso eval 'isdefined(Main, :Revise)' 2>&8)
checkout "no-revise: restart --revise re-enables" "true" "$out"

out=$($JLD --project="$WORK/ToyPkg" list 2>&8)
checkout "list shows both daemons" "ToyPkg-iso" "$out"

# ---- --test: test-environment daemons ----

# TestEnv mode: ToyPkg has a classic [extras]/[targets] setup, so the test
# daemon activates via TestEnv at boot. Its active project is a sandbox that
# has ToyPkg as a *dependency* — the package's own Project.toml never does.
sandbox_check='import TOML; haskey(get(TOML.parsefile(Base.active_project()), "deps", Dict()), "ToyPkg") ? "test env active" : "test env NOT active"'
out=$($J --test eval 'using Test, ToyPkg; ToyPkg.double(2)' 2>&8)
check "test daemon starts (TestEnv mode)" 0 $?
checkout "package + test deps load" "4" "$out"
out=$($J --test eval "$sandbox_check" 2>&8)
checkout "TestEnv sandbox is the active project" "test env active" "$out"
out=$($J --test eval 'td_var = 1;' 2>&8; $J eval 'isdefined(Main, :td_var)' 2>&8)
checkout "test daemon is separate from the regular one" "false" "$out"
out=$($JLD --project="$WORK/ToyPkg" list 2>&8)
checkout "test daemon listed with test marker" "ToyPkg-$NAME-test" "$out"
$JLD --id="ToyPkg-$NAME-test" restart >/dev/null 2>&8
out=$($J --test --no-autostart eval "$sandbox_check" 2>&8)
checkout "restart by id keeps the test env" "test env active" "$out"

# Workspace mode: a package that declares test/ as a workspace project is
# served with test/ active directly — no TestEnv. Needs a Pkg with workspace
# support (probed functionally, skipped otherwise); the manifest must be
# resolved by the daemon's julia.
DJULIA="${JLD_JULIA:-julia}"
julia --startup-file=no -e "using Pkg; Pkg.generate(\"$WORK/WsPkg\")" >/dev/null 2>&8
cat > "$WORK/WsPkg/src/WsPkg.jl" <<'EOF'
module WsPkg
triple(x) = 3x
end
EOF
cat >> "$WORK/WsPkg/Project.toml" <<'EOF'

[workspace]
projects = ["test"]
EOF
mkdir -p "$WORK/WsPkg/test"
WSUUID=$(julia --startup-file=no -e "import TOML; print(TOML.parsefile(\"$WORK/WsPkg/Project.toml\")[\"uuid\"])" 2>&8)
cat > "$WORK/WsPkg/test/Project.toml" <<EOF
[deps]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
WsPkg = "$WSUUID"
EOF
if "$DJULIA" --startup-file=no --project="$WORK/WsPkg" -e 'using Pkg; Pkg.resolve()' >/dev/null 2>&8 &&
   "$DJULIA" --startup-file=no --project="$WORK/WsPkg/test" -e 'using WsPkg' >/dev/null 2>&8; then
    out=$($JLD --project="$WORK/WsPkg" --name=$NAME --test eval 'using Test, WsPkg; string(WsPkg.triple(3), " in ", basename(dirname(Base.active_project())))' 2>&8)
    check "workspace test daemon starts" 0 $?
    checkout "test/ is the active project" "9 in test" "$out"
    $JLD --project="$WORK/WsPkg" --name=$NAME --test kill >/dev/null 2>&1
else
    echo "skip: workspace --test (this julia's Pkg lacks workspace support)"
fi

# ---- transcript ----

$J eval 'for i in 1:5000; println("spam ", i); end; "spammed"' >/dev/null 2>&1
out=$($J transcript 2>&8)
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
print(kind, \": \", payload)" 2>&8)
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
out=$($JLD --id=ToyPkg-ci eval 'sess_var + 1' 2>&8)
checkout "eval into a served session" "1235" "$out"
stopout=$($JLD --id=ToyPkg-ci stop 2>&1)
rc=$?
check "stop refused for sessions" 2 $rc
[ $rc -ne 2 ] && echo "stop said: $stopout"
out=$($JLD --id=ToyPkg-ci eval '"session alive"' 2>&8)
checkout "session survived stop" "session alive" "$out"
kill -9 $SESSPID >/dev/null 2>&1
SESSPID=""

# ---- timeout escalation (non-yielding eval) ----

$J --timeout=2 eval 'Libc.systemsleep(600)' >/dev/null 2>"$WORK/esc.err" &
EPID=$!
for i in $(seq 1 60); do kill -0 $EPID 2>/dev/null || break; sleep 0.5; done
if kill -0 $EPID 2>/dev/null; then
    kill -9 $EPID
    check "timeout escalation exits" 124 999
else
    wait $EPID
    check "timeout escalation exits" 124 $?
fi
checkout "escalation killed the daemon" "killed the daemon" "$(cat "$WORK/esc.err")"
out=$($J eval '"fresh daemon"' 2>&8)
check "autostart after escalation" 0 $?
checkout "fresh daemon answers" "fresh daemon" "$out"

# ---- interrupt --force ----

$J eval 'Libc.systemsleep(600)' >/dev/null 2>&1 &
FPID=$!
wait_busy
$J interrupt --force >/dev/null 2>&8
wait $FPID
check "force-killed eval client notices" 3 $?
out=$($J --no-autostart eval '"forced restart"' 2>&8)
check "interrupt --force restarted the daemon" 0 $?
checkout "restarted daemon answers" "forced restart" "$out"

# ---- --idle-timeout ----

$JLD --project="$WORK/ToyPkg" --name=idle --no-revise --idle-timeout=3 start >/dev/null 2>&8
out=$($JLD --project="$WORK/ToyPkg" --name=idle eval '"idle up"' 2>&8)
checkout "idle-timeout daemon works" "idle up" "$out"
st=""
for i in $(seq 1 45); do
    st=$($JLD --project="$WORK/ToyPkg" --name=idle status 2>&8)
    [[ "$st" == *"not running"* ]] && break
    sleep 1
done
checkout "idle-timeout stops the daemon" "not running" "$st"

# ---- gc / shutdown ----

$JLD --project="$WORK/ToyPkg" --name=iso kill >/dev/null 2>&1
sleep 0.5
out=$($JLD --project="$WORK/ToyPkg" list 2>&8)
if [[ "$out" == *"ToyPkg-iso"* ]]; then
    check "list hides dead daemons" 0 1
else
    check "list hides dead daemons" 0 0
fi
out=$($JLD --project="$WORK/ToyPkg" list --all 2>&8)
checkout "list --all shows dead daemons" "ToyPkg-iso" "$out"
out=$($JLD --project="$WORK/ToyPkg" gc 2>&1)
checkout "gc removes dead daemons" "removed" "$out"
out=$($J eval '"still here"' 2>&8)
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
        tail -30 "$d/daemon.log" 2>&8
    done
    exit 1
fi
