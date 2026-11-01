`define TB_STIMULUS_FILE "tb_stimulus_pm_access_level.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_DISABLE_CORE_WORKERS 1
`define TB_PM_ENABLE 1
`define TB_PM_CLUSTER_DOMAINS 1
`define TB_PM_ACCESS_HOLD 300
module tb_bingo_hw_manager_pm_access_level;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
