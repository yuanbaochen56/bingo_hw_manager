// Replay: a dead core in cluster 1 is replayed inside cluster 1
`define TB_STIMULUS_FILE "tb_stimulus_replay_two_clusters.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 3
`define TB_FAULT_TASK_ID 11
`define TB_FAULT_MODE 0

module tb_bingo_hw_manager_replay_two_clusters;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
