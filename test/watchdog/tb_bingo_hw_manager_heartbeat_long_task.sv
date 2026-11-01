`define TB_STIMULUS_FILE "tb_stimulus_heartbeat_long_task.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 8
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_heartbeat_long_task;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule