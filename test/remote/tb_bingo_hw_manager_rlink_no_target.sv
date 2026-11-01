// Real transport (remote_link + AXI-Lite xbar, random stalls). Level 3: a dead core whose type has no export target is stuck,
// and the export of another type still goes through
`define TB_STIMULUS_FILE "tb_stimulus_rlink_no_target.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 1
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 0
`define TB_FAULT2_TASK_ID 3
// Both chiplets: core 0 type 1, core 1 type 2, core 2 type 3 (no local substitute)
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b111
`define TB_REMOTE_LINK 2
// Only type 1 has an export target
`define TB_REMOTE_TARGET_TYPES 16'h0002

module tb_bingo_hw_manager_rlink_no_target;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
