// Fault-aware power management: a fenced (dead) core no longer keeps its power domain at the normal level, and no
// longer counts as load
`define TB_STIMULUS_FILE "tb_stimulus_pm_fault_aware.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
// distinct types: the dead core has no substitute
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_PM_ENABLE 1

module tb_bingo_hw_manager_pm_fault_aware;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
