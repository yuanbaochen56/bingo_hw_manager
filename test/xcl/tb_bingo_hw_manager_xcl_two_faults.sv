// Level 2: two dead cores in different clusters, each replayed in the other cluster
`define TB_STIMULUS_FILE "tb_stimulus_xcl_two_faults.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 4
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 4
`define TB_FAULT2_TASK_ID 21
// Cluster 0: core 0 type 1, core 1 type 2, cores 2-3 type 3
// Cluster 1: core 0 type 2, cores 1-2 type 1, core 3 type 3
`define TB_CORE_TYPE_ID {4'd3, 4'd3, 4'd1, 4'd3, 4'd1, 4'd2, 4'd2, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011

module tb_bingo_hw_manager_xcl_two_faults;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
