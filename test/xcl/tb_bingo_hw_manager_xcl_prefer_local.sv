// Level 2: a same-type core of the dead core's own cluster wins over lower-indexed ones elsewhere
`define TB_STIMULUS_FILE "tb_stimulus_xcl_prefer_local.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 3
`define TB_FAULT_TASK_ID 11
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE -1
`define TB_FAULT2_TASK_ID 0
// All cores type 1 (default)
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011

module tb_bingo_hw_manager_xcl_prefer_local;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
