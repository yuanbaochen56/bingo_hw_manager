// =============================================================================
// Bingo HW Manager Testbench Harness
// =============================================================================
// Reusable testbench infrastructure for bingo_hw_manager_top.
// This file is `included inside a module wrapper that defines:
//   `TB_NUM_CHIPLET
//   `TB_NUM_CLUSTERS_PER_CHIPLET
//   `TB_NUM_CORES_PER_CLUSTER
//   `TB_STIMULUS_FILE  (path to stimulus .svh file)
//
// The stimulus file must define:
//   localparam int unsigned EXPECTED_TASK_COUNT = ...;
//   localparam int unsigned DEADLOCK_THRESHOLD  = ...;  (cycles without progress => deadlock)
//   localparam int unsigned DEP_MATRIX_LOG_INTERVAL = ...; (0 = disabled)
//   Task descriptor declarations (using pack_*_task helpers)
//   Per-chiplet push sequences (initial blocks)
// =============================================================================

`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "axi/port.svh"

`ifndef TB_EVLOG_DEPTH
  `define TB_EVLOG_DEPTH 0
`endif

import axi_pkg::*;
import axi_test::*;

// ---------------------------------------------------------------------------
// Local configuration (from defines)
// ---------------------------------------------------------------------------
`ifndef TB_WATCHDOG_HEARTBEAT_TIMEOUT
  `define TB_WATCHDOG_HEARTBEAT_TIMEOUT 100000
`endif
// Replay: cycles without heartbeat before a busy core is fenced (0: detection only)
`ifndef TB_WATCHDOG_CONFIRM_TIMEOUT
  `define TB_WATCHDOG_CONFIRM_TIMEOUT 0
`endif
`ifndef TB_DISABLE_CORE_WORKERS
  `define TB_DISABLE_CORE_WORKERS 0
`endif
// Fault injection into the core workers: core TB_FAULT_CORE (flat id, -1: none)
// misbehaves once it reads task TB_FAULT_TASK_ID.
//   TB_FAULT_MODE 0 HANG   : never reports done, no heartbeat
//   TB_FAULT_MODE 1 ZOMBIE : silent until fenced, then reports done
//                            TB_FAULT_ZOMBIE_DELAY cycles later and polls again
//   TB_FAULT_MODE 2 SLOW   : silent for TB_FAULT_SLOW_CYCLES, then reports done
`ifndef TB_FAULT_CORE
  `define TB_FAULT_CORE -1
`endif
`ifndef TB_FAULT_TASK_ID
  `define TB_FAULT_TASK_ID 0
`endif
`ifndef TB_FAULT_MODE
  `define TB_FAULT_MODE 0
`endif
`ifndef TB_FAULT_ZOMBIE_DELAY
  `define TB_FAULT_ZOMBIE_DELAY 20
`endif
`ifndef TB_FAULT_SLOW_CYCLES
  `define TB_FAULT_SLOW_CYCLES 0
`endif
// Second, independent fault (always HANG), e.g. a substitute that dies as well
`ifndef TB_FAULT2_CORE
  `define TB_FAULT2_CORE -1
`endif
`ifndef TB_FAULT2_TASK_ID
  `define TB_FAULT2_TASK_ID 0
`endif
// Third, independent fault (always HANG)
`ifndef TB_FAULT3_CORE
  `define TB_FAULT3_CORE -1
`endif
`ifndef TB_FAULT3_TASK_ID
  `define TB_FAULT3_TASK_ID 0
`endif
// CoreTypeId[core][cluster] of the DUT, 4 bits per slot (default: all type 1,
// every core of a cluster may take over any other)
`ifndef TB_CORE_TYPE_ID
  `define TB_CORE_TYPE_ID {(NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET){4'd1}}
`endif
// SubstituteLevelMask of the DUT ([0] same cluster, [1] other clusters, [2] remote)
`ifndef TB_SUBSTITUTE_LEVEL_MASK
  `define TB_SUBSTITUTE_LEVEL_MASK 3'b001
`endif
`ifndef TB_SUBSTITUTE_L2_TYPE_EN
  `define TB_SUBSTITUTE_L2_TYPE_EN 16'hffff
`endif
// Level 3: connect the remote dispatch / done streams of chiplet i to chiplet
// (i + 1) % NUM_CHIPLET (back to back; needs TB_SUBSTITUTE_LEVEL_MASK[2])
// Import stand-in levels (bingo_hw_manager_top ImportSubstituteLevelMask)
// Substitute choice when a core dies (bingo_hw_manager_top SubstitutePolicy)
`ifndef TB_SUBSTITUTE_POLICY
  `define TB_SUBSTITUTE_POLICY 0
`endif
// ForeignStuckDrain of the DUT (a stuck slot also drains a dead logical core's heads)
`ifndef TB_FOREIGN_STUCK_DRAIN
  `define TB_FOREIGN_STUCK_DRAIN 1
`endif
`ifndef TB_IMPORT_SUBSTITUTE_LEVEL_MASK
  `define TB_IMPORT_SUBSTITUTE_LEVEL_MASK (`TB_SUBSTITUTE_LEVEL_MASK & 3'b011)
`endif
// With TB_NUM_CHIPLET 1 the single chiplet is its own successor (loopback)
`ifndef TB_REMOTE_LINK
  `define TB_REMOTE_LINK 0
`endif
// TB_REMOTE_LINK 2: real transport, one bingo_hw_manager_remote_link per
// chiplet on an axi_lite_xbar addressed by chip id (ring: chiplet i exports to
// i + 1), with random handshake stalls (TB_REMOTE_STALL) and
// TB_REMOTE_CREDITS dispatch credits per peer
`ifndef TB_REMOTE_CREDITS
  `define TB_REMOTE_CREDITS 2
`endif
`ifndef TB_REMOTE_STALL
  `define TB_REMOTE_STALL 1
`endif
// Core types (bit = CoreTypeId) with an export target: mode 2 gives the other
// types no RemoteTargetChip entry, and every mode passes the mask to the top
// (remote_export_type_en_i)
`ifndef TB_REMOTE_TARGET_TYPES
  `define TB_REMOTE_TARGET_TYPES 16'hffff
`endif
// Mode 2 with 3+ chiplets: core types (bit = CoreTypeId) exported to the
// predecessor instead of the successor (two targets per chiplet)
`ifndef TB_REMOTE_PRED_TYPES
  `define TB_REMOTE_PRED_TYPES 16'h0000
`endif
// Origin side: cycles a proxy waits for a remote done before it gives up (0: never)
`ifndef TB_REMOTE_PROXY_TIMEOUT
  `define TB_REMOTE_PROXY_TIMEOUT 0
`endif
// Idle power management (DFS): every slot in domain 1 (TB_PM_CLUSTER_DOMAINS:
// cluster c in domain 1 + c), idle level 25, normal
// level 6 (HeMAiA's values); the PM's clk/rst controller writes always complete
`ifndef TB_PM_ENABLE
  `define TB_PM_ENABLE 0
`endif
localparam int unsigned PM_IDLE_LEVEL   = 25;
localparam int unsigned PM_NORMAL_LEVEL = 6;
// Recovery boost level (0: off)
`ifndef TB_PM_BOOST_LEVEL
  `define TB_PM_BOOST_LEVEL 0
`endif
localparam int unsigned PM_BOOST_LEVEL  = `TB_PM_BOOST_LEVEL;
// Idle entry delay in cycles (0: at once)
`ifndef TB_PM_IDLE_DELAY
  `define TB_PM_IDLE_DELAY 0
`endif
// External access wake: cycles a cluster stays awake after an access (0: off);
// the stimulus drives cluster_access
`ifndef TB_PM_ACCESS_HOLD
  `define TB_PM_ACCESS_HOLD 0
`endif
// 1: the slots of cluster c are in power domain 1 + c (default: all in domain 1)
`ifndef TB_PM_CLUSTER_DOMAINS
  `define TB_PM_CLUSTER_DOMAINS 0
`endif
// Link errors (remote_link error_o) are test failures unless allowed
`ifndef TB_ALLOW_LINK_ERROR
  `define TB_ALLOW_LINK_ERROR 0
`endif
// WatchdogCoreMask[core][cluster] of the DUT ('1: all slots monitored)
// A remote done that does not match the proxy head is an error unless a test
// provokes it
`ifndef TB_ALLOW_DONE_MISMATCH
  `define TB_ALLOW_DONE_MISMATCH 0
`endif

`ifndef TB_WATCHDOG_CORE_MASK
  `define TB_WATCHDOG_CORE_MASK '1
`endif
// Heartbeat CSR number (DUT CsrHeartbeatAddr and the CSR_HEARTBEAT used by stimuli)
`ifndef TB_CSR_HEARTBEAT_ADDR
  `define TB_CSR_HEARTBEAT_ADDR 12'h5fd
`endif
localparam int unsigned READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1; // 1: CSR Req/Resp
localparam int unsigned TASK_QUEUE_TYPE = 0;                     // 0: AXI Lite Slave
localparam int unsigned NUM_CHIPLET                = `TB_NUM_CHIPLET;
localparam int unsigned NUM_CLUSTERS_PER_CHIPLET   = `TB_NUM_CLUSTERS_PER_CHIPLET;
localparam int unsigned NUM_CORES_PER_CLUSTER      = `TB_NUM_CORES_PER_CLUSTER;
localparam int unsigned READY_AGENT_NUM = NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET;
localparam int unsigned WATCHDOG_HEARTBEAT_TIMEOUT = `TB_WATCHDOG_HEARTBEAT_TIMEOUT;
localparam int unsigned WATCHDOG_CONFIRM_TIMEOUT   = `TB_WATCHDOG_CONFIRM_TIMEOUT;
localparam int          FAULT_CORE                 = `TB_FAULT_CORE;
localparam int unsigned FAULT_TASK_ID              = `TB_FAULT_TASK_ID;
localparam int unsigned FAULT_MODE                 = `TB_FAULT_MODE;
localparam int          FAULT2_CORE                = `TB_FAULT2_CORE;
localparam int          FAULT3_CORE                = `TB_FAULT3_CORE;
localparam int unsigned FAULT3_TASK_ID             = `TB_FAULT3_TASK_ID;
localparam int unsigned FAULT2_TASK_ID             = `TB_FAULT2_TASK_ID;
localparam int unsigned FAULT_HANG                 = 0;
// Runtime copies of the fault selection: a stimulus may override them at time 0.
int          fault_core    = FAULT_CORE;
int unsigned fault_task_id = FAULT_TASK_ID;
int unsigned fault_mode    = FAULT_MODE;
// second fault, settable at run time as well (random stimuli)
int          fault2_core    = FAULT2_CORE;
int unsigned fault2_task_id = FAULT2_TASK_ID;
localparam int unsigned FAULT_ZOMBIE               = 1;
localparam int unsigned FAULT_SLOW                 = 2;

localparam time CyclTime = 10ns;
localparam time ApplTime =  2ns;
localparam time TestTime =  8ns;

localparam int unsigned ChipIdWidth = 8;
localparam int unsigned HOST_AW = 48;
localparam int unsigned HOST_DW = 64;
localparam int unsigned DEV_AW  = 48;
localparam int unsigned DEV_DW  = 32;

typedef logic [HOST_AW-1:0]   host_axi_lite_addr_t;
typedef logic [HOST_DW-1:0]   host_axi_lite_data_t;
typedef logic [HOST_DW/8-1:0] host_axi_lite_strb_t;
typedef logic [DEV_AW-1:0]    device_axi_lite_addr_t;
typedef logic [DEV_DW-1:0]    device_axi_lite_data_t;
typedef logic [DEV_DW/8-1:0]  device_axi_lite_strb_t;
typedef logic [ChipIdWidth-1:0] chip_id_t;

localparam device_axi_lite_addr_t CSR_READY     = device_axi_lite_addr_t'(12'h5fe);
localparam device_axi_lite_addr_t CSR_DONE      = device_axi_lite_addr_t'(12'h5ff);
localparam device_axi_lite_addr_t CSR_HEARTBEAT = device_axi_lite_addr_t'(`TB_CSR_HEARTBEAT_ADDR);

localparam host_axi_lite_addr_t TASK_QUEUE_BASE      = 48'h1000_0000;
localparam host_axi_lite_addr_t DONE_QUEUE_BASE      = 48'h2000_0000;
localparam host_axi_lite_addr_t READY_QUEUE_BASE     = 48'h3000_0000;
localparam host_axi_lite_addr_t READY_QUEUE_STRIDE   = 48'h1000;
localparam host_axi_lite_addr_t H2H_DONE_QUEUE_BASE  = 48'h4000_0000;

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------
localparam int unsigned TaskIdWidth = 12;

typedef logic [1:0]                                                  bingo_hw_manager_task_type_t;
typedef logic [TaskIdWidth-1:0]                                      bingo_hw_manager_task_id_t;
typedef logic [ChipIdWidth-1:0]                                      bingo_hw_manager_assigned_chiplet_id_t;
typedef logic [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_assigned_cluster_id_t;
typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0]    bingo_hw_manager_assigned_core_id_t;
typedef logic [NUM_CORES_PER_CLUSTER-1:0]                            bingo_hw_manager_dep_code_t;
// Per-edge identity tag (must mirror bingo_hw_manager_top exactly).
localparam int unsigned DEP_TAG_WIDTH = 4;
typedef logic [DEP_TAG_WIDTH-1:0]                                    bingo_hw_manager_dep_tag_t;

typedef struct packed {
    bingo_hw_manager_dep_tag_t                   dep_check_tag;
    bingo_hw_manager_dep_code_t                  dep_check_code;
    logic                                        dep_check_en;
} bingo_hw_manager_dep_check_info_t;

typedef struct packed {
    bingo_hw_manager_dep_tag_t                   dep_set_tag;
    bingo_hw_manager_dep_code_t                  dep_set_code;
    bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
    bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id;
    logic                                        dep_set_all_chiplet;
    logic                                        dep_set_en;
} bingo_hw_manager_dep_set_info_t;

typedef struct packed {
    logic                                        is_exit;
    bingo_hw_manager_dep_set_info_t              dep_set_info;
    bingo_hw_manager_dep_check_info_t            dep_check_info;
    bingo_hw_manager_assigned_core_id_t          assigned_core_id;
    bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
    bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
    bingo_hw_manager_task_id_t                   task_id;
    bingo_hw_manager_task_type_t                 task_type;
    logic                                        cond_exec_en;
    logic [4:0]                                  cond_exec_group_id;
    logic                                        cond_exec_invert;
} bingo_hw_manager_task_desc_t;

localparam int unsigned TaskDescWidth = $bits(bingo_hw_manager_task_desc_t);
localparam int unsigned ReservedBitsForTaskDesc = HOST_DW - TaskDescWidth;

if (TaskDescWidth > HOST_DW) begin : gen_task_desc_width_check
    initial begin
        $error("Task Descriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)!", TaskDescWidth, HOST_DW);
        $finish;
    end
end

typedef struct packed {
    logic [ReservedBitsForTaskDesc-1:0]          reserved_bits;
    logic                                        is_exit;
    bingo_hw_manager_dep_set_info_t              dep_set_info;
    bingo_hw_manager_dep_check_info_t            dep_check_info;
    bingo_hw_manager_assigned_core_id_t          assigned_core_id;
    bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
    bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
    bingo_hw_manager_task_id_t                   task_id;
    bingo_hw_manager_task_type_t                 task_type;
    logic                                        cond_exec_en;
    logic [4:0]                                  cond_exec_group_id;
    logic                                        cond_exec_invert;
} bingo_hw_manager_task_desc_full_t;

typedef struct packed {
    bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
    bingo_hw_manager_assigned_core_id_t        assigned_core_id;
    bingo_hw_manager_task_id_t                 task_id;
} bingo_hw_manager_done_info_t;

localparam int unsigned DoneInfoWidth = $bits(bingo_hw_manager_done_info_t);
localparam int unsigned ReservedBitsForDoneInfo = DEV_DW - DoneInfoWidth;

if (DoneInfoWidth > DEV_DW) begin : gen_done_info_width_check
    initial begin
        $error("Done Info width (%0d) exceeds Device AXI Lite Data Width (%0d)!", DoneInfoWidth, DEV_DW);
        $finish;
    end
end

typedef struct packed {
    logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
    bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
    bingo_hw_manager_assigned_core_id_t        assigned_core_id;
    bingo_hw_manager_task_id_t                 task_id;
} bingo_hw_manager_done_info_full_t;

// CSR types
typedef struct packed {
    device_axi_lite_addr_t   addr;
    device_axi_lite_data_t   data;
    logic                    write;
} csr_req_t;

typedef struct packed {
    device_axi_lite_data_t   data;
} csr_rsp_t;

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------
function automatic int flat_id(
    input int chip_id,
    input int cluster_id,
    input int core_id
);
    return chip_id * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER +
           cluster_id * NUM_CORES_PER_CLUSTER +
           core_id;
endfunction

function automatic bingo_hw_manager_task_desc_full_t pack_normal_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code,
    input logic                                  dep_set_en,
    input logic                                  dep_set_all_chiplet,
    input bingo_hw_manager_assigned_chiplet_id_t dep_set_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id,
    input bingo_hw_manager_dep_code_t            dep_set_code,
    input bingo_hw_manager_dep_tag_t             dep_check_tag = '0,
    input bingo_hw_manager_dep_tag_t             dep_set_tag = '0
);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info.dep_check_en      = dep_check_en;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_check_info.dep_check_tag     = dep_check_tag;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_all_chiplet = dep_set_all_chiplet;
    tmp.dep_set_info.dep_set_chiplet_id  = dep_set_chiplet_id;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.dep_set_info.dep_set_tag         = dep_set_tag;
    tmp.cond_exec_en                     = 1'b0;
    tmp.cond_exec_group_id               = 5'b0;
    tmp.cond_exec_invert                 = 1'b0;
    tmp.is_exit                          = 1'b0;
    tmp.reserved_bits                    = '0;
    return tmp;
