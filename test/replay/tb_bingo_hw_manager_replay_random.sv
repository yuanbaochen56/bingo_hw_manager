// Replay: random task graph with a random fault (hang / zombie / slow) on a random task.
// Run with several seeds: scripts/run_replay_random.sh
`define TB_STIMULUS_FILE "tb_stimulus_replay_random.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 4
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_SLOW_CYCLES 450

module tb_bingo_hw_manager_replay_random;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
