// DARTS Tier 1: CERF skip test — conditional task skipped, deps propagated
`define TB_STIMULUS_FILE "tb_stimulus_cerf_skip.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_cerf_skip;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
