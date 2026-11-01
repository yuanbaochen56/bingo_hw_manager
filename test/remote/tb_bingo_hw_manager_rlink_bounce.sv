// Real transport (remote_link + AXI-Lite xbar, random stalls). Level 3: the core that runs the imported tasks dies, and
// they go back to their origin as rejects (bounce)
`define TB_STIMULUS_FILE "tb_stimulus_rlink_bounce.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
// chiplet 1, core 0 hangs on the imported task 1
`define TB_FAULT2_CORE 3
`define TB_FAULT2_TASK_ID 1
// Both chiplets: core 0 type 1, core 1 type 2, core 2 type 3 (no local substitute)
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b111
`define TB_REMOTE_LINK 2

module tb_bingo_hw_manager_rlink_bounce;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