endfunction

function automatic bingo_hw_manager_task_desc_full_t pack_dummy_check_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code,
    input bingo_hw_manager_dep_tag_t             dep_check_tag = '0
);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info.dep_check_en      = 1'b1;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_check_info.dep_check_tag     = dep_check_tag;
    tmp.dep_set_info                     = '0;
    tmp.cond_exec_en                     = 1'b0;
    tmp.cond_exec_group_id               = 5'b0;
    tmp.cond_exec_invert                 = 1'b0;
    tmp.is_exit                          = 1'b0;
    tmp.reserved_bits                    = '0;
    return tmp;
endfunction

function automatic bingo_hw_manager_task_desc_full_t pack_dummy_set_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_set_en,
    input logic                                  dep_set_all_chiplet,
    input bingo_hw_manager_assigned_chiplet_id_t dep_set_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id,
    input bingo_hw_manager_dep_code_t            dep_set_code,
    input bingo_hw_manager_dep_tag_t             dep_set_tag = '0
);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info                   = '0;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_all_chiplet = dep_set_all_chiplet;
    tmp.dep_set_info.dep_set_chiplet_id  = dep_set_chiplet_id;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.dep_set_info.dep_set_tag         = dep_set_tag;
    tmp.cond_exec_en                     = 1'b0;
    tmp.cond_exec_group_id               = 5'b0;
    tmp.cond_exec_invert                 = 1'b0;
    tmp.is_exit                          = 1'b0;
    tmp.reserved_bits                    = '0;
    return tmp;
endfunction

// ---------------------------------------------------------------------------
// Clock / Reset
// ---------------------------------------------------------------------------
logic clk_i;
logic rst_ni;

clk_rst_gen #(
    .ClkPeriod    ( CyclTime ),
    .RstClkCycles ( 5        )
) i_clk_gen (
    .clk_o  ( clk_i  ),
    .rst_no ( rst_ni )
);

// ---------------------------------------------------------------------------
// AXI-Lite type aliases
// ---------------------------------------------------------------------------
`AXI_LITE_TYPEDEF_ALL(host, host_axi_lite_addr_t, host_axi_lite_data_t, host_axi_lite_strb_t)
`AXI_LITE_TYPEDEF_ALL(dev,  device_axi_lite_addr_t, device_axi_lite_data_t, device_axi_lite_strb_t)

// ---------------------------------------------------------------------------
// Interface instantiation
// ---------------------------------------------------------------------------
AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW), .AXI_DATA_WIDTH(HOST_DW))
    local_task_if [NUM_CHIPLET-1:0] (.clk_i(clk_i));

AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW), .AXI_DATA_WIDTH(DEV_DW))
    local_done_if [NUM_CHIPLET-1:0] (.clk_i(clk_i));

AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW), .AXI_DATA_WIDTH(DEV_DW))
    local_ready_if [NUM_CHIPLET*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER-1:0] (.clk_i(clk_i));

// Task queue wires
host_req_t  [NUM_CHIPLET-1:0] local_task_queue_req;
host_resp_t [NUM_CHIPLET-1:0] local_task_queue_resp;

