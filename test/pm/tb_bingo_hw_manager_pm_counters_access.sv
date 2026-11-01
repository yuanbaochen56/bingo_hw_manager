// Power-domain counters with the external access servo stimulus (two
// cluster domains; the servo level 12 and the derate level 18 count as other
// levels), against a model of their definition every cycle
`define TB_STIMULUS_FILE "tb_stimulus_pm_access_level.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_DISABLE_CORE_WORKERS 1
`define TB_PM_ENABLE 1
`define TB_PM_CLUSTER_DOMAINS 1
`define TB_PM_ACCESS_HOLD 300
module tb_bingo_hw_manager_pm_counters_access;
  `include "tb_bingo_hw_manager_harness.svh"
  // domain 1: idle, normal, other and active; domain 2 (its cores poll throughout): idle
  localparam bit pmc_expect_nonzero [2][5] = '{'{1, 1, 0, 1, 1}, '{1, 0, 0, 0, 0}};
  `include "tb_pm_counters_check.svh"
endmodule
