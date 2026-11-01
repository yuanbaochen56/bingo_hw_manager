// Random task graph with a random fault (as replay_random), and the host
// parking and moving back random cores (never the faulty one) all along
`define TB_STIMULUS_FILE "tb_stimulus_replay_random.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 4
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_SLOW_CYCLES 450
`define TB_RANDOM_PARK 1

module tb_bingo_hw_manager_park_random;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
