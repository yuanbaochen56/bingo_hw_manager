`define TB_STIMULUS_FILE "tb_stimulus_csr_heartbeat_addr.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 16
// HeMAiA-style configuration: heartbeat = write to the ready CSR (0x5fe),
// core 2 (the host slot on HeMAiA) excluded from the watchdog.
`define TB_CSR_HEARTBEAT_ADDR 12'h5fe
`define TB_WATCHDOG_CORE_MASK 3'b011
`define TB_DISABLE_CORE_WORKERS 1

module tb_bingo_hw_manager_csr_heartbeat_addr;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
