`define TB_STIMULUS_FILE "tb_stimulus_no_replay.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE -1
`define TB_SUBSTITUTE_LEVEL_MASK 3'b100
module tb_bingo_hw_manager_replay_no_replay_l3;
    localparam int NR_CASE = 4;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
