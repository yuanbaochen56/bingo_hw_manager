// =============================================================================
// Bingo HW Manager Multi-Cluster Tagged Testbench
// =============================================================================
// Same harness as tb_bingo_hw_manager_top, but with TWO clusters, driving a
// CROSS-cluster column-aliasing stimulus: two producers on the same bare core
// (core1) -- one local to cluster 0, one cross-cluster from cluster 1 -- both
// set cluster-0's cell[0][1] but with distinct tags, and two consumers each
// drain their own tag. Proves the multi-cluster tagged datapath
// (SET arbiter -> cluster demux -> matrix, with the tag intact) disambiguates
// the bare-core column.
// =============================================================================
`define TB_STIMULUS_FILE "tb_stimulus_tagged_mc.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_tagged_mc;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
