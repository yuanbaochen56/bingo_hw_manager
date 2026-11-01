// Core parking: asking again during the move back keeps the core parked; with
// nothing left on the substitute the move back is immediate
`define TB_STIMULUS_FILE "tb_stimulus_unpark_cancel.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_unpark_cancel;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
