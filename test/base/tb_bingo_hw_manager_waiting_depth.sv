// Waiting queues of depth 2 (WaitingQueueDepth): back-pressure on the task queue
`define TB_STIMULUS_FILE "tb_stimulus_waiting_depth.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WAITING_QUEUE_DEPTH 2

module tb_bingo_hw_manager_waiting_depth;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
