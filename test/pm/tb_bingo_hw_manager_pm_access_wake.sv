// Control plane: an external access into a cluster (e.g. the host reading its
// L1) keeps that cluster's power domain at the normal level for a host-set hold
// time after the last access, fenced slots included
`define TB_STIMULUS_FILE "tb_stimulus_pm_access_wake.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
// core k: type k + 1 in both clusters
`define TB_CORE_TYPE_ID {4'd3, 4'd3, 4'd2, 4'd2, 4'd1, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011
`define TB_PM_ENABLE 1
`define TB_PM_CLUSTER_DOMAINS 1
`define TB_PM_ACCESS_HOLD 300
`define TB_PM_IDLE_DELAY 0

module tb_bingo_hw_manager_pm_access_wake;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
