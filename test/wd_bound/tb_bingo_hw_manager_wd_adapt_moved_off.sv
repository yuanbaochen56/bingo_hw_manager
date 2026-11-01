// Executions away from their own logical slot: the moved flag through replay and
// remap, and BINGO_WD_LATE[6], [8:7] at the top (both clear: learned as before).
`define TB_STIMULUS_FILE "tb_stimulus_wd_adapt_moved.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
`define TB_WD_ADAPT_MOVED_OFF 1
module tb_bingo_hw_manager_wd_adapt_moved_off;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
