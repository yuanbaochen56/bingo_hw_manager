`define TB_STIMULUS_FILE "tb_stimulus_watchdog_risk_confirm.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 20
`define TB_WATCHDOG_CONFIRM_TIMEOUT 80
`define TB_DISABLE_CORE_WORKERS 1
module tb_bingo_hw_manager_watchdog_risk_confirm;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
