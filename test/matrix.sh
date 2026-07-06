#!/usr/bin/env bash
# Run the e2e suite for every daemon julia x client julia combination.
# Usage: test/matrix.sh <julia-bin>... (default: julia from PATH)
set -u
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
VERSIONS=("$@")
[ ${#VERSIONS[@]} -eq 0 ] && VERSIONS=(julia)
fail=0
for daemon in "${VERSIONS[@]}"; do
    for client in "${VERSIONS[@]}"; do
        dv=$("$daemon" --version 2>/dev/null | awk '{print $3}')
        cv=$("$client" --version 2>/dev/null | awk '{print $3}')
        echo "=== daemon $dv / client $cv ==="
        out=$(JLD_JULIA="$daemon" JLD_CLIENT_JULIA="$client" "$HERE/e2e.sh" 2>&1)
        if [ $? -eq 0 ]; then
            echo "$out" | tail -1
        else
            echo "$out"
            fail=1
        fi
    done
done
exit $fail
