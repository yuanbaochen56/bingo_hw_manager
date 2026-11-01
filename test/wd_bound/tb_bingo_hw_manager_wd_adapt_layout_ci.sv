`define TB_STIMULUS_FILE "tb_stimulus_wd_adapt_layout.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_DISABLE_CORE_WORKERS 1
module tb_bingo_hw_manager_wd_adapt_layout_ci;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
