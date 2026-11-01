// Power-domain counters with the recovery boost stimulus (a fence; the
// substitute's domain at the boost level, idle and normal otherwise), against
// a model of their definition every cycle
`define TB_STIMULUS_FILE "tb_stimulus_pm_recovery_boost.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
`define TB_PM_ENABLE 1
`define TB_PM_BOOST_LEVEL 3

module tb_bingo_hw_manager_pm_counters_boost;
  `include "tb_bingo_hw_manager_harness.svh"
  // idle, normal, boost and active must have counted in domain 1
  localparam bit pmc_expect_nonzero [1][5] = '{'{1, 1, 1, 0, 1}};
  `include "tb_pm_counters_check.svh"
endmodule
