// Replay: a done that races with the confirm timeout retires the task exactly once
`define TB_STIMULUS_FILE "tb_stimulus_replay_done_race.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 5
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 16
`define TB_WATCHDOG_CONFIRM_TIMEOUT 64
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_replay_done_race;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
