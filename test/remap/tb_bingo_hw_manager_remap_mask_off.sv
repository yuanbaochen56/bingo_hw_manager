`define TB_STIMULUS_FILE "tb_stimulus_remap_mask_off.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 32
// HeMAiA-like types: core0 accelerator, core1 DM, core2 host (no two alike)
`define TB_CORE_TYPE_ID {4'd0, 4'd2, 4'd1}
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_remap_mask_off;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
