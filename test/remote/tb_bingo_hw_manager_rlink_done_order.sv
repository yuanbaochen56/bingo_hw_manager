// Real transport: two dead cores of chiplet 0 export in parallel; the dones of
// each proxy slot come back in export order through the stalled link
`define TB_STIMULUS_FILE "tb_stimulus_rlink_done_order.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 1
`define TB_FAULT2_TASK_ID 11
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b111
`define TB_REMOTE_LINK 2
// enough credits for all 12 exports
`define TB_REMOTE_CREDITS 8

module tb_bingo_hw_manager_rlink_done_order;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
