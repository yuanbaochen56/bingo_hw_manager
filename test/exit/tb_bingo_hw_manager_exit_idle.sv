// Real exits stop polling. Both boost policies and PM must treat them as idle.
`define TB_STIMULUS_FILE "tb_stimulus_exit_idle.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
`define TB_PM_ENABLE 1
`define TB_PM_BOOST_LEVEL 3
`define TB_PM_IDLE_DELAY 40
`define TB_PM_CLUSTER_DOMAINS 1
`define TB_CORE_TYPE_ID {4'd2, 4'd2, 4'd1, 4'd1, 4'd1, 4'd1}

module tb_bingo_hw_manager_exit_idle;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
