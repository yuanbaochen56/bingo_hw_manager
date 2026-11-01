`define TB_STIMULUS_FILE "tb_stimulus_exit_absorb.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_DISABLE_CORE_WORKERS 1
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_SUBSTITUTE_LEVEL_MASK 3'b111
`define TB_CORE_TYPE_ID {4'd2, 4'd2, 4'd2, 4'd2, 4'd2, 4'd1}
module tb_bingo_hw_manager_exit_l3;
    localparam int ExitCase = 5;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