for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    `AXI_LITE_ASSIGN_TO_REQ   (local_task_queue_req[chiplet_idx],  local_task_if[chiplet_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_task_if[chiplet_idx],         local_task_queue_resp[chiplet_idx]);
end

// Done queue wires
dev_req_t  [NUM_CHIPLET-1:0] local_done_queue_req;
dev_resp_t [NUM_CHIPLET-1:0] local_done_queue_resp;

for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    `AXI_LITE_ASSIGN_TO_REQ   (local_done_queue_req[chiplet_idx],  local_done_if[chiplet_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_done_if[chiplet_idx],         local_done_queue_resp[chiplet_idx]);
end

// Ready queue wires
dev_req_t  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_req  [NUM_CHIPLET];
dev_resp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_resp [NUM_CHIPLET];

for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    for (genvar cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
        for (genvar core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
            `AXI_LITE_ASSIGN_TO_REQ   (local_ready_queue_req[chiplet_idx][core_idx][cluster_idx],
                                       local_ready_if[flat_id(chiplet_idx, cluster_idx, core_idx)]);
            `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if[flat_id(chiplet_idx, cluster_idx, core_idx)],
                                       local_ready_queue_resp[chiplet_idx][core_idx][cluster_idx]);
        end
    end
end

// CSR interfaces
csr_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req       [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req_valid  [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req_ready  [NUM_CHIPLET];
csr_rsp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp       [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp_valid [NUM_CHIPLET];
logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp_ready [NUM_CHIPLET];

// ---------------------------------------------------------------------------
// H2H Chiplet Xbar
// ---------------------------------------------------------------------------
localparam axi_pkg::xbar_cfg_t H2HAxiLiteXbarCfg = '{
    NoSlvPorts:         NUM_CHIPLET,
    NoMstPorts:         NUM_CHIPLET,
    MaxSlvTrans:        4,
    MaxMstTrans:        4,
    FallThrough:        0,
    LatencyMode:        axi_pkg::CUT_ALL_PORTS,
    PipelineStages:     0,
    AxiIdWidthSlvPorts: 0,
    AxiIdUsedSlvPorts:  0,
    UniqueIds:          0,
    AxiAddrWidth:       HOST_AW,
    AxiDataWidth:       HOST_DW,
    NoAddrRules:        NUM_CHIPLET
};

typedef struct packed {
    logic [31:0] idx;
    logic [47:0] start_addr;
    logic [47:0] end_addr;
} xbar_rule_48_t;

host_req_t     [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_in_req;
host_resp_t    [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_in_resp;
host_req_t     [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_out_req;
host_resp_t    [NUM_CHIPLET-1:0] h2h_axi_lite_xbar_out_resp;
xbar_rule_48_t [NUM_CHIPLET-1:0] H2HAxiLiteXbarAddrmap;

for (genvar i = 0; i < NUM_CHIPLET; i++) begin
    assign H2HAxiLiteXbarAddrmap[i] = '{
        idx:        i,
        start_addr: {8'(i), 40'h0},
        end_addr:   {8'(i), 40'h8000_0000}
    };
end

axi_lite_xbar #(
    .Cfg        ( H2HAxiLiteXbarCfg ),
    .aw_chan_t  ( host_aw_chan_t     ),
    .w_chan_t   ( host_w_chan_t      ),
    .b_chan_t   ( host_b_chan_t      ),
    .ar_chan_t  ( host_ar_chan_t     ),
    .r_chan_t   ( host_r_chan_t      ),
    .axi_req_t ( host_req_t         ),
    .axi_resp_t( host_resp_t        ),
    .rule_t    ( xbar_rule_48_t     )
) i_axi_lite_xbar_h2h_chiplet (
    .clk_i                  ( clk_i                       ),
    .rst_ni                 ( rst_ni                      ),
    .test_i                 ( '0                          ),
    .slv_ports_req_i        ( h2h_axi_lite_xbar_in_req    ),
    .slv_ports_resp_o       ( h2h_axi_lite_xbar_in_resp   ),
    .mst_ports_req_o        ( h2h_axi_lite_xbar_out_req   ),
    .mst_ports_resp_i       ( h2h_axi_lite_xbar_out_resp  ),
    .addr_map_i             ( H2HAxiLiteXbarAddrmap       ),
    .en_default_mst_port_i  ( '0                          ),
    .default_mst_port_i     ( '0                          )
);

// Probe of chiplet 0's chiplet done-queue port: while h2h_probe_en is set
// (by a stimulus, only while the xbar has nothing in flight to chiplet 0),
// h2h_probe_master drives that port instead of the xbar
AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW), .AXI_DATA_WIDTH(HOST_DW)) h2h_probe_if (.clk_i(clk_i));
host_req_t                    h2h_probe_req;
host_resp_t                   h2h_probe_resp;
logic                         h2h_probe_en = 1'b0;
host_req_t  [NUM_CHIPLET-1:0] h2h_dut_req;
host_resp_t [NUM_CHIPLET-1:0] h2h_dut_resp;
`AXI_LITE_ASSIGN_TO_REQ   (h2h_probe_req, h2h_probe_if);
`AXI_LITE_ASSIGN_FROM_RESP(h2h_probe_if,  h2h_probe_resp);
assign h2h_probe_resp = h2h_dut_resp[0];
for (genvar i = 0; i < NUM_CHIPLET; i++) begin : gen_h2h_probe_mux
    if (i == 0) begin : gen_probe
        assign h2h_dut_req[i]                = h2h_probe_en ? h2h_probe_req : h2h_axi_lite_xbar_out_req[i];
        assign h2h_axi_lite_xbar_out_resp[i] = h2h_probe_en ? host_resp_t'('0) : h2h_dut_resp[i];
    end else begin : gen_pass
        assign h2h_dut_req[i]                = h2h_axi_lite_xbar_out_req[i];
        assign h2h_axi_lite_xbar_out_resp[i] = h2h_dut_resp[i];
    end
end

// ---------------------------------------------------------------------------
// AXI Drivers
// ---------------------------------------------------------------------------
typedef axi_test::axi_lite_rand_master #(
    .AW ( HOST_AW ), .DW ( HOST_DW ),
    .TA ( ApplTime ), .TT ( TestTime ),
    .MIN_ADDR ( 48'h0 ), .MAX_ADDR ( {8'(NUM_CHIPLET-1), 40'h8000_0000} ),
    .MAX_READ_TXNS  ( 10 ), .MAX_WRITE_TXNS ( 10 )
) host_rand_lite_master_t;

typedef axi_test::axi_lite_rand_master #(
    .AW ( DEV_AW ), .DW ( DEV_DW ),
    .TA ( ApplTime ), .TT ( TestTime ),
    .MIN_ADDR ( 48'h0 ), .MAX_ADDR ( {8'(NUM_CHIPLET-1), 40'h8000_0000} ),
    .MAX_READ_TXNS  ( 10 ), .MAX_WRITE_TXNS ( 10 )
) dev_rand_lite_master_t;

host_rand_lite_master_t h2h_probe_master;
initial begin
    h2h_probe_master = new(h2h_probe_if, "h2h_probe_master");
    h2h_probe_master.reset();
end

host_rand_lite_master_t task_queue_master [NUM_CHIPLET];
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_task_queue_master
    initial begin
        automatic string name = $sformatf("task_queue_master_chiplet%0d", chiplet_idx);
        task_queue_master[chiplet_idx] = new(local_task_if[chiplet_idx], name);
        task_queue_master[chiplet_idx].reset();
    end
end

dev_rand_lite_master_t done_queue_master [NUM_CHIPLET];
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_done_queue_master
    initial begin
        automatic string name = $sformatf("done_queue_master_chiplet%0d", chiplet_idx);
        done_queue_master[chiplet_idx] = new(local_done_if[chiplet_idx], name);
        done_queue_master[chiplet_idx].reset();
    end
end

dev_rand_lite_master_t ready_queue_master [NUM_CHIPLET*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER];
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_ready_queue_master
    for (genvar cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
        for (genvar core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
            localparam int RQ_IDX = chiplet_idx * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER
                                  + cluster_idx * NUM_CORES_PER_CLUSTER
                                  + core_idx;
            initial begin
                automatic string name = $sformatf("ready_queue_master_chip%0d_cl%0d_co%0d",
                                                  chiplet_idx, cluster_idx, core_idx);
                ready_queue_master[RQ_IDX] = new(local_ready_if[RQ_IDX], name);
                ready_queue_master[RQ_IDX].reset();
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Chip IDs and task queue base addresses
// ---------------------------------------------------------------------------
chip_id_t [NUM_CHIPLET-1:0] chip_id;
for (genvar i = 0; i < NUM_CHIPLET; i++) begin
    assign chip_id[i] = chip_id_t'(i);
end

host_axi_lite_addr_t [NUM_CHIPLET-1:0] task_queue_base;
for (genvar i = 0; i < NUM_CHIPLET; i++) begin
    assign task_queue_base[i] = {chip_id[i], TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]};
end

// ---------------------------------------------------------------------------
// DARTS Tier 1: Per-chiplet CERF control signals (driven by stimulus)
// ---------------------------------------------------------------------------
logic [NUM_CHIPLET-1:0]      cerf_write_en;
logic [31:0]                 cerf_write_data [NUM_CHIPLET];
// Degradation table (core type -> clear/set). Width 16 matches CoreTypeIdWidth 4.
localparam int unsigned CERF_FB_NUM_TYPES = 16;
logic [CERF_FB_NUM_TYPES-1:0]      cerf_fb_en    [NUM_CHIPLET];
logic [CERF_FB_NUM_TYPES-1:0][4:0] cerf_fb_clear [NUM_CHIPLET];
logic [CERF_FB_NUM_TYPES-1:0][4:0] cerf_fb_set   [NUM_CHIPLET];
logic [CERF_FB_NUM_TYPES-1:0]      cerf_fb_evt   [NUM_CHIPLET];

initial begin
    cerf_write_en = '0;
    for (int i = 0; i < NUM_CHIPLET; i++) begin
        cerf_write_data[i] = '0;
        cerf_fb_en[i]      = '0;
        cerf_fb_clear[i]   = '0;
        cerf_fb_set[i]     = '0;
    end
end

task automatic cerf_write_bitmask(input int chip, input logic [31:0] mask);
    cerf_write_data[chip] <= mask;
    cerf_write_en[chip]   <= 1'b1;
    @(posedge clk_i);
    cerf_write_en[chip]   <= 1'b0;
    @(posedge clk_i);
endtask

// ---------------------------------------------------------------------------
// Level 3 remote streams (per chiplet, see TB_REMOTE_LINK)
// ---------------------------------------------------------------------------
localparam int unsigned REMOTE_SLOT_W = cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET);
localparam host_axi_lite_addr_t REMOTE_LINK_BASE = 48'h5000_0000;  // 8 KiB: dispatch page, done page
// Outputs of chiplet i
logic                     rd_valid       [NUM_CHIPLET];
logic                     rd_ready       [NUM_CHIPLET];
host_axi_lite_data_t      rd_desc        [NUM_CHIPLET];
logic [3:0]               rd_core_type   [NUM_CHIPLET];
chip_id_t                 rd_origin_chip [NUM_CHIPLET];
logic [REMOTE_SLOT_W-1:0] rd_proxy_slot  [NUM_CHIPLET];
logic                     rdn_valid      [NUM_CHIPLET];
logic                     rdn_ready      [NUM_CHIPLET];
chip_id_t                 rdn_chip       [NUM_CHIPLET];
logic [REMOTE_SLOT_W-1:0] rdn_proxy_slot [NUM_CHIPLET];
logic [TaskIdWidth-1:0]   rdn_task_id    [NUM_CHIPLET];
logic                     rdn_reject     [NUM_CHIPLET];
// Inputs of chiplet i (mode 1: exports of its predecessor and dones of its
// successor wired directly; mode 2: from its remote_link)
logic                     rd_in_valid       [NUM_CHIPLET];
logic                     rd_in_ready       [NUM_CHIPLET];
host_axi_lite_data_t      rd_in_desc        [NUM_CHIPLET];
logic [3:0]               rd_in_core_type   [NUM_CHIPLET];
chip_id_t                 rd_in_origin_chip [NUM_CHIPLET];
logic [REMOTE_SLOT_W-1:0] rd_in_proxy_slot  [NUM_CHIPLET];
logic                     rdn_in_valid      [NUM_CHIPLET];
logic                     rdn_in_ready      [NUM_CHIPLET];
logic [REMOTE_SLOT_W-1:0] rdn_in_proxy_slot [NUM_CHIPLET];
logic [TaskIdWidth-1:0]   rdn_in_task_id    [NUM_CHIPLET];
logic                     rdn_in_reject     [NUM_CHIPLET];
// Rejects received by chiplet i (task ids of its rejected exports, in order)
int unsigned              remote_rejects    [NUM_CHIPLET][$];
localparam logic [15:0]   REMOTE_TARGET_TYPES = `TB_REMOTE_TARGET_TYPES;
logic [15:0]              remote_type_en    [NUM_CHIPLET];  // to the top (remote_export_type_en_i)
// Export queues of the top: one per link peer (mode 2: successor and, with 3+
// chiplets, predecessor), the queue of each type and the peers with a credit
localparam int unsigned   RL_NUM_PEERS = ((`TB_REMOTE_LINK == 2) && (NUM_CHIPLET > 2)) ? 2 : 1;
logic [15:0][0:0]         remote_type_peer  [NUM_CHIPLET];
logic [RL_NUM_PEERS-1:0]  remote_peer_ready [NUM_CHIPLET];
// A stimulus may hold the imports of chiplet i (both sides of the handshake)
logic [NUM_CHIPLET-1:0]   rl_import_hold = '0;
logic                     remote_timeout    [NUM_CHIPLET];  // remote_timeout_o
int unsigned              remote_export_count [NUM_CHIPLET];
int unsigned              remote_import_count [NUM_CHIPLET];
int unsigned              remote_done_in_count [NUM_CHIPLET];
// mode 2 only
logic [5:0]               remote_link_error   [NUM_CHIPLET];
int unsigned              remote_credit_stall [NUM_CHIPLET];  // cycles an export waited for a credit
int unsigned              remote_max_outstanding [NUM_CHIPLET];
for (genvar i = 0; i < NUM_CHIPLET; i++) begin : gen_remote_link
    localparam int unsigned Pred = (i + NUM_CHIPLET - 1) % NUM_CHIPLET;
    localparam int unsigned Succ = (i + 1) % NUM_CHIPLET;
    if (`TB_REMOTE_LINK != 2) begin : gen_direct
        // chiplet i exports to Succ and gets the dones of its exports from Succ
        assign rd_in_valid[i]       = (`TB_REMOTE_LINK != 0) && rd_valid[Pred];
        assign rd_in_ready[i]       = (`TB_REMOTE_LINK != 0) && rd_ready[Succ];
        assign rd_in_desc[i]        = rd_desc[Pred];
        assign rd_in_core_type[i]   = rd_core_type[Pred];
        assign rd_in_origin_chip[i] = rd_origin_chip[Pred];
        assign rd_in_proxy_slot[i]  = rd_proxy_slot[Pred];
        assign rdn_in_valid[i]      = (`TB_REMOTE_LINK != 0) && rdn_valid[Succ] && (rdn_chip[Succ] == chip_id_t'(i));
        assign rdn_in_ready[i]      = (`TB_REMOTE_LINK != 0) && rdn_ready[Pred];
        assign rdn_in_proxy_slot[i] = rdn_proxy_slot[Succ];
        assign rdn_in_task_id[i]    = rdn_task_id[Succ];
        assign rdn_in_reject[i]     = rdn_reject[Succ];
        assign remote_link_error[i] = '0;
        assign remote_type_en[i]    = REMOTE_TARGET_TYPES;
        assign remote_type_peer[i]  = '0;
        assign remote_peer_ready[i] = '1;
    end
    initial begin
        remote_export_count[i]    = 0;
        remote_import_count[i]    = 0;
        remote_done_in_count[i]   = 0;
        remote_credit_stall[i]    = 0;
        remote_max_outstanding[i] = 0;
    end
    // Done order: per proxy slot, the dones come back in export order
    int unsigned export_order [1 << REMOTE_SLOT_W][$];
    always @(posedge clk_i) begin
        if (rst_ni) begin
            if (rd_valid[i] && rd_in_ready[i]) begin
                automatic bingo_hw_manager_task_desc_full_t ed = bingo_hw_manager_task_desc_full_t'(rd_desc[i]);
                remote_export_count[i]++;
                export_order[rd_proxy_slot[i]].push_back(ed.task_id);
                if (remote_export_count[i] - remote_done_in_count[i] > remote_max_outstanding[i]) begin
                    remote_max_outstanding[i] = remote_export_count[i] - remote_done_in_count[i];
                end
            end
            if (rd_in_valid[i] && rd_ready[i] && !rl_import_hold[i] && !gen_dut[i].i_dut.imported.reject) remote_import_count[i]++;
            if (rdn_in_valid[i] && rdn_ready[i]) begin
                remote_done_in_count[i]++;
                if (rdn_in_reject[i]) begin
                    remote_rejects[i].push_back(rdn_in_task_id[i]);
                    $display("[TB] %0t chip %0d: reject of task %0d (slot %0d)", $time, i,
                             rdn_in_task_id[i], rdn_in_proxy_slot[i]);
                end
                if (export_order[rdn_in_proxy_slot[i]].size() == 0) begin
                    if (`TB_ALLOW_DONE_MISMATCH == 0)
                        $error("[REMOTE_LINK] chip %0d: done of task %0d for slot %0d without an export",
                               i, rdn_in_task_id[i], rdn_in_proxy_slot[i]);
                end else begin
                    if ((`TB_ALLOW_DONE_MISMATCH == 0) &&
                        (export_order[rdn_in_proxy_slot[i]][0] != rdn_in_task_id[i])) begin
                        $error("[REMOTE_LINK] chip %0d slot %0d: done of task %0d, expected task %0d",
                               i, rdn_in_proxy_slot[i], rdn_in_task_id[i], export_order[rdn_in_proxy_slot[i]][0]);
                    end
                    void'(export_order[rdn_in_proxy_slot[i]].pop_front());
                end
            end
            // a done goes back to the exporter: the predecessor, or with
            // TB_REMOTE_PRED_TYPES also the successor
            if ((`TB_REMOTE_LINK != 0) && rdn_valid[i] && (rdn_chip[i] != chip_id_t'(Pred)) &&
                ((`TB_REMOTE_PRED_TYPES == 0) || (rdn_chip[i] != chip_id_t'(Succ)))) begin
                $error("[REMOTE_LINK] chip %0d sends a done to chip %0d, expected %0d", i, rdn_chip[i], Pred);
            end
            if ((`TB_ALLOW_LINK_ERROR == 0) && (remote_link_error[i] != '0)) begin
                $error("[REMOTE_LINK] chip %0d: link error %b", i, remote_link_error[i]);
            end
        end
    end
end

function automatic logic [15:0][ChipIdWidth:0] rl_targets(input int unsigned succ, input int unsigned pred);
    for (int unsigned t = 0; t < 16; t++) begin
        rl_targets[t] = {REMOTE_TARGET_TYPES[t], ChipIdWidth'(`TB_REMOTE_PRED_TYPES & (16'd1 << t) ? pred : succ)};
    end
endfunction

if (`TB_REMOTE_LINK == 2) begin : gen_rlink
    localparam int unsigned RlNumPeers = RL_NUM_PEERS;
    host_req_t  [NUM_CHIPLET-1:0] rl_mst_req, rl_xbar_in_req, rl_xbar_out_req, rl_slv_req;
    host_resp_t [NUM_CHIPLET-1:0] rl_mst_resp, rl_xbar_in_resp, rl_xbar_out_resp, rl_slv_resp;
    xbar_rule_48_t [NUM_CHIPLET-1:0] rl_addr_map;
    localparam axi_pkg::xbar_cfg_t RlXbarCfg = '{
        NoSlvPorts:         NUM_CHIPLET,
        NoMstPorts:         NUM_CHIPLET,
        MaxSlvTrans:        4,
        MaxMstTrans:        4,
        FallThrough:        0,
        LatencyMode:        axi_pkg::CUT_ALL_PORTS,
        PipelineStages:     0,
        AxiIdWidthSlvPorts: 0,
        AxiIdUsedSlvPorts:  0,
        UniqueIds:          0,
        AxiAddrWidth:       HOST_AW,
        AxiDataWidth:       HOST_DW,
        NoAddrRules:        NUM_CHIPLET
    };
    for (genvar i = 0; i < NUM_CHIPLET; i++) begin : gen_node
        localparam int unsigned Pred = (i + NUM_CHIPLET - 1) % NUM_CHIPLET;
        localparam int unsigned Succ = (i + 1) % NUM_CHIPLET;
        localparam logic [RlNumPeers-1:0][ChipIdWidth-1:0] Peers =
            (NUM_CHIPLET <= 2) ? (RlNumPeers*ChipIdWidth)'(Succ) : (RlNumPeers*ChipIdWidth)'({8'(Succ), 8'(Pred)});
        // every core type of TB_REMOTE_TARGET_TYPES goes to the successor
        // (TB_REMOTE_PRED_TYPES: to the predecessor)
        localparam logic [15:0][ChipIdWidth:0] Targets = rl_targets(Succ, Pred);
        logic [RlNumPeers-1:0][$clog2(`TB_REMOTE_CREDITS + 1)-1:0] credits;
        assign rl_addr_map[i] = '{idx: i, start_addr: {8'(i), REMOTE_LINK_BASE[39:0]},
                                  end_addr: {8'(i), REMOTE_LINK_BASE[39:0] + 40'h2000}};
        bingo_hw_manager_remote_link #(
            .ChipIdWidth       ( ChipIdWidth           ),
            .CoreTypeIdWidth   ( 4                     ),
            .RemoteSlotIdWidth ( REMOTE_SLOT_W         ),
            .TaskIdWidth       ( TaskIdWidth           ),
            .AxiAddrWidth      ( HOST_AW               ),
            .AxiDataWidth      ( HOST_DW               ),
            .NumPeers          ( RlNumPeers            ),
            .PeerChipId        ( Peers                 ),
            .RemoteTargetChip  ( Targets               ),
            .DispatchCredits   ( `TB_REMOTE_CREDITS    ),
            .req_t             ( host_req_t            ),
            .resp_t            ( host_resp_t           )
        ) i_link (
            .clk_i                 ( clk_i                ),
            .rst_ni                ( rst_ni               ),
            .chip_id_i             ( chip_id[i]           ),
            .base_addr_i           ( REMOTE_LINK_BASE     ),
            .export_valid_i        ( rd_valid[i]          ),
            .export_ready_o        ( rd_in_ready[i]       ),
            .export_desc_i         ( rd_desc[i]           ),
            .export_core_type_i    ( rd_core_type[i]      ),
            .export_origin_chip_i  ( rd_origin_chip[i]    ),
            .export_proxy_slot_i   ( rd_proxy_slot[i]     ),
            .done_out_valid_i      ( rdn_valid[i]         ),
            .done_out_ready_o      ( rdn_in_ready[i]      ),
            .done_out_chip_i       ( rdn_chip[i]          ),
            .done_out_proxy_slot_i ( rdn_proxy_slot[i]    ),
            .done_out_task_id_i    ( rdn_task_id[i]       ),
            .done_out_reject_i     ( rdn_reject[i]        ),
            .import_valid_o        ( rd_in_valid[i]       ),
            .import_ready_i        ( rd_ready[i] && !rl_import_hold[i] ),
            .import_desc_o         ( rd_in_desc[i]        ),
            .import_core_type_o    ( rd_in_core_type[i]   ),
            .import_origin_chip_o  ( rd_in_origin_chip[i] ),
            .import_proxy_slot_o   ( rd_in_proxy_slot[i]  ),
            .done_in_valid_o       ( rdn_in_valid[i]      ),
            .done_in_ready_i       ( rdn_ready[i]         ),
            .done_in_proxy_slot_o  ( rdn_in_proxy_slot[i] ),
            .done_in_task_id_o     ( rdn_in_task_id[i]    ),
            .done_in_reject_o      ( rdn_in_reject[i]     ),
            .mst_req_o             ( rl_mst_req[i]        ),
            .mst_resp_i            ( rl_mst_resp[i]       ),
            .slv_req_i             ( rl_slv_req[i]        ),
            .slv_resp_o            ( rl_slv_resp[i]       ),
            .target_valid_o        ( remote_type_en[i]    ),
            .target_peer_o         ( remote_type_peer[i]  ),
            .peer_ready_o          ( remote_peer_ready[i] ),
            .error_o               ( remote_link_error[i] ),
            .credits_o             ( credits              )
        );
        // random stalls on both sides of the xbar
        bingo_tb_axi_lite_stall #(
            .Enable(`TB_REMOTE_STALL != 0), .Seed(16'(16'h1234 + 16 * i)),
            .aw_chan_t(host_aw_chan_t), .w_chan_t(host_w_chan_t), .b_chan_t(host_b_chan_t),
            .ar_chan_t(host_ar_chan_t), .r_chan_t(host_r_chan_t), .req_t(host_req_t), .resp_t(host_resp_t)
        ) i_stall_mst (
            .clk_i, .rst_ni,
            .slv_req_i(rl_mst_req[i]), .slv_resp_o(rl_mst_resp[i]),
            .mst_req_o(rl_xbar_in_req[i]), .mst_resp_i(rl_xbar_in_resp[i])
        );
        bingo_tb_axi_lite_stall #(
            .Enable(`TB_REMOTE_STALL != 0), .Seed(16'(16'h4321 + 16 * i)),
            .aw_chan_t(host_aw_chan_t), .w_chan_t(host_w_chan_t), .b_chan_t(host_b_chan_t),
            .ar_chan_t(host_ar_chan_t), .r_chan_t(host_r_chan_t), .req_t(host_req_t), .resp_t(host_resp_t)
        ) i_stall_slv (
            .clk_i, .rst_ni,
            .slv_req_i(rl_xbar_out_req[i]), .slv_resp_o(rl_xbar_out_resp[i]),
            .mst_req_o(rl_slv_req[i]), .mst_resp_i(rl_slv_resp[i])
        );
        always @(posedge clk_i) begin
            // an export waits in the export queue of a peer without credits
            // (the top only offers exports to peers that have one)
            if (rst_ni && |(~gen_dut[i].i_dut.i_remote_export.gen_export_queues.export_peer_empty & ~remote_peer_ready[i])) begin
                remote_credit_stall[i]++;
            end
        end
    end
    axi_lite_xbar #(
        .Cfg        ( RlXbarCfg       ),
        .aw_chan_t  ( host_aw_chan_t  ),
        .w_chan_t   ( host_w_chan_t   ),
        .b_chan_t   ( host_b_chan_t   ),
        .ar_chan_t  ( host_ar_chan_t  ),
        .r_chan_t   ( host_r_chan_t   ),
        .axi_req_t  ( host_req_t      ),
        .axi_resp_t ( host_resp_t     ),
        .rule_t     ( xbar_rule_48_t  )
    ) i_rl_xbar (
        .clk_i                 ( clk_i            ),
        .rst_ni                ( rst_ni           ),
        .test_i                ( 1'b0             ),
        .slv_ports_req_i       ( rl_xbar_in_req   ),
        .slv_ports_resp_o      ( rl_xbar_in_resp  ),
        .mst_ports_req_o       ( rl_xbar_out_req  ),
        .mst_ports_resp_i      ( rl_xbar_out_resp ),
        .addr_map_i            ( rl_addr_map      ),
        .en_default_mst_port_i ( '0               ),
        .default_mst_port_i    ( '0               )
    );
end

// PM bus: the clk/rst controller takes every write at once, unless a stimulus
// stalls it (pm_bus_stall: the domain level cannot change)
logic       pm_bus_stall = 1'b0;
// External accesses into each chiplet's clusters (driven by a stimulus)
logic [NUM_CLUSTERS_PER_CHIPLET-1:0] cluster_access [NUM_CHIPLET];
initial for (int i = 0; i < NUM_CHIPLET; i++) cluster_access[i] = '0;
// Core parking request (bit = core + cluster*NUM_CORES) and its sticky failure.
// Default 0: placement matches a run with parking left unused.
device_axi_lite_data_t park_req  [NUM_CHIPLET];
device_axi_lite_data_t park_fail [NUM_CHIPLET];
logic [63:0] evlog_head [NUM_CHIPLET];
logic [31:0] evlog_count [NUM_CHIPLET];
logic [15:0] evlog_dropped [NUM_CHIPLET];
logic [31:0] evlog_pop [NUM_CHIPLET];
logic [31:0] recovery_hold [NUM_CHIPLET], pm_access_level [NUM_CHIPLET];
initial for (int i = 0; i < NUM_CHIPLET; i++) begin
    evlog_pop[i] = '0;
    recovery_hold[i] = '0;
    pm_access_level[i] = '0;
end
always @(negedge clk_i)
    if (rst_ni && $test$plusargs("EVLOG_DRAIN"))
        for (int i = 0; i < NUM_CHIPLET; i++)
            if (evlog_count[i] != 0) evlog_pop[i]++;
initial for (int i = 0; i < NUM_CHIPLET; i++) park_req[i] = '0;
// Fault precursors (late threshold, policy, halving epoch, clear bitmap) and
// the at-risk bitmap. Default 0: off, as in a run without these ports.
device_axi_lite_data_t risk_late   [NUM_CHIPLET];
device_axi_lite_data_t risk_policy [NUM_CHIPLET];
device_axi_lite_data_t risk_epoch  [NUM_CHIPLET];
device_axi_lite_data_t risk_clear  [NUM_CHIPLET];
device_axi_lite_data_t risk_confirm [NUM_CHIPLET];
logic [15:0][31:0] wd_type_h [NUM_CHIPLET];
logic [15:0][31:0] wd_type_c [NUM_CHIPLET];
logic [31:0] wd_adapt [NUM_CHIPLET];
logic [31:0] wd_late [NUM_CHIPLET];
device_axi_lite_data_t risk        [NUM_CHIPLET];
initial for (int i = 0; i < NUM_CHIPLET; i++) begin
    risk_late[i] = '0; risk_policy[i] = '0; risk_epoch[i] = '0; risk_clear[i] = '0;
    risk_confirm[i] = '0;
    wd_type_h[i] = '0; wd_type_c[i] = '0;
    wd_adapt[i] = '0;
    wd_late[i] = '0;
end
// Boost choice ([0] policy, [11:8] credit, [23:16] minimum load); 0 = substitutes
device_axi_lite_data_t boost_policy [NUM_CHIPLET];
initial for (int i = 0; i < NUM_CHIPLET; i++) boost_policy[i] = '0;
// Power domain of every slot
device_axi_lite_data_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] pm_core_domain;
for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin : gen_pm_domain_core
    for (genvar cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin : gen_pm_domain_cluster
        assign pm_core_domain[c][cl] = device_axi_lite_data_t'((`TB_PM_CLUSTER_DOMAINS != 0) ? 1 + cl : 1);
    end
