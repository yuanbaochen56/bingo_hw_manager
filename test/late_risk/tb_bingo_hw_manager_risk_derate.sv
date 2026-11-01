// Fault precursors without a substitute: parking fails and the at-risk core's
// domain runs at the derate level; clearing the risk restores the normal level.
`define TB_STIMULUS_FILE "tb_stimulus_risk_derate.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 2
`define TB_WATCHDOG_HEARTBEAT_TIMEOUT 200
`define TB_WATCHDOG_CONFIRM_TIMEOUT 800
`define TB_DISABLE_CORE_WORKERS 1
`define TB_PM_ENABLE 1
`define TB_PM_BOOST_LEVEL 3
// core 1 type 2, core 0 type 1: core 0 has no substitute
`define TB_CORE_TYPE_ID {4'd2, 4'd1}

module tb_bingo_hw_manager_risk_derate;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
