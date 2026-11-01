#!/bin/bash
# One-shot local simulation on the ESAT servers: load Questa, (re)generate
# compile.tcl via the HeMAiA container if needed, compile, run tests.
#
# Usage: scripts/sim.sh [--regen] <test> [<test> ...]
#   <test> may be given as heartbeat, bingo_hw_manager_heartbeat or
#   tb_bingo_hw_manager_heartbeat.
#   --regen  force regeneration of build/compile.tcl (e.g. after adding files)
#
# Logs: build/vlog.log (compile), build/sim_<test>.log (per test)

set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
QUESTA_RC=~micasusr/design/scripts/questasim_2025.2.rc
HEMAIA_IMAGE=ghcr.io/kuleuven-micas/hemaia:main

regen=0
tests=()
for arg in "$@"; do
    case "$arg" in
        --regen) regen=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) tests+=("$arg") ;;
    esac
done
if [ ${#tests[@]} -eq 0 ]; then
    sed -n '2,10p' "$0"
    exit 1
fi

# Resolve short names to the tb name without the tb_ prefix. Every tb lives in
# one subfolder of test/ (watchdog/, replay/, ..., generated/).
tb_exists() { compgen -G "$ROOT/test/*/tb_$1.sv" > /dev/null; }
names=()
for t in "${tests[@]}"; do
    t="${t#tb_}"
    t="${t%.sv}"
    if tb_exists "$t"; then
        names+=("$t")
    elif tb_exists "bingo_hw_manager_$t"; then
        names+=("bingo_hw_manager_$t")
    else
        echo "Testbench for '$t' not found in test/" >&2
        exit 1
    fi
done

command -v vsim >/dev/null || source "$QUESTA_RC"
export MTI_VCO_MODE=64

mkdir -p "$ROOT/build"
cd "$ROOT/build" || exit 1

# Step 1: compile.tcl only needs regenerating when the file list changes
if [ $regen -eq 1 ] || [ ! -f compile.tcl ] || [ "$ROOT/Bender.yml" -nt compile.tcl ]; then
    echo "==> Generating compile.tcl (podman)"
    podman run --rm -v "$ROOT:$ROOT" -w "$ROOT/build" "$HEMAIA_IMAGE" \
        bash -lc 'VSIM=true ../scripts/compile_vsim.sh' || exit 1
fi

# Step 2: compile (every edit to .sv/.svh, including stimulus files)
echo "==> Compiling"
if ! vsim -c -do 'exit -code [source compile.tcl]' > vlog.log 2>&1; then
    grep -n "Error" vlog.log | head -20
    echo "COMPILE FAILED, see build/vlog.log"
    exit 1
fi

# Step 3: run tests, same pass criteria as the Makefile's sim-%.log rule
fail=0
for t in "${names[@]}"; do
    log="sim_$t.log"
    echo "==> Running $t"
    rm -f vsim.log
    "$ROOT/scripts/run_vsim.sh" "$t" 2>&1
    [ -f vsim.log ] && mv vsim.log "$log" || echo "run_vsim.sh produced no log" > "$log"
    if grep -q "Errors: 0," "$log" && ! grep -q "Error:" "$log" && ! grep -q "Fatal:" "$log"; then
        echo "    PASS  $(grep -m1 -i "passed" "$log" | sed 's/^# //')"
    else
        echo "    FAIL  see build/$log"
        grep -n "Error:\|Fatal:" "$log" | head -5 | sed 's/^/    /'
        fail=1
    fi
done
exit $fail