end
host_resp_t pm_ready_resp;
always_comb begin
    pm_ready_resp          = '0;
    pm_ready_resp.aw_ready = !pm_bus_stall;
    pm_ready_resp.w_ready  = !pm_bus_stall;
end

// ---------------------------------------------------------------------------
// DUT Instantiation
// ---------------------------------------------------------------------------
for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_dut
    bingo_hw_manager_top #(
        .READY_AND_DONE_QUEUE_INTERFACE_TYPE ( READY_AND_DONE_QUEUE_INTERFACE_TYPE ),
        .TASK_QUEUE_TYPE                     ( TASK_QUEUE_TYPE                     ),
        .WatchdogHeartbeatTimeoutCycles      ( WATCHDOG_HEARTBEAT_TIMEOUT          ),
        .WatchdogConfirmTimeoutCycles        ( WATCHDOG_CONFIRM_TIMEOUT            ),
        .WatchdogCoreMask                    ( `TB_WATCHDOG_CORE_MASK              ),
        .CoreTypeIdWidth                     ( 4                                   ),
        .CoreTypeId                          ( `TB_CORE_TYPE_ID                    ),
        .SubstituteLevelMask                 ( `TB_SUBSTITUTE_LEVEL_MASK           ),
        .SubstituteL2TypeEn                  ( `TB_SUBSTITUTE_L2_TYPE_EN           ),
        .SubstitutePolicy                    ( `TB_SUBSTITUTE_POLICY               ),
        .ForeignStuckDrain                   ( `TB_FOREIGN_STUCK_DRAIN             ),
        .EventLogDepth                       ( `TB_EVLOG_DEPTH                     ),
        .RemoteNumPeers                      ( RL_NUM_PEERS                        ),
        .ImportSubstituteLevelMask           ( `TB_IMPORT_SUBSTITUTE_LEVEL_MASK    ),
        .CsrHeartbeatAddr                    ( `TB_CSR_HEARTBEAT_ADDR              ),
        .NUM_CORES_PER_CLUSTER               ( NUM_CORES_PER_CLUSTER               ),
        .NUM_CLUSTERS_PER_CHIPLET            ( NUM_CLUSTERS_PER_CHIPLET            ),
        .DepTagWidth                         ( DEP_TAG_WIDTH                       ),
        .HostAxiLiteAddrWidth                ( HOST_AW                             ),
        .HostAxiLiteDataWidth                ( HOST_DW                             ),
        .DeviceAxiLiteAddrWidth              ( DEV_AW                              ),
        .DeviceAxiLiteDataWidth              ( DEV_DW                              ),
        .host_axi_lite_req_t                 ( host_req_t                          ),
        .host_axi_lite_resp_t                ( host_resp_t                         ),
        .device_axi_lite_req_t               ( dev_req_t                           ),
        .device_axi_lite_resp_t              ( dev_resp_t                          ),
        .csr_req_t                           ( csr_req_t                           ),
        .csr_rsp_t                           ( csr_rsp_t                           )
    ) i_dut (
        .clk_i                                ( clk_i                                                       ),
        .rst_ni                               ( rst_ni                                                      ),
        .chip_id_i                            ( chip_id[chiplet_idx]                                        ),
        .task_queue_base_addr_i               ( {chip_id[chiplet_idx], TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}  ),
        .task_queue_axi_lite_req_i            ( local_task_queue_req[chiplet_idx]                            ),
        .task_queue_axi_lite_resp_o           ( local_task_queue_resp[chiplet_idx]                           ),
        .task_list_base_addr_i                ( '0                                                          ),
        .num_task_i                           ( '0                                                          ),
        .bingo_hw_manager_start_i             ( '0                                                          ),
        .bingo_hw_manager_reset_start_o       ( /* unused */                                                ),
        .bingo_hw_manager_reset_start_en_o    ( /* unused */                                                ),
        .task_queue_axi_lite_req_o            ( /* unused */                                                ),
        .task_queue_axi_lite_resp_i           ( '0                                                          ),
        .chiplet_mailbox_base_addr_i          ( {chip_id[chiplet_idx], H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
        .to_remote_chiplet_axi_lite_req_o     ( h2h_axi_lite_xbar_in_req[chiplet_idx]                       ),
        .to_remote_chiplet_axi_lite_resp_i    ( h2h_axi_lite_xbar_in_resp[chiplet_idx]                      ),
        .from_remote_axi_lite_req_i           ( h2h_dut_req[chiplet_idx]                                    ),
        .from_remote_axi_lite_resp_o          ( h2h_dut_resp[chiplet_idx]                                   ),
        .done_queue_base_addr_i               ( {chip_id[chiplet_idx], DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}  ),
        .done_queue_axi_lite_req_i            ( local_done_queue_req[chiplet_idx]                            ),
        .done_queue_axi_lite_resp_o           ( local_done_queue_resp[chiplet_idx]                           ),
        .ready_queue_base_addr_i              ( {chip_id[chiplet_idx], READY_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
        .ready_queue_axi_lite_req_i           ( local_ready_queue_req[chiplet_idx]                           ),
        .ready_queue_axi_lite_resp_o          ( local_ready_queue_resp[chiplet_idx]                          ),
        .csr_req_i                            ( csr_req[chiplet_idx]                                        ),
        .csr_req_valid_i                      ( csr_req_valid[chiplet_idx]                                  ),
        .csr_req_ready_o                      ( csr_req_ready[chiplet_idx]                                  ),
        .csr_rsp_o                            ( csr_resp[chiplet_idx]                                       ),
        .csr_rsp_valid_o                      ( csr_resp_valid[chiplet_idx]                                 ),
        .csr_rsp_ready_i                      ( csr_resp_ready[chiplet_idx]                                 ),
        .bingo_hw_manager_enable_idle_pm_i    ( device_axi_lite_data_t'(`TB_PM_ENABLE)                        ),
        .bingo_hw_manager_idle_power_level_i  ( device_axi_lite_data_t'(PM_IDLE_LEVEL)                        ),
        .bingo_hw_manager_normal_power_level_i( device_axi_lite_data_t'(PM_NORMAL_LEVEL)                      ),
        .bingo_hw_manager_boost_power_level_i ( device_axi_lite_data_t'(PM_BOOST_LEVEL)                       ),
        .bingo_hw_manager_boost_policy_i      ( boost_policy[chiplet_idx]                                   ),
        .bingo_hw_manager_idle_entry_delay_i  ( device_axi_lite_data_t'(`TB_PM_IDLE_DELAY)                    ),
        .bingo_hw_manager_cluster_access_i    ( cluster_access[chiplet_idx]                                 ),
        .bingo_hw_manager_access_wake_hold_i  ( device_axi_lite_data_t'(`TB_PM_ACCESS_HOLD)                   ),
        .bingo_hw_manager_recovery_hold_i     ( recovery_hold[chiplet_idx]                                  ),
        .bingo_hw_manager_pm_access_level_i   ( pm_access_level[chiplet_idx]                                ),
        .bingo_hw_manager_park_req_i          ( park_req[chiplet_idx]                                       ),
        .bingo_hw_manager_park_fail_o         ( park_fail[chiplet_idx]                                      ),
        .bingo_hw_manager_risk_late_i         ( risk_late[chiplet_idx]                                      ),
        .bingo_hw_manager_risk_policy_i       ( risk_policy[chiplet_idx]                                    ),
        .bingo_hw_manager_risk_epoch_i        ( risk_epoch[chiplet_idx]                                     ),
        .bingo_hw_manager_risk_clear_i        ( risk_clear[chiplet_idx]                                     ),
        .bingo_hw_manager_risk_confirm_i      ( risk_confirm[chiplet_idx]                                   ),
        .wd_type_h_i                         ( wd_type_h[chiplet_idx]                                      ),
        .wd_type_c_i                         ( wd_type_c[chiplet_idx]                                      ),
        .wd_adapt_i                          ( wd_adapt[chiplet_idx]                                       ),
        .bingo_hw_manager_wd_late_i           ( wd_late[chiplet_idx]                                        ),
        .bingo_hw_manager_risk_o              ( risk[chiplet_idx]                                           ),
        .bingo_hw_manager_pm_base_addr_i      ( '0                                                          ),
        .bingo_hw_manager_core_power_domain_i ( pm_core_domain                                              ),
        .bingo_hw_manager_pm_mode_i           ( '0                                                          ),
        // HeMAiA DVFS_CLINT_MSIP_ADDR CSR reset is 0; pm_mode_i[0]=0 gates the doorbell.
        .bingo_hw_manager_dvfs_clint_msip_addr_i ( '0                                                        ),
        // HeMAiA DVFS_ACK CSR reset is 0; pm_mode_i[0]=0 gates the acknowledged level.
        .bingo_hw_manager_dvfs_ack_i          ( '0                                                          ),
        // Standalone DFS TB does not need the host DVFS request output.
        .bingo_hw_manager_dvfs_request_o      (                                                             ),
        .pm_axi_lite_req_o                    ( /* unused */                                                ),
        .pm_axi_lite_resp_i                   ( pm_ready_resp                                               ),
        // DARTS Tier 1: CERF interface (stimulus files can drive these)
        .cerf_write_en_i                      ( cerf_write_en[chiplet_idx]                                   ),
        .cerf_write_data_i                    ( cerf_write_data[chiplet_idx]                                 ),
        .cerf_state_o                         ( /* read-back, unused in standalone TB */                     ),
        .cerf_fb_en_i                         ( cerf_fb_en[chiplet_idx]                                      ),
        .cerf_fb_clear_i                      ( cerf_fb_clear[chiplet_idx]                                   ),
        .cerf_fb_set_i                        ( cerf_fb_set[chiplet_idx]                                     ),
        .cerf_fb_evt_o                        ( cerf_fb_evt[chiplet_idx]                                     ),
        .evlog_enable_i                      ( `TB_EVLOG_DEPTH != 0                                        ),
        .evlog_clear_i                       ( '0                                                          ),
        .evlog_pop_i                         ( evlog_pop[chiplet_idx]                                      ),
        .evlog_head_o                        ( evlog_head[chiplet_idx]                                     ),
        .evlog_count_o                       ( evlog_count[chiplet_idx]                                    ),
        .evlog_dropped_o                     ( evlog_dropped[chiplet_idx]                                  ),
        // DARTS: Load monitor
        .load_total_pending_o                 ( /* unused */                                                ),
        // Watchdog / replay status (probed hierarchically by the stimuli)
        .core_fenced_o                        ( /* unused */                                                ),
        .replay_stuck_o                       ( /* unused */                                                ),
        // Stimuli probe suspect state hierarchically; no TB output wire is needed.
        .core_dead_suspect_o                  (                                                             ),
        // Stimuli probe blocked state hierarchically; no TB output wire is needed.
        .replay_blocked_o                     (                                                             ),
        // Level 3 remote dispatch (see gen_remote_link)
        .remote_dispatch_valid_o              ( rd_valid[chiplet_idx]                                       ),
        .remote_dispatch_ready_i              ( rd_in_ready[chiplet_idx]                                    ),
        .remote_dispatch_desc_o               ( rd_desc[chiplet_idx]                                        ),
        .remote_dispatch_core_type_o          ( rd_core_type[chiplet_idx]                                   ),
        .remote_dispatch_origin_chip_o        ( rd_origin_chip[chiplet_idx]                                 ),
        .remote_dispatch_proxy_slot_o         ( rd_proxy_slot[chiplet_idx]                                  ),
        .remote_dispatch_valid_i              ( rd_in_valid[chiplet_idx] && !rl_import_hold[chiplet_idx]    ),
        .remote_dispatch_ready_o              ( rd_ready[chiplet_idx]                                       ),
        .remote_dispatch_desc_i               ( rd_in_desc[chiplet_idx]                                     ),
        .remote_dispatch_core_type_i          ( rd_in_core_type[chiplet_idx]                                ),
        .remote_dispatch_origin_chip_i        ( rd_in_origin_chip[chiplet_idx]                              ),
        .remote_dispatch_proxy_slot_i         ( rd_in_proxy_slot[chiplet_idx]                               ),
        .remote_done_valid_o                  ( rdn_valid[chiplet_idx]                                      ),
        .remote_done_ready_i                  ( rdn_in_ready[chiplet_idx]                                   ),
        .remote_done_chip_o                   ( rdn_chip[chiplet_idx]                                       ),
        .remote_done_proxy_slot_o             ( rdn_proxy_slot[chiplet_idx]                                 ),
        .remote_done_task_id_o                ( rdn_task_id[chiplet_idx]                                    ),
        .remote_done_reject_o                 ( rdn_reject[chiplet_idx]                                     ),
        .remote_done_valid_i                  ( rdn_in_valid[chiplet_idx]                                   ),
        .remote_done_ready_o                  ( rdn_ready[chiplet_idx]                                      ),
        .remote_done_proxy_slot_i             ( rdn_in_proxy_slot[chiplet_idx]                              ),
        .remote_done_task_id_i                ( rdn_in_task_id[chiplet_idx]                                 ),
        .remote_done_reject_i                 ( rdn_in_reject[chiplet_idx]                                  ),
        .remote_export_type_en_i              ( remote_type_en[chiplet_idx]                                 ),
        .remote_export_type_peer_i            ( remote_type_peer[chiplet_idx]                               ),
        .remote_export_peer_ready_i           ( remote_peer_ready[chiplet_idx]                              ),
        .remote_proxy_timeout_i               ( device_axi_lite_data_t'(`TB_REMOTE_PROXY_TIMEOUT)          ),
        .remote_timeout_o                     ( remote_timeout[chiplet_idx]                                 ),
        .remote_done_mismatch_o               ( /* probed below */                                          )
    );
    if (`TB_EVLOG_DEPTH != 0) begin : gen_evlog_check
        `include "tb_bingo_evlog_monitor.svh"
    end
    always @(posedge clk_i) begin
        if (rst_ni && (`TB_ALLOW_DONE_MISMATCH == 0) && i_dut.remote_done_mismatch_o) begin
            $error("[REMOTE_LINK] chip %0d: remote done does not match the proxy head", chiplet_idx);
        end
    end
end

// ---------------------------------------------------------------------------
// Remap placement monitor (white-box, always on)
// ---------------------------------------------------------------------------
// A task may only leave its logical core once that core is retired (fenced and
// its outstanding tasks replayed) or PARKED (a host park of a live core).
// With park_req held at 0, park_parked stays 0 and the retired check is the
// one this monitor has always applied. Tasks that never execute on a core
// (dummy-set, CERF-skipped) must never be remapped: they rely on their logical
// core's checkout FIFO order.
for (genvar gi = 0; gi < NUM_CHIPLET; gi++) begin : gen_remap_monitor
    always @(posedge clk_i) begin
        if (rst_ni) begin
            for (int p = 0; p < NUM_CORES_PER_CLUSTER; p++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    if (gen_dut[gi].i_dut.route.fire[p][cl]) begin
                        automatic int src    = gen_dut[gi].i_dut.route.src_core[p][cl];
                        automatic int src_cl = gen_dut[gi].i_dut.waiting_dep_check_task_desc[src].assigned_cluster_id;
                        if ((src != p) || (src_cl != cl)) begin
                            if ((gen_dut[gi].i_dut.core_retired[src][src_cl] !== 1'b1) &&
                                (gen_dut[gi].i_dut.park.parked[src][src_cl] !== 1'b1)) begin
                                $error("[REMAP_CHECK] chip %0d: task %0d of non-retired logical core %0d (cluster %0d) placed on physical core %0d cluster %0d",
                                       gi, gen_dut[gi].i_dut.waiting_dep_check_task_desc[src].task_id, src, src_cl, p, cl);
                            end
                            if (((gen_dut[gi].i_dut.waiting_dep_check_task_desc[src].task_type == 2'b01) &&
                                 gen_dut[gi].i_dut.waiting_dep_check_task_desc[src].dep_set_info.dep_set_en) ||
                                gen_dut[gi].i_dut.cond_exec_skip[src]) begin
                                $error("[REMAP_CHECK] chip %0d: non-executing task %0d of logical core %0d (cluster %0d) remapped to physical core %0d cluster %0d",
                                       gi, gen_dut[gi].i_dut.waiting_dep_check_task_desc[src].task_id, src, src_cl, p, cl);
                            end
                        end
                    end
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Retire scoreboard (white-box, always on)
// ---------------------------------------------------------------------------
// Every task that enters a checkout queue retires exactly once, and the tasks
// of one logical core retire in the order they left its waiting queue. A replay
// move (checkout entry popped to go to another core) is not a retirement.
typedef int unsigned retire_q_t [$];
retire_q_t   retire_expected [NUM_CHIPLET][NUM_CLUSTERS_PER_CHIPLET][NUM_CORES_PER_CLUSTER];
int unsigned retire_count    [NUM_CHIPLET][4096];

for (genvar gi = 0; gi < NUM_CHIPLET; gi++) begin : gen_retire_scoreboard
    initial begin
        for (int t = 0; t < 4096; t++) retire_count[gi][t] = 0;
    end
    always @(posedge clk_i) begin
        if (rst_ni) begin
            // Entries leaving a waiting queue (all but dummy-check tasks reach a checkout queue)
            for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
                if (gen_dut[gi].i_dut.i_dep_unit.waiting_dep_check_queue_pop[core]) begin
                    automatic bingo_hw_manager_task_desc_t d = gen_dut[gi].i_dut.waiting_dep_check_task_desc[core];
                    if (!((d.task_type == 2'b01) && d.dep_check_info.dep_check_en)) begin
                        retire_expected[gi][d.assigned_cluster_id][core].push_back(d.task_id);
                    end
                end
            end
            // Retirements
            for (int p = 0; p < NUM_CORES_PER_CLUSTER; p++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    // (an imported entry is scoreboarded on its origin chiplet)
                    if (gen_dut[gi].i_dut.checkout_queue_pop[p][cl] &&
                        !gen_dut[gi].i_dut.replay_pop[p][cl] &&
                        !gen_dut[gi].i_dut.checkout_head_imported[p][cl]) begin
                        automatic bingo_hw_manager_task_desc_t d = gen_dut[gi].i_dut.checkout_queue_data_out[p][cl];
                        automatic int logical    = d.assigned_core_id;
                        automatic int logical_cl = d.assigned_cluster_id;
                        retire_count[gi][d.task_id]++;
                        if (retire_count[gi][d.task_id] > 1) begin
                            $error("[RETIRE_CHECK] chip %0d: task %0d retired %0d times (core %0d cluster %0d)",
                                   gi, d.task_id, retire_count[gi][d.task_id], p, cl);
                        end
                        // Checked per logical slot: the entry may retire in another cluster
                        if (retire_expected[gi][logical_cl][logical].size() == 0) begin
                            $error("[RETIRE_CHECK] chip %0d: task %0d of logical core %0d cluster %0d retired but never dispatched",
                                   gi, d.task_id, logical, logical_cl);
                        end else if (retire_expected[gi][logical_cl][logical][0] != d.task_id) begin
                            $error("[RETIRE_CHECK] chip %0d: logical core %0d cluster %0d retired task %0d, expected task %0d first",
                                   gi, logical, logical_cl, d.task_id, retire_expected[gi][logical_cl][logical][0]);
                        end else begin
                            void'(retire_expected[gi][logical_cl][logical].pop_front());
                        end
                    end
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Replay event counters (for stimulus checks)
// ---------------------------------------------------------------------------
int unsigned replay_move_count [NUM_CHIPLET];  // checkout entries moved off fenced cores
int unsigned remap_count       [NUM_CHIPLET];  // tasks routed to another physical core
int unsigned fence_drop_count  [NUM_CHIPLET];  // done writes of fenced cores dropped
bit          replay_stuck_seen [NUM_CHIPLET];
bit          dead_suspect_seen [NUM_CHIPLET];

for (genvar gi = 0; gi < NUM_CHIPLET; gi++) begin : gen_replay_counters
    initial begin
        replay_move_count[gi] = 0;
        remap_count[gi]       = 0;
        fence_drop_count[gi]  = 0;
        replay_stuck_seen[gi] = 1'b0;
        dead_suspect_seen[gi] = 1'b0;
    end
    always @(posedge clk_i) begin
        if (rst_ni) begin
            if (gen_dut[gi].i_dut.replay_step.fire) replay_move_count[gi]++;
            if (gen_dut[gi].i_dut.replay_stuck) replay_stuck_seen[gi] = 1'b1;
            if (|gen_dut[gi].i_dut.core_dead_suspect) dead_suspect_seen[gi] = 1'b1;
            for (int p = 0; p < NUM_CORES_PER_CLUSTER; p++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    if (gen_dut[gi].i_dut.route.fire[p][cl] &&
                        ((gen_dut[gi].i_dut.route.src_core[p][cl] != p) ||
                         (gen_dut[gi].i_dut.waiting_dep_check_task_desc[gen_dut[gi].i_dut.route.src_core[p][cl]].assigned_cluster_id != cl))) begin
                        remap_count[gi]++;
                    end
                end
            end
            for (int i = 0; i < NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET; i++) begin
                if (gen_dut[gi].i_dut.gen_csr_to_fifo_intf.i_csr_port.write_done_queue_valid_1d[i] &&
                    gen_dut[gi].i_dut.gen_csr_to_fifo_intf.i_csr_port.core_fenced_1d[i]) begin
                    fence_drop_count[gi]++;
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Replay / remap SVA (white-box, always on)
// ---------------------------------------------------------------------------
// Concurrent properties on the DUT state; the per-task properties (retired
// exactly once, per-logical-core order, none lost) are checked by the retire
// scoreboard above and the final check below.
for (genvar gi = 0; gi < NUM_CHIPLET; gi++) begin : gen_replay_sva
    typedef logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] slot_mask_t;
    slot_mask_t fenced, retired, stuck, hold;
    assign fenced  = gen_dut[gi].i_dut.core_fenced;
    assign retired = gen_dut[gi].i_dut.core_retired;
    assign stuck   = gen_dut[gi].i_dut.replay_stuck_slot;
    assign hold    = gen_dut[gi].i_dut.replay_hold_slot;

    default clocking cb_sva @(posedge clk_i); endclocking
    default disable iff (!rst_ni);

    // fenced / retired / stuck are sticky; retired and stuck imply fenced and
    // exclude each other
    a_fenced_sticky:  assert property (($past(fenced)  & ~fenced)  == '0);
    a_retired_sticky: assert property (($past(retired) & ~retired) == '0);
    a_stuck_sticky:   assert property (($past(stuck)   & ~stuck)   == '0);
    a_retired_fenced: assert property ((retired & ~fenced) == '0);
    a_stuck_fenced:   assert property ((stuck & ~fenced) == '0);
    a_retired_stuck:  assert property ((retired & stuck) == '0);
    // A MOVE step goes from a fenced, unretired slot to a live other slot
    // (level 3: or rotates the source's head)
    a_move_src: assert property (gen_dut[gi].i_dut.replay_step.fire |->
        fenced[gen_dut[gi].i_dut.replay_src_core][gen_dut[gi].i_dut.replay_src_cluster] &&
        !retired[gen_dut[gi].i_dut.replay_src_core][gen_dut[gi].i_dut.replay_src_cluster]);
    a_move_dst: assert property ((gen_dut[gi].i_dut.replay_step.fire && !gen_dut[gi].i_dut.replay_rotate &&
                                  !gen_dut[gi].i_dut.replay_step.bounce) |->
        !fenced[gen_dut[gi].i_dut.replay_step.dst_core][gen_dut[gi].i_dut.replay_step.dst_cluster]);
    // A held (moved / partly moved) slot retires nothing. A stuck or rejected
    // slot only retires a head that runs on no core (a dummy-set, a task
    // skipped at dispatch, or one the CERF skips now), of its own logical core,
    // or (ForeignStuckDrain) of a retired logical core whose every moved entry
    // is in this slot. The harness counts those entries itself (sva_in), from
    // the checkout pushes and pops, independently of the manager's counters.
    int unsigned sva_in [NUM_CORES_PER_CLUSTER][NUM_CLUSTERS_PER_CHIPLET][NUM_CORES_PER_CLUSTER][NUM_CLUSTERS_PER_CHIPLET];
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int p = 0; p < NUM_CORES_PER_CLUSTER; p++)
                for (int pcl = 0; pcl < NUM_CLUSTERS_PER_CHIPLET; pcl++)
                    for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++)
                        for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
                            sva_in[p][pcl][c][cl] <= 0;
        end else begin
            for (int p = 0; p < NUM_CORES_PER_CLUSTER; p++) begin
                for (int pcl = 0; pcl < NUM_CLUSTERS_PER_CHIPLET; pcl++) begin
                    automatic int ic = gen_dut[gi].i_dut.checkout_queue_data_in[p][pcl].assigned_core_id;
                    automatic int icl = gen_dut[gi].i_dut.checkout_queue_data_in[p][pcl].assigned_cluster_id;
                    automatic int oc = gen_dut[gi].i_dut.checkout_queue_data_out[p][pcl].assigned_core_id;
                    automatic int ocl = gen_dut[gi].i_dut.checkout_queue_data_out[p][pcl].assigned_cluster_id;
                    automatic bit in_moved = gen_dut[gi].i_dut.checkout_queue_push[p][pcl] && (ic != p || icl != pcl) &&
                                             ic < NUM_CORES_PER_CLUSTER && icl < NUM_CLUSTERS_PER_CHIPLET;
                    automatic bit out_moved = gen_dut[gi].i_dut.checkout_queue_pop[p][pcl] && (oc != p || ocl != pcl) &&
                                              oc < NUM_CORES_PER_CLUSTER && ocl < NUM_CLUSTERS_PER_CHIPLET;
                    if (in_moved && out_moved && ic == oc && icl == ocl) begin
                        // push and pop of the same logical core: no change
                    end else begin
                        if (in_moved)  sva_in[p][pcl][ic][icl] <= sva_in[p][pcl][ic][icl] + 1;
                        if (out_moved) sva_in[p][pcl][oc][ocl] <= sva_in[p][pcl][oc][ocl] - 1;
                    end
                end
            end
        end
    end
    function automatic bit sva_all_in(int p, int pcl, int x, int xcl);
        for (int q = 0; q < NUM_CORES_PER_CLUSTER; q++)
            for (int qcl = 0; qcl < NUM_CLUSTERS_PER_CHIPLET; qcl++)
                if ((q != p || qcl != pcl) && sva_in[q][qcl][x][xcl] != 0) return 1'b0;
        return 1'b1;
    endfunction
    slot_mask_t stuck_skip_ok;
    always_comb begin
        for (int unsigned c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
            for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                automatic int x = gen_dut[gi].i_dut.checkout_queue_data_out[c][cl].assigned_core_id;
                automatic int xcl = gen_dut[gi].i_dut.checkout_queue_data_out[c][cl].assigned_cluster_id;
                stuck_skip_ok[c][cl] =
                    (((x == c) && (xcl == cl)) ||
                     (gen_dut[gi].i_dut.ForeignStuckDrain && (x < NUM_CORES_PER_CLUSTER) &&
                      (xcl < NUM_CLUSTERS_PER_CHIPLET) && retired[x][xcl] && sva_all_in(c, cl, x, xcl))) &&
                    ((gen_dut[gi].i_dut.checkout_queue_data_out[c][cl].task_type == 2'b01) ||
                     (gen_dut[gi].i_dut.checkout_queue_data_out[c][cl].cond_exec_en &&
                      (gen_dut[gi].i_dut.cerf_state[gen_dut[gi].i_dut.checkout_queue_data_out[c][cl].cond_exec_group_id] ==
                       gen_dut[gi].i_dut.checkout_queue_data_out[c][cl].cond_exec_invert)));
            end
        end
    end
    a_hold_no_retire: assert property (
        (hold & gen_dut[gi].i_dut.checkout_queue_pop & ~gen_dut[gi].i_dut.replay_pop) == '0);
    a_stuck_skip_only: assert property (
        ((stuck | gen_dut[gi].i_dut.remote_rejected_q) & ~stuck_skip_ok &
         gen_dut[gi].i_dut.checkout_queue_pop & ~gen_dut[gi].i_dut.replay_pop) == '0);
    // Replay pushes and routed pushes never meet in one queue
    a_push_excl: assert property ((gen_dut[gi].i_dut.replay_push & gen_dut[gi].i_dut.route.fire) == '0);
    // A fenced slot gets no ready push (it would never run the task)
    a_no_ready_push_fenced: assert property ((fenced & gen_dut[gi].i_dut.ready_queue_push) == '0);

    // Level 3: an exported entry never gets a ready push; an imported one
    // never enters a fenced slot
    a_rotate_self: assert property (gen_dut[gi].i_dut.replay_rotate |->
        ((gen_dut[gi].i_dut.replay_src_core == gen_dut[gi].i_dut.replay_step.dst_core) &&
         (gen_dut[gi].i_dut.replay_src_cluster == gen_dut[gi].i_dut.replay_step.dst_cluster) &&
         !gen_dut[gi].i_dut.replay_step.push_ready));
    a_import_live: assert property ((fenced & gen_dut[gi].i_dut.imported.push) == '0);

    c_fence:       cover property ($rose(|fenced));
    c_rotate:      cover property (gen_dut[gi].i_dut.replay_rotate);
    c_import:      cover property (|gen_dut[gi].i_dut.imported.push);
    // Level 3: only an imported head is bounced (rejected back), and nothing
    // is pushed for it; a rejected proxy slot retires nothing more, except the
    // heads that run on no core (stuck_skip_ok, see a_stuck_skip_only)
    a_bounce_imported: assert property (gen_dut[gi].i_dut.replay_step.bounce |->
        (gen_dut[gi].i_dut.replay_step.fire &&
         gen_dut[gi].i_dut.checkout_head_imported[gen_dut[gi].i_dut.replay_src_core][gen_dut[gi].i_dut.replay_src_cluster] &&
         (gen_dut[gi].i_dut.replay_push == '0)));
    a_rejected_no_retire: assert property (
        (gen_dut[gi].i_dut.remote_rejected_q & ~stuck_skip_ok & gen_dut[gi].i_dut.checkout_retire_valid) == '0);
    a_rejected_fenced: assert property ((gen_dut[gi].i_dut.remote_rejected_q & ~fenced) == '0);
    c_bounce:        cover property (gen_dut[gi].i_dut.replay_step.bounce);
    c_import_reject: cover property (gen_dut[gi].i_dut.imported.reject);
    c_reject_in:     cover property ($rose(|gen_dut[gi].i_dut.remote_rejected_q));
    c_retire:      cover property ($rose(|retired));
    c_stuck:       cover property ($rose(|stuck));
    c_cross_move:  cover property (gen_dut[gi].i_dut.replay_step.fire &&
        (gen_dut[gi].i_dut.replay_src_cluster != gen_dut[gi].i_dut.replay_step.dst_cluster));
    c_move_abort:  cover property ((gen_dut[gi].i_dut.i_replay_ctrl.state_q == 2) &&
                                   (gen_dut[gi].i_dut.i_replay_ctrl.state_d == 0) &&
                                   (|(hold & ~gen_dut[gi].i_dut.replay_step.move)));
end

// ---------------------------------------------------------------------------
// CSR Helper Tasks
// ---------------------------------------------------------------------------
task automatic reset_csr_interface();
    for (int chip = 0; chip < NUM_CHIPLET; chip++) begin
        for (int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin
            for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
                csr_req[chip][core][cluster]        <= '0;
                csr_req_valid[chip][core][cluster]  <= 1'b0;
                csr_resp_ready[chip][core][cluster] <= 1'b0;
            end
        end
    end
    @(posedge clk_i);
endtask

task automatic csr_read(
    input int chip, input int cluster, input int core,
    input device_axi_lite_addr_t addr,
    output device_axi_lite_data_t data
);
    csr_req[chip][core][cluster].addr  <= addr;
    csr_req[chip][core][cluster].write <= 1'b0;
    csr_req[chip][core][cluster].data  <= '0;
    csr_req_valid[chip][core][cluster] <= 1'b1;
    csr_resp_ready[chip][core][cluster] <= 1'b1;

    // Sample ready only after the new request has been visible for a clock
    // edge; right after a previous request, ready still belongs to that one.
    @(posedge clk_i);
    while (csr_req_ready[chip][core][cluster] !== 1'b1) @(posedge clk_i);
    while (csr_resp_valid[chip][core][cluster] !== 1'b1) @(posedge clk_i);

    data = csr_resp[chip][core][cluster].data;
    csr_req_valid[chip][core][cluster]  <= 1'b0;
    csr_resp_ready[chip][core][cluster] <= 1'b0;
endtask

task automatic csr_write(
    input int chip, input int cluster, input int core,
    input device_axi_lite_addr_t addr,
    input device_axi_lite_data_t data
);
    csr_req[chip][core][cluster].addr  <= addr;
    csr_req[chip][core][cluster].write <= 1'b1;
    csr_req[chip][core][cluster].data  <= data;
    csr_req_valid[chip][core][cluster] <= 1'b1;
    csr_resp_ready[chip][core][cluster] <= 1'b0;

    // See csr_read: back-to-back calls must not reuse the previous ready.
    @(posedge clk_i);
    while (csr_req_ready[chip][core][cluster] !== 1'b1) @(posedge clk_i);
    csr_req_valid[chip][core][cluster] <= 1'b0;
endtask

// Report completion of task_id from (chip, cluster, core) through the done CSR.
task automatic csr_done(
    input int chip, input int cluster, input int core,
    input int unsigned task_id
);
    automatic bingo_hw_manager_done_info_full_t info = '0;
    info.task_id             = bingo_hw_manager_task_id_t'(task_id);
    info.assigned_cluster_id = bingo_hw_manager_assigned_cluster_id_t'(cluster);
    info.assigned_core_id    = bingo_hw_manager_assigned_core_id_t'(core);
    csr_write(chip, cluster, core, CSR_DONE, device_axi_lite_data_t'(info));
endtask

// Model a healthy core running a long task: stay busy for `cycles` cycles and
// write the heartbeat CSR every `period` cycles.
task automatic busy_with_heartbeat(
    input int chip, input int cluster, input int core,
    input int unsigned cycles, input int unsigned period,
    input device_axi_lite_addr_t heartbeat_addr = CSR_HEARTBEAT
);
    for (int unsigned t = 0; t < cycles; t += period) begin
        repeat (period) @(posedge clk_i);
        csr_write(chip, cluster, core, heartbeat_addr, device_axi_lite_data_t'(1));
    end
endtask

// ---------------------------------------------------------------------------
// Progress Tracking
// ---------------------------------------------------------------------------
int unsigned completed_task_count = 0;
int unsigned last_progress_count  = 0;
logic [4095:0] task_completed_bitmap = '0;

// Per-chiplet done queue lock (for AXI-Lite mode)
logic [NUM_CHIPLET-1:0] done_queue_lock;

// Fenced / retired slots, for the fault-injecting core worker and the stimuli
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] fenced_export  [NUM_CHIPLET];
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] retired_export [NUM_CHIPLET];
// Level 3 / replay state per chiplet (stimuli index these with variables)
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stuck_slot_export    [NUM_CHIPLET];
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] remote_rejected_export [NUM_CHIPLET];
logic                                                          replay_stuck_export  [NUM_CHIPLET];
logic                                                          import_fire_export   [NUM_CHIPLET];
logic [TaskIdWidth-1:0]                                        import_task_export   [NUM_CHIPLET];
logic                                                          replay_bounce_export [NUM_CHIPLET];
for (genvar gi = 0; gi < NUM_CHIPLET; gi++) begin : gen_fenced_export
    assign fenced_export[gi]  = gen_dut[gi].i_dut.core_fenced;
    assign retired_export[gi] = gen_dut[gi].i_dut.core_retired;
    assign stuck_slot_export[gi]      = gen_dut[gi].i_dut.replay_stuck_slot;
    assign remote_rejected_export[gi] = gen_dut[gi].i_dut.remote_rejected_q;
    assign replay_stuck_export[gi]    = gen_dut[gi].i_dut.replay_stuck;
    assign import_fire_export[gi]     = gen_dut[gi].i_dut.imported.fire;
    assign import_task_export[gi]     = gen_dut[gi].i_dut.imported.desc.task_id;
    assign replay_bounce_export[gi]   = gen_dut[gi].i_dut.replay_step.bounce;
end

// Wait until (chip, cluster, core) is retired: fenced and its outstanding tasks replayed.
task automatic wait_retired(
    input int chip, input int cluster, input int core,
    input int unsigned max_cycles
);
    fork : wait_retired_or_timeout
        begin
            wait (retired_export[chip][core][cluster] === 1'b1);
        end
        begin
            repeat (max_cycles) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "core %0d cluster %0d was not retired within %0d cycles (fenced %0b)",
                   core, cluster, max_cycles, fenced_export[chip][core][cluster]);
        end
    join_any
    disable wait_retired_or_timeout;
endtask

// ---------------------------------------------------------------------------
// Core Worker Task (with structured trace logging)
// ---------------------------------------------------------------------------
task automatic core_worker(
    input chip_id_t chip,
    input int cluster,
    input int core
);
    automatic axi_pkg::resp_t                  resp = '0;
    automatic device_axi_lite_data_t           data = '0;
    automatic device_axi_lite_addr_t           data_addr;
    automatic device_axi_lite_data_t           status = '1;
    automatic device_axi_lite_addr_t           status_addr;
    automatic device_axi_lite_addr_t           done_addr;
    automatic bingo_hw_manager_done_info_full_t done_info = '0;
    automatic device_axi_lite_data_t           done_payload = '0;
    automatic int idx = flat_id(chip, cluster, core);

    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth]   = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth]   = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE
        + device_axi_lite_addr_t'((core + cluster * NUM_CORES_PER_CLUSTER) * READY_QUEUE_STRIDE)
        + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE
        + device_axi_lite_addr_t'((core + cluster * NUM_CORES_PER_CLUSTER) * READY_QUEUE_STRIDE)
        + 32'd8;

    forever begin
        if (READY_AND_DONE_QUEUE_INTERFACE_TYPE == 0) begin
            // AXI Lite mode: poll status, then read
            ready_queue_master[idx].read(status_addr, '0, status, resp);
            repeat (5) @(posedge clk_i);
            if (status[0]) begin
                repeat (10) @(posedge clk_i);
                continue;
            end
            ready_queue_master[idx].read(data_addr, '0, data, resp);
        end else begin
            // CSR mode: blocking read from FIFO
            csr_read(chip, cluster, core, CSR_READY, data);
        end

        // Task dispatched
        $display("[TRACE] %0t,TASK_DISPATCHED,%0d,%0d,%0d,%0d",
                 $time, chip, cluster, core, data[TaskIdWidth-1:0]);

        if ((idx == fault2_core) && (data[TaskIdWidth-1:0] == fault2_task_id[TaskIdWidth-1:0])) begin
            $display("[FAULT] %0t chip %0d cluster %0d core %0d: second fault (hang) on task %0d",
                     $time, chip, cluster, core, fault2_task_id);
            forever @(posedge clk_i);
        end
        if ((idx == FAULT3_CORE) && (data[TaskIdWidth-1:0] == FAULT3_TASK_ID[TaskIdWidth-1:0])) begin
            $display("[FAULT] %0t chip %0d cluster %0d core %0d: third fault (hang) on task %0d",
                     $time, chip, cluster, core, FAULT3_TASK_ID);
            forever @(posedge clk_i);
        end
        if ((idx == fault_core) && (data[TaskIdWidth-1:0] == fault_task_id[TaskIdWidth-1:0])) begin
            $display("[FAULT] %0t chip %0d cluster %0d core %0d: mode %0d on task %0d",
                     $time, chip, cluster, core, fault_mode, fault_task_id);
            if (fault_mode == FAULT_HANG) begin
                forever @(posedge clk_i);
            end else if (fault_mode == FAULT_ZOMBIE) begin
                wait (fenced_export[chip][core][cluster] === 1'b1);
                repeat (`TB_FAULT_ZOMBIE_DELAY) @(posedge clk_i);
                done_info = '0;
                done_info.task_id             = data[TaskIdWidth-1:0];
                done_info.assigned_cluster_id = bingo_hw_manager_assigned_cluster_id_t'(cluster);
                done_info.assigned_core_id    = bingo_hw_manager_assigned_core_id_t'(core);
                $display("[FAULT] %0t zombie core %0d cluster %0d reports done for task %0d",
                         $time, core, cluster, fault_task_id);
                csr_write(chip, cluster, core, CSR_DONE, device_axi_lite_data_t'(done_info));
                // A fenced core never gets another task
                csr_read(chip, cluster, core, CSR_READY, data);
                $error("[FAULT] zombie core %0d cluster %0d received task %0d after being fenced",
                       core, cluster, data[TaskIdWidth-1:0]);
                forever @(posedge clk_i);
            end else begin
                // SLOW: silent (no heartbeat), then continue normally
                repeat (`TB_FAULT_SLOW_CYCLES) @(posedge clk_i);
            end
        end

        // Simulate work with random delay
        repeat ($urandom_range(20, 50)) @(posedge clk_i);

        // Compose done info
        done_info.task_id            = data[TaskIdWidth-1:0];
        done_info.assigned_cluster_id = bingo_hw_manager_assigned_cluster_id_t'(cluster);
        done_info.assigned_core_id    = bingo_hw_manager_assigned_core_id_t'(core);
        done_info.reserved_bits       = '0;
        done_payload = device_axi_lite_data_t'(done_info);

        if (READY_AND_DONE_QUEUE_INTERFACE_TYPE == 0) begin
            wait (!done_queue_lock[chip]);
            done_queue_lock[chip] = 1'b1;
            done_queue_master[chip].write(done_addr, '0, done_payload, {DEV_DW/8{1'b1}}, resp);
            repeat ($urandom_range(20, 50)) @(posedge clk_i);
            done_queue_lock[chip] = 1'b0;
        end else begin
            csr_write(chip, cluster, core, CSR_DONE, done_payload);
            repeat ($urandom_range(10, 20)) @(posedge clk_i);
        end

        // Record completion
        $display("[TRACE] %0t,TASK_DONE,%0d,%0d,%0d,%0d",
                 $time, chip, cluster, core, data[TaskIdWidth-1:0]);
        if (task_completed_bitmap[data[TaskIdWidth-1:0]]) begin
            $error("[TRACE] task %0d completed twice", data[TaskIdWidth-1:0]);
        end
        completed_task_count++;
        task_completed_bitmap[data[TaskIdWidth-1:0]] = 1'b1;
    end
endtask

// ---------------------------------------------------------------------------
// Ready Queue Pollers — fork core_worker for all cores
// ---------------------------------------------------------------------------
initial begin : ready_queue_pollers
    reset_csr_interface();
    wait (rst_ni);
    repeat (5) @(posedge clk_i);
    done_queue_lock = '0;
    if (`TB_DISABLE_CORE_WORKERS == 0) begin
        for (int chip_idx = 0; chip_idx < NUM_CHIPLET; chip_idx++) begin
            for (int cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
                for (int core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
                    fork
                        automatic int c  = chip_idx;
                        automatic int cl = cluster_idx;
                        automatic int co = core_idx;
                        core_worker(c, cl, co);
                    join_none
                end
            end
        end
    end
end
// ---------------------------------------------------------------------------
// Signal export from generate blocks — allows runtime indexing for monitoring
// ---------------------------------------------------------------------------
logic [7:0] dep_counter_state [NUM_CHIPLET][NUM_CLUSTERS_PER_CHIPLET][NUM_CORES_PER_CLUSTER][NUM_CORES_PER_CLUSTER];
logic [NUM_CORES_PER_CLUSTER-1:0] waiting_empty_export [NUM_CHIPLET];
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_empty_export [NUM_CHIPLET];
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_empty_export [NUM_CHIPLET];

for (genvar gi = 0; gi < NUM_CHIPLET; gi++) begin : gen_sig_export
    for (genvar gj = 0; gj < NUM_CLUSTERS_PER_CHIPLET; gj++) begin : gen_cl_export
        for (genvar gr = 0; gr < NUM_CORES_PER_CLUSTER; gr++) begin : gen_row_export
            for (genvar gc = 0; gc < NUM_CORES_PER_CLUSTER; gc++) begin : gen_col_export
                // Probe the presence-bit scoreboard: 1 if any tag is live in
                // the cell (monitor/dump only).
                assign dep_counter_state[gi][gj][gr][gc] =
                    8'(|gen_dut[gi].i_dut.i_dep_unit.gen_dep_matrix[gj].i_dep_matrix.sb_q[gr][gc]);
            end
        end
    end
    assign waiting_empty_export[gi] = gen_dut[gi].i_dut.waiting_dep_check_queue_empty;
    assign ready_empty_export[gi]   = gen_dut[gi].i_dut.ready_queue_empty;
    assign checkout_empty_export[gi] = gen_dut[gi].i_dut.checkout_queue_empty;
end

// ---------------------------------------------------------------------------
// Dependency Matrix Monitor — human-readable dump
// ---------------------------------------------------------------------------
task automatic dump_dep_matrix_state();
    $display("  ===== DEPENDENCY MATRIX STATE (counter-based) =====");
    for (int chip = 0; chip < NUM_CHIPLET; chip++) begin
        for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
            $display("  Chiplet %0d, Cluster %0d:", chip, cl);
            for (int r = 0; r < NUM_CORES_PER_CLUSTER; r++) begin
                $write("    Row %0d (Core %0d): [", r, r);
                for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                    if (c > 0) $write(", ");
                    $write("%0d", dep_counter_state[chip][cl][r][c]);
                end
                $display("]");
            end
        end
    end
endtask

task automatic dump_queue_state();
    $display("  ===== QUEUE STATE =====");
    for (int chip = 0; chip < NUM_CHIPLET; chip++) begin
        $display("  Chiplet %0d:", chip);
        for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
            $display("    Core %0d: waiting_dep_check = %s",
                core,
                waiting_empty_export[chip][core] ? "EMPTY" : "HAS_TASKS");
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                $display("      Cluster %0d: ready_q = %s, checkout_q = %s, fenced = %0b",
                    cl,
                    ready_empty_export[chip][core][cl] ? "EMPTY" : "HAS_TASKS",
                    checkout_empty_export[chip][core][cl] ? "EMPTY" : "HAS_TASKS",
                    fenced_export[chip][core][cl]);
            end
        end
    end
endtask

// ---------------------------------------------------------------------------
// Include stimulus file EARLY — defines EXPECTED_TASK_COUNT, DEADLOCK_THRESHOLD,
// DEP_MATRIX_LOG_INTERVAL, task descriptors, and push sequences.
// ---------------------------------------------------------------------------
`include `TB_STIMULUS_FILE

// ---------------------------------------------------------------------------
// Deadlock Detection Watchdog
// ---------------------------------------------------------------------------
initial begin : deadlock_watchdog
    wait (rst_ni);
    repeat (100) @(posedge clk_i);
    forever begin
        repeat (DEADLOCK_THRESHOLD) @(posedge clk_i);
        if (completed_task_count == EXPECTED_TASK_COUNT) begin
            // Already done, let completion_monitor handle it
            break;
        end
        if (completed_task_count == last_progress_count) begin
            $display("");
            $display("+===============================================+");
            $display("|           DEADLOCK DETECTED                   |");
            $display("+===============================================+");
            $display("  No progress for %0d cycles at time %0t", DEADLOCK_THRESHOLD, $time);
            $display("  Completed: %0d / %0d tasks", completed_task_count, EXPECTED_TASK_COUNT);
            $display("  -----------------------------------------------");
            $display("  Uncompleted tasks:");
            for (int t = 1; t <= EXPECTED_TASK_COUNT; t++)
                if (!task_completed_bitmap[t])
                    $display("    Task %0d: NOT completed", t);
            $display("  -----------------------------------------------");
            dump_dep_matrix_state();
            dump_queue_state();
            $display("+===============================================+");
            $display("|           SIMULATION ABORTED                  |");
            $display("+===============================================+");
            $fatal(1, "Deadlock detected: no progress for %0d cycles", DEADLOCK_THRESHOLD);
        end
        last_progress_count = completed_task_count;
    end
end

// ---------------------------------------------------------------------------
// Completion Monitor
// ---------------------------------------------------------------------------
initial begin : completion_monitor
    wait (completed_task_count == EXPECTED_TASK_COUNT);
    repeat (50) @(posedge clk_i);
    // Level 3: the last remote dones may still be in flight on the link
    for (int unsigned t = 0; t < 10000; t++) begin
        automatic bit drained = 1'b1;
        for (int gi = 0; gi < NUM_CHIPLET; gi++) begin
            if (remote_done_in_count[gi] != remote_export_count[gi]) drained = 1'b0;
        end
        if (drained) break;
        @(posedge clk_i);
    end
    repeat (20) @(posedge clk_i);
    $display("");
    $display("+===============================================+");
    $display("|           SIMULATION PASSED                   |");
    $display("+===============================================+");
    $display("  All %0d tasks completed at time %0t", EXPECTED_TASK_COUNT, $time);
    $display("  -----------------------------------------------");
    $display("  Final dependency matrix state (should be all zeros):");
    dump_dep_matrix_state();
    $finish;
end

// ---------------------------------------------------------------------------
// Periodic Dependency Matrix Snapshot Logger
// ---------------------------------------------------------------------------
initial begin : dep_matrix_periodic_logger
    if (DEP_MATRIX_LOG_INTERVAL > 0) begin
        wait (rst_ni);
        forever begin
            repeat (DEP_MATRIX_LOG_INTERVAL) @(posedge clk_i);
            if (completed_task_count < EXPECTED_TASK_COUNT) begin
                $display("");
                $display("[DEP_MATRIX_SNAPSHOT] t=%0t, completed=%0d/%0d",
                         $time, completed_task_count, EXPECTED_TASK_COUNT);
                dump_dep_matrix_state();
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Stimulus file was included above (before deadlock watchdog)
// ---------------------------------------------------------------------------

// None lost: once all expected tasks completed, every task that entered a
// checkout queue has retired
final begin
    if (completed_task_count == EXPECTED_TASK_COUNT) begin
        for (int gi = 0; gi < NUM_CHIPLET; gi++) begin
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                    if (retire_expected[gi][cl][c].size() != 0) begin
                        $error("[RETIRE_CHECK] chip %0d: logical core %0d cluster %0d never retired tasks %p",
                               gi, c, cl, retire_expected[gi][cl][c]);
                    end
                end
            end
        end
    end
end
