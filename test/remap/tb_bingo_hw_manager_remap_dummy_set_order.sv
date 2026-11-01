`define TB_STIMULUS_FILE "tb_stimulus_remap_dummy_set_order.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_remap_dummy_set_order;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
