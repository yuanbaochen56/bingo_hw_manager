`define TB_STIMULUS_FILE "tb_stimulus_remap_dummy_after_remap.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 32
`define TB_DISABLE_CORE_WORKERS 1
`define TB_WATCHDOG_CONFIRM_TIMEOUT 128

module tb_bingo_hw_manager_remap_dummy_after_remap;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
