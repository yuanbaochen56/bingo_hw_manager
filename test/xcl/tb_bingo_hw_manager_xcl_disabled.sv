// Level 2 off (default mask): no cross-cluster substitute, the dead core is stuck
`define TB_STIMULUS_FILE "tb_stimulus_xcl_disabled.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE -1
`define TB_FAULT2_TASK_ID 0
// Same types as xcl_fallback: the only other type-1 core sits in cluster 1
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1, 4'd2, 4'd2, 4'd1}

module tb_bingo_hw_manager_xcl_disabled;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
