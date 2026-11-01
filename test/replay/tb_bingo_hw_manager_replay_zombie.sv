// Replay: a fenced core that comes back cannot retire its task a second time
`define TB_STIMULUS_FILE "tb_stimulus_replay_zombie.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 1
`define TB_FAULT_ZOMBIE_DELAY 20

module tb_bingo_hw_manager_replay_zombie;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
