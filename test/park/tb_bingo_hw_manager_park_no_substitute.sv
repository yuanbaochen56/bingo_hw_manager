// Core parking with no live core of the same type: the request fails and the
// tasks stay on the original core.
`define TB_STIMULUS_FILE "tb_stimulus_park_no_substitute.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_DISABLE_CORE_WORKERS 1
// core 1 type 2, core 0 type 1: parking core 0 has no substitute
`define TB_CORE_TYPE_ID {4'd2, 4'd1}

module tb_bingo_hw_manager_park_no_substitute;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
