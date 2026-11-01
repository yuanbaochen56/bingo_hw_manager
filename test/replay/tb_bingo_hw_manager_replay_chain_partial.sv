// Replay: the substitute dies while the dead core is only partly moved (P0-3)
`define TB_STIMULUS_FILE "tb_stimulus_replay_chain_partial.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 4
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE 1
`define TB_FAULT2_TASK_ID 11

module tb_bingo_hw_manager_replay_chain_partial;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
