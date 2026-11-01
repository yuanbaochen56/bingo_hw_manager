// Control plane: the watchdog counts cycles of the normal clock, so a core whose power domain is stuck at the slow
// idle level is not suspected for heartbeat gaps that are fine at its real speed
`define TB_STIMULUS_FILE "tb_stimulus_pm_slow_watchdog.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 0
`define TB_DISABLE_CORE_WORKERS 1
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_PM_ENABLE 1

module tb_bingo_hw_manager_pm_slow_watchdog;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
