// Control plane: while a core runs a dead core's tasks, its power domain runs at the boost level
`define TB_STIMULUS_FILE "tb_stimulus_pm_recovery_boost.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
`define TB_PM_ENABLE 1
`define TB_PM_BOOST_LEVEL 3

module tb_bingo_hw_manager_pm_recovery_boost;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
