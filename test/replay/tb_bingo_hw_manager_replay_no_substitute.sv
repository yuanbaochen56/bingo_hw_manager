// Replay: with no allowed substitute the dead core's tasks stay put and the rest keeps running
`define TB_STIMULUS_FILE "tb_stimulus_replay_no_substitute.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
// HeMAiA-like types: core0 accelerator, core1 DM, core2 host (no two alike)
`define TB_CORE_TYPE_ID {4'd0, 4'd2, 4'd1}

module tb_bingo_hw_manager_replay_no_substitute;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
