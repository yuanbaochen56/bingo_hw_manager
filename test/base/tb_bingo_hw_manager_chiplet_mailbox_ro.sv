// Chiplet done-queue mailbox: a remote write of a register other than the
// write register (thresholds, IRQ, CTRL flush) answers SLVERR and loses no
// queued dependency set
`define TB_STIMULUS_FILE "tb_stimulus_chiplet_mailbox_ro.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_chiplet_mailbox_ro;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
