// Two stuck core types degrade one after the other; clear == set sets the group.
`define TB_STIMULUS_FILE "tb_stimulus_cerf_fallback_multi.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 1
`define TB_FAULT2_TASK_ID 2
// core 2 type 1 (stays live), core 1 type 5, core 0 type 4 (both unique, both stuck)
`define TB_CORE_TYPE_ID {4'd1, 4'd5, 4'd4}

module tb_bingo_hw_manager_cerf_fallback_multi;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
