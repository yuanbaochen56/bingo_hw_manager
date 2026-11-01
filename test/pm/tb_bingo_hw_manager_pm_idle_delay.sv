// Control plane: with an idle entry delay a power domain only drops to the idle level after its cores were idle
// that long; short gaps between tasks keep the normal level
`define TB_STIMULUS_FILE "tb_stimulus_pm_idle_delay.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 2000
`define TB_DISABLE_CORE_WORKERS 1
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_PM_ENABLE 1
`define TB_PM_IDLE_DELAY 500

module tb_bingo_hw_manager_pm_idle_delay;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
