// Replay: a fenced core without substitute does not block the replay of another fenced core
`define TB_STIMULUS_FILE "tb_stimulus_replay_stuck_other_core.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 4
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 1
`define TB_FAULT2_TASK_ID 3
// Core 0: type 1 (only one), cores 1 and 2: type 2, core 3: type 3
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd2, 4'd1}

module tb_bingo_hw_manager_replay_stuck_other_core;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
