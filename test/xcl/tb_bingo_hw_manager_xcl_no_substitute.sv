// Level 2: no same-type core anywhere in the chiplet: stuck, the other cores keep running
`define TB_STIMULUS_FILE "tb_stimulus_xcl_no_substitute.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE -1
`define TB_FAULT2_TASK_ID 0
// Core 0 of cluster 0: type 4 (unique in the chiplet), all other cores type 1
`define TB_CORE_TYPE_ID {4'd1, 4'd1, 4'd1, 4'd1, 4'd1, 4'd4}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011

module tb_bingo_hw_manager_xcl_no_substitute;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
