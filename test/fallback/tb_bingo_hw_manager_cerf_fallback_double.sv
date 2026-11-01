// A type with a substitute: both of its cores die, the second while it runs the
// first one's tasks. The stuck substitute drains the dead core's skipped heads.
`define TB_STIMULUS_FILE "tb_stimulus_cerf_fallback_double.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 1
`define TB_FAULT2_TASK_ID 1
// cores 0 and 1 type 4 (each other's substitute), core 2 type 1
`define TB_CORE_TYPE_ID {4'd1, 4'd4, 4'd4}


module tb_bingo_hw_manager_cerf_fallback_double;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
