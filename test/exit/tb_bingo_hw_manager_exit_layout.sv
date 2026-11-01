`define TB_STIMULUS_FILE "tb_stimulus_exit_absorb.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_DISABLE_CORE_WORKERS 1
module tb_bingo_hw_manager_exit_layout;
    localparam int ExitCase = 6;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
