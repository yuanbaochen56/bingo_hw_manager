// Four clusters: three DM cores die one after the other, the last one runs every DM task; the event log names all twelve slots
`define TB_STIMULUS_FILE "tb_stimulus_4cl_dm_chain.svh"
`define TB_4CL_DM_FAULTS 3
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 4
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
// cluster c, core 1 (DM) is flat core 3 * c + 1
`define TB_FAULT_CORE 7
`define TB_FAULT_TASK_ID 21
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 1
`define TB_FAULT2_TASK_ID 22
`define TB_FAULT3_CORE 4
`define TB_FAULT3_TASK_ID 23
`define TB_EVLOG_DEPTH 64
// core 0 type 1 (GEMM), core 1 type 2 (DM), core 2 type 0 (host / empty), in every cluster
`define TB_CORE_TYPE_ID {4'd0, 4'd0, 4'd0, 4'd0, 4'd2, 4'd2, 4'd2, 4'd2, 4'd1, 4'd1, 4'd1, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011
`define TB_SUBSTITUTE_L2_TYPE_EN 16'hfffd

module tb_bingo_hw_manager_4cl_dm_three;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
