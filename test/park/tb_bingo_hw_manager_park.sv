// Core parking: an in-flight task finishes on its own core; later tasks of that
// logical core run on the substitute, in order.
`define TB_STIMULUS_FILE "tb_stimulus_park.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_park;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
