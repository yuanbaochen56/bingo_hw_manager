// Level 3 over the real transport with two peers: a peer that holds its
// imports (no credits left) does not block the exports to the other peer
`define TB_STIMULUS_FILE "tb_stimulus_rlink_hol.svh"
`define TB_NUM_CHIPLET 3
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
`define TB_REMOTE_STALL 0
// type 2 goes to the predecessor (chiplet 0 -> chiplet 2), the others to the successor
`define TB_REMOTE_PRED_TYPES 16'h0004

module tb_bingo_hw_manager_rlink_hol;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
