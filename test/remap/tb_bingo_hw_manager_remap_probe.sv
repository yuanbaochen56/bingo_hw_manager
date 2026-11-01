`define TB_STIMULUS_FILE "tb_stimulus_remap_probe.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 64
`define TB_DISABLE_CORE_WORKERS 1
`define TB_WATCHDOG_CONFIRM_TIMEOUT 256

module tb_bingo_hw_manager_remap_probe;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
