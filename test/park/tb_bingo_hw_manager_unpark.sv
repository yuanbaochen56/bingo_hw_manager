// Core parking: a parked core moves back once its tasks on the substitute retired; its
// new tasks wait, the substitute's own tasks do not
`define TB_STIMULUS_FILE "tb_stimulus_unpark.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_unpark;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
