// Executions at a level faster than normal: the control plane's fast flag and
// BINGO_WD_LATE[6] at the top.
`define TB_STIMULUS_FILE "tb_stimulus_wd_adapt_fast.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
`define TB_PM_ENABLE 1
module tb_bingo_hw_manager_wd_adapt_fast;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
