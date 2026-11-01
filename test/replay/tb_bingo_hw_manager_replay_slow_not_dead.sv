// Replay: a slow core (silent between the two timeouts) is not fenced
`define TB_STIMULUS_FILE "tb_stimulus_replay_slow_not_dead.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 2
`define TB_FAULT_SLOW_CYCLES 450

module tb_bingo_hw_manager_replay_slow_not_dead;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
