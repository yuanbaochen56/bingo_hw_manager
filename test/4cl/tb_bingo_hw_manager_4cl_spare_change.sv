// Four clusters, cluster 3 a spare, then cluster 1: a fenced cluster keeps the substitute it got, a later fence takes the new spare
`define TB_STIMULUS_FILE "tb_stimulus_4cl_dm_sub.svh"
`define TB_4CL_SUB_CASE 2
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 4
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
// cluster c, core 1 (DM) is flat core 3 * c + 1
`define TB_FAULT_CORE 7
`define TB_FAULT_TASK_ID 21
`define TB_FAULT_MODE 0
`define TB_FAULT3_CORE 1
`define TB_FAULT3_TASK_ID 2
`define TB_SUB_SPARE 32'h8

// core 0 type 1 (GEMM), core 1 type 2 (DM), core 2 type 0 (host / empty), in every cluster
`define TB_CORE_TYPE_ID {4'd0, 4'd0, 4'd0, 4'd0, 4'd2, 4'd2, 4'd2, 4'd2, 4'd1, 4'd1, 4'd1, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011
`define TB_SUBSTITUTE_L2_TYPE_EN 16'hfffd

module tb_bingo_hw_manager_4cl_spare_change;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
