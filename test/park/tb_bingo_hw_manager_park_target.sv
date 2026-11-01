// Core parking: a core in HOLD that becomes the substitute of a fenced core gives up the
// park; it cannot be parked while it runs that core's tasks
`define TB_STIMULUS_FILE "tb_stimulus_park_target.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_DISABLE_CORE_WORKERS 1
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800

module tb_bingo_hw_manager_park_target;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
