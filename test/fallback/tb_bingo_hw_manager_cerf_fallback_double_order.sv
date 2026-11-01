// A type with a substitute: both cores die, but the dead core's task at the
// stuck substitute's head is still needed by the CERF: it stays, nothing passes it.
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
`define TB_CERF_DOUBLE_T1_UNGATED 1


module tb_bingo_hw_manager_cerf_fallback_double_order;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
