// Core parking: the substitute of a parked core dies; no core is left: the park fails and logical core 0 runs its tasks again.
// Tasks of the parked core that wait in front of the dead substitute's full
// queue must not overtake the replay of its older tasks
`define TB_STIMULUS_FILE "tb_stimulus_park_sub_fence.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_FAULT_CORE 1
`define TB_FAULT_TASK_ID 1
`define TB_FAULT_MODE 0

module tb_bingo_hw_manager_park_sub_fence_last;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
