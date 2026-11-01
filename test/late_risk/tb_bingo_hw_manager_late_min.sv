`define TB_STIMULUS_FILE "tb_stimulus_late_manager.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 500
`define TB_WATCHDOG_CONFIRM_TIMEOUT 2000
`define TB_DISABLE_CORE_WORKERS 1
`define TB_LATE_CASE 1
module tb_bingo_hw_manager_late_min;
    `include "tb_bingo_hw_manager_late_harness.svh"
endmodule
`undef TB_LATE_CASE
