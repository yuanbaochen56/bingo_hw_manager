// =============================================================================
// Bingo HW Manager Top Testbench — Default 27-task multi-chiplet test
// =============================================================================
`define TB_STIMULUS_FILE "tb_stimulus_default.svh"
`define TB_NUM_CHIPLET 4
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_top;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
