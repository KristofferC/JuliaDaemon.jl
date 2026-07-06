#!/usr/bin/env bash
# End-to-end test for jld. Requires a working `julia` on PATH (or JLD_JULIA).
set -uo pipefail

JLD_HOME="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
JLD="$JLD_HOME/bin/jld"
WORK="$(mktemp -d)"
NAME="e2e$$"
FAILS=0

check() { # check <desc> <expected-exit> <actual-exit>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected exit $2, got $3)"; FAILS=$((FAILS+1)); fi
}
checkout() { # checkout <desc> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then echo "ok: $1"; else echo "FAIL: $1 (missing: $2)"; echo "$3"; FAILS=$((FAILS+1)); fi
}

cleanup() {
    "$JLD" --project="$WORK/ToyPkg" --name=$NAME kill >/dev/null 2>&1
    rm -rf "$WORK" "${XDG_CACHE_HOME:-$HOME/.cache}"/julia-daemon/ToyPkg-$NAME-*
}
trap cleanup EXIT

julia --startup-file=no -e "using Pkg; Pkg.generate(\"$WORK/ToyPkg\")" >/dev/null 2>&1
cd "$WORK/ToyPkg"
J="$JLD --name=$NAME"

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

$J --timeout=2 eval 'sleep(60)' >/dev/null 2>&1
check "timeout interrupt" 124 $?

out=$($J eval '1 + 2' 2>/dev/null)
check "daemon survived interrupt" 0 $?
checkout "daemon state intact" "3" "$out"

echo 'scratch_result = sum(1:10)' > "$WORK/scratch.jl"
out=$($J run "$WORK/scratch.jl" 2>/dev/null; $J eval 'scratch_result' 2>/dev/null)
checkout "run file + state persists" "55" "$out"

out=$($J transcript 2>/dev/null)
checkout "transcript records inputs" "scratch_result = sum(1:10)" "$out"
checkout "transcript records outputs" "Hello World!" "$out"

out=$($J --module=Wk eval 'wk_x = 7; wk_x' 2>/dev/null; $J eval 'Main.Wk.wk_x * 2, isdefined(Main, :wk_x)' 2>/dev/null)
checkout "module workspace" "(14, false)" "$out"

out=$($J eval 'sc_ref = 5;' 2>/dev/null; $J eval-scratch 'sc_tmp = sc_ref * 3' 2>/dev/null; $J eval 'isdefined(Main, :sc_tmp)' 2>/dev/null)
checkout "eval-scratch sees Main, keeps nothing" "15
false" "$out"

out=$($J stacks 2>/dev/null)
check "stacks" 0 $?
checkout "stacks reports threads" "Thread" "$out"

$J stop >/dev/null 2>&1
$J --no-autostart eval '1' >/dev/null 2>&1
check "stopped daemon unreachable" 3 $?

echo
if [ $FAILS -eq 0 ]; then echo "PASS (all checks)"; else echo "FAIL ($FAILS checks)"; exit 1; fi
