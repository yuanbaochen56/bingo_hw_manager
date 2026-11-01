#!/bin/bash
set -e

[ ! -z "$VSIM" ] || VSIM=vsim

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Step 1: Bender compiles RTL sources + hand-written tests
bender script vsim -t test -t rtl \
    --vlog-arg="-svinputport=compat" \
    --vlog-arg="-override_timescale 1ns/1ps" \
    --vlog-arg="-suppress 2583" \
    --vlog-arg="+incdir+${ROOT}/test" \
    --vlog-arg="+incdir+${ROOT}/test/generated" \
    > compile.tcl

# Step 2: Append generated testbenches (glob — no manual Bender.yml listing needed).
# Uses -incr so vlog sees the work library from Step 1 (packages, types).
# Include paths: test/common/ (the harness), test/generated/, axi, common_cells.
GEN_FILES=$(find "${ROOT}/test/generated" -name 'tb_bingo_hw_manager_*.sv' 2>/dev/null | sort)
if [ -n "$GEN_FILES" ]; then
    AXI_INC=$(find "${ROOT}/.bender" -path '*/axi-*/include' -type d 2>/dev/null | head -1)
    CC_INC=$(find "${ROOT}/.bender" -path '*/common_cells-*/include' -type d 2>/dev/null | head -1)

    cat >> compile.tcl << GENEOF

# --- Auto-generated testbenches (from test/generated/) ---
vlog -incr -sv \\
    -svinputport=compat \\
    -override_timescale 1ns/1ps \\
    -suppress 2583 \\
    "+incdir+${AXI_INC}" \\
    "+incdir+${CC_INC}" \\
    +incdir+${ROOT}/test/common \\
    +incdir+${ROOT}/test/generated \\
GENEOF

    for f in $GEN_FILES; do
        echo "    $f \\" >> compile.tcl
    done
    echo "" >> compile.tcl
fi

echo 'return 0' >> compile.tcl

$VSIM -c -do 'exit -code [source compile.tcl]'
