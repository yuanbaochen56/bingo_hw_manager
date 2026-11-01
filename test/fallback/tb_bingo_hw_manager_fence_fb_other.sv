// Fence fallback: only other types are set: the type-1 victim is replayed on
// its level-2 substitute
`define TB_STIMULUS_FILE "tb_stimulus_fence_fb.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 2
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_SUBSTITUTE_L2_TYPE_EN 16'hffff
// Cluster 0: core 0 type 1, cores 1-2 type 2.
// Cluster 1: core 0 type 2, core 1 type 1, core 2 type 3.
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1, 4'd2, 4'd2, 4'd1}
`define TB_FAULT_CORE 0
`define TB_SUBSTITUTE_LEVEL_MASK 3'b011
`define TB_FENCE_FB 16'hfffd
`define FB_VICTIM_TYPE 1
`define FB_SUB_CORE 1
`define FB_EXPECT_STUCK 0

module tb_bingo_hw_manager_fence_fb_other;
    `include "tb_bingo_hw_manager_harness.svh"
endmodule
