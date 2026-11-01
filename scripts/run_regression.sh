#!/bin/bash
# Full regression: every testbench of the Bender `test` target through
# scripts/sim.sh (one compile), then the random replay test with N seeds and
# the random level-3 transport tests (one fault / a fault on each chiplet)
# with N/4 seeds each, and the random test with core parking with N/2 seeds.
# Usage: scripts/run_regression.sh [N_RANDOM_SEEDS] [TAG]
#   Logs: build/regress_<TAG>.log and build/random_<TAG>.out
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
N=${1:-40}
TAG=${2:-latest}
cd "$ROOT" || exit 1
# Directed tests in Bender.yml order; the random test runs separately with seeds.
tests=$(sed -n 's/^ *- test\/[a-z0-9_]*\/tb_\(bingo_hw_manager_[a-z0-9_]*\)\.sv.*/\1/p' Bender.yml |
        grep -v '^bingo_hw_manager_replay_random$\|^bingo_hw_manager_rlink_random$\|^bingo_hw_manager_rlink_random_reject$\|^bingo_hw_manager_park_random$')
scripts/sim.sh $tests > "build/regress_$TAG.log" 2>&1
sim_rc=$?
# A4 symmetric controls use the same compiled fixture and seed.
command -v vsim >/dev/null || source ~micasusr/design/scripts/questasim_2025.2.rc
for case in normal_zero replay_zero queued_blocked cerf_disabled; do
    case "$case" in
        normal_zero) tb=no_replay_normal; flag=+NR_TASK_TYPE=0 ;;
        replay_zero) tb=replay_no_replay; flag=+NR_TASK_TYPE=0 ;;
        queued_blocked) tb=replay_no_replay_queued; flag=+NR_FIRST_MARKED=1 ;;
        cerf_disabled) tb=replay_no_replay_cerf; flag=+NR_CERF=0 ;;
    esac
    log="build/no_replay_${case}_${TAG}.log"
    (cd build && vsim -c -sv_seed 0 "tb_bingo_hw_manager_$tb" "$flag" -t 1ns \
        -voptargs=+acc -do "run -all; quit -f") > "$log" 2>&1
    if grep -q "No replay case .* passed" "$log" &&
       grep -q "Errors: 0," "$log" && ! grep -q "Error:\|Fatal:" "$log"; then
        echo "    PASS  A4 $case" >> "build/regress_$TAG.log"
    else
        echo "    FAIL  A4 $case (see $log)" >> "build/regress_$TAG.log"
        sim_rc=1
    fi
done
npass=$(grep -c '^    PASS' "build/regress_$TAG.log")
nfail=$(grep -c '^    FAIL' "build/regress_$TAG.log")
echo "directed: $npass PASS, $nfail FAIL (build/regress_$TAG.log)"
grep '^    FAIL' -B1 "build/regress_$TAG.log" | grep '^==>' || true
rnd_rc=0
if [ "$N" -gt 0 ]; then
    scripts/run_replay_random.sh "$N" > "build/random_$TAG.out" 2>&1
    rnd_rc=$?
    echo "random: $(grep -c ' PASS' "build/random_$TAG.out") / $N PASS (build/random_$TAG.out)"
    N3=$(( (N + 3) / 4 ))
    scripts/run_replay_random.sh "$N3" 1 rlink_random > "build/random_l3_$TAG.out" 2>&1 || rnd_rc=1
    echo "random L3: $(grep -c ' PASS' "build/random_l3_$TAG.out") / $N3 PASS (build/random_l3_$TAG.out)"
    scripts/run_replay_random.sh "$N3" 1 rlink_random_reject > "build/random_l3rej_$TAG.out" 2>&1 || rnd_rc=1
    echo "random L3 two faults: $(grep -c ' PASS' "build/random_l3rej_$TAG.out") / $N3 PASS (build/random_l3rej_$TAG.out)"
    N2=$(( (N + 1) / 2 ))
    scripts/run_replay_random.sh "$N2" 1 park_random > "build/random_park_$TAG.out" 2>&1 || rnd_rc=1
    echo "random park: $(grep -c ' PASS' "build/random_park_$TAG.out") / $N2 PASS (build/random_park_$TAG.out)"
fi
[ $sim_rc -eq 0 ] && [ $rnd_rc -eq 0 ]
