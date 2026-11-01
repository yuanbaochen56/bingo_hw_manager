// Level 3: a remote done whose task id is not the exported head's stops the
// proxy slot (sticky remote_done_mismatch_o) instead of retiring the wrong task
`define TB_STIMULUS_FILE "tb_stimulus_remote_done_mismatch.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE -1
`define TB_FAULT2_TASK_ID 0
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b111
`define TB_REMOTE_LINK 1
`define TB_ALLOW_DONE_MISMATCH 1

module tb_bingo_hw_manager_remote_done_mismatch;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
