// Real transport, one chiplet: remote_link loops back to its own chiplet
// (force remote: SubstituteLevelMask 3'b100, imports may use level 1)
`define TB_STIMULUS_FILE "tb_stimulus_rlink_loopback.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE -1
`define TB_FAULT2_TASK_ID 0
// core 0 type 1, core 1 type 1, core 2 type 2
`define TB_CORE_TYPE_ID {4'd2, 4'd1, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b100
`define TB_IMPORT_SUBSTITUTE_LEVEL_MASK 3'b001
`define TB_REMOTE_LINK 2

module tb_bingo_hw_manager_rlink_loopback;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
