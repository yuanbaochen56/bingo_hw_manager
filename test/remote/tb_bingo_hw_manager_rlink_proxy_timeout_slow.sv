// Level 3 over the real transport, origin-side proxy timeout: every remote done comes within the timeout: no false timeout
`define TB_STIMULUS_FILE "tb_stimulus_rlink_proxy_timeout.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0
`define TB_FAULT2_CORE -1
`define TB_FAULT2_TASK_ID 0
`define TB_CORE_TYPE_ID {4'd3, 4'd2, 4'd1}
`define TB_SUBSTITUTE_LEVEL_MASK 3'b111
`define TB_REMOTE_LINK 2
`define TB_REMOTE_STALL 0
`define TB_REMOTE_PROXY_TIMEOUT 1800
`define TB_PT_HOLD 1500

module tb_bingo_hw_manager_rlink_proxy_timeout_slow;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
