// Level 3 over the real transport: random task graphs on two chiplets and a random hang on each; when both
// dead cores share a type the exports are rejected (run with several seeds: scripts/run_replay_random.sh N 1 rlink_random_reject)
`define TB_STIMULUS_FILE "tb_stimulus_rlink_random.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b111
`define TB_REMOTE_LINK 2
`define TB_RR_TWO_FAULTS

module tb_bingo_hw_manager_rlink_random_reject;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
