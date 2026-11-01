// A fence while a park is draining drops the park. The outstanding task is
// replayed once; the task that was held goes to the substitute afterwards.
`define TB_STIMULUS_FILE "tb_stimulus_park_fence.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 400
`define TB_FAULT_CORE 0
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0

module tb_bingo_hw_manager_park_fence;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
