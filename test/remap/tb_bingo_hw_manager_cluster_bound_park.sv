`define TB_STIMULUS_FILE "tb_stimulus_park_no_substitute.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_DISABLE_CORE_WORKERS 1
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011
`define TB_SUBSTITUTE_L2_TYPE_EN 16'hfffd
`define TB_CORE_TYPE_ID {4'd2, 4'd2, 4'd1, 4'd1}

module tb_bingo_hw_manager_cluster_bound_park;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
