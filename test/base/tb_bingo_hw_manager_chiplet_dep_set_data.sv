// Chiplet dep-set write: the data is the whole descriptor of the setting task,
// with no unknown bit
`define TB_STIMULUS_FILE "tb_stimulus_chiplet_dep_set_data.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_chiplet_dep_set_data;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
