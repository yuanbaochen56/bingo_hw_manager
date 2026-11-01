// Control plane: with SubstitutePolicy 1 a dead core's tasks go to the least loaded live core of its type, not the
// lowest one
`define TB_STIMULUS_FILE "tb_stimulus_substitute_least_loaded.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 4
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
`define TB_SUBSTITUTE_POLICY 1

module tb_bingo_hw_manager_substitute_least_loaded;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
