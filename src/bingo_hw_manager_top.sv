// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
`include "bingo_hw_manager/typedef.svh"
module bingo_hw_manager_top #(
    parameter int unsigned READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1, // 1: CSR Req/Resp 0: Default AXi Lite Slave
    parameter int unsigned TASK_QUEUE_TYPE = 1,                     // 1: AXI Lite Master 0: Default AXI Lite Slave
    parameter int unsigned NUM_CORES_PER_CLUSTER = 4,
    parameter int unsigned NUM_CLUSTERS_PER_CHIPLET = 2,
    // Dedicated host DVFS doorbell bit inside the shared CLINT MSIP word. Injected from
    // the HeMAiA level (occamygen hw_manager_ipi_idx) and forwarded to the PM so it is
    // never hardcoded; must match HW_MANAGER_DVFS_MSIP_BIT / occamy_soc.sv ipi_i.
    parameter int unsigned HOST_DVFS_MSIP_BIT = 3,
    parameter int unsigned ChipIdWidth = 8,
    parameter int unsigned TaskIdWidth = 12,
    // Identity-aware dependency tracking (per-edge tags). The mini-compiler's
    // per-edge tags are plumbed to the tagged dep-matrix scoreboard so a
    // consumer drains only ITS producer's increment (no counter-sharing hazard).
    parameter int unsigned DepTagWidth = 4,
    parameter int unsigned WatchdogHeartbeatTimeoutCycles = 100000, // The number of cycles for the watchdog to time out
    // Cycles a busy core may go without heartbeat before it is fenced (confirmed
    // dead, sticky until reset) and its outstanding tasks are replayed on other
    // cores. Must exceed WatchdogHeartbeatTimeoutCycles. 0 disables fencing,
    // replay and remap (detection only). Needs the CSR ready/done interface.
    parameter int unsigned WatchdogConfirmTimeoutCycles = 0,
    // Watchdog enable per (core, cluster) slot. A masked slot is never reported
    // dead_suspect (e.g. a host slot that sends no heartbeats, or a tied-off slot).
    parameter logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] WatchdogCoreMask = '1,
    // Core remap / replay: type id of each (core, cluster) slot, chiplet-wide. Two
    // cores with the same non-zero type can run each other's tasks, also from
    // another cluster (level 2, see SubstituteLevelMask), so one may take over the
    // tasks of the other once that one is fenced; a substitute in the dead core's
    // own cluster is preferred. Give
    // cores whose tasks only work in their own cluster (e.g. operands in local
    // L1 at local addresses) a cleared SubstituteL2TypeEn bit. Type 0: the slot
    // neither hands over its tasks nor takes over others' (e.g. a host slot).
    // Default: all cores of the chiplet are interchangeable.
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter int unsigned WdAdaptTypeBits = 2,
    parameter int unsigned WdClassWidth = 3,
    parameter logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0][CoreTypeIdWidth-1:0] CoreTypeId =
        {(NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET){CoreTypeIdWidth'(1)}},
    // Where a fenced core's tasks (outstanding: replay, new: remap) may go, per
    // level; the lowest enabled level with a live same-type core wins:
    //   [0] level 1: a core of the same cluster
    //   [1] level 2: a core of another cluster of this chiplet
    //   [2] level 3: another chiplet, through the remote dispatch interface
    // Default: level 1 only. Without WatchdogConfirmTimeoutCycles nothing is
    // fenced and this mask has no effect (detection only).
    parameter logic [2:0] SubstituteLevelMask = 3'b001,
    // A cleared bit keeps that core type within its assigned cluster.
    // Same-cluster substitutes remain enabled by SubstituteLevelMask[0].
    parameter logic [2**CoreTypeIdWidth-1:0] SubstituteL2TypeEn = '1,
    // Levels an imported task (level 3, from another chiplet) may use to find a
    // live stand-in for its home slot here (bit 2 is ignored: never re-exported).
    // Default: the local levels of SubstituteLevelMask. Setting it apart from
    // SubstituteLevelMask is a debug / loopback aid: e.g. SubstituteLevelMask =
    // 3'b100 with ImportSubstituteLevelMask = 3'b001 exports every task of a
    // fenced core (force remote) and still lets it run on a same-cluster core
    // when it comes back through a loopback link.
    parameter logic [2:0] ImportSubstituteLevelMask = SubstituteLevelMask & 3'b011,
    // Substitute choice when a core dies (bingo_hw_manager_slot_table): 0 = lowest
    // live core of the type, 1 = least loaded (checkout queue occupancy), both
    // in the logical cluster first. Fixed until that substitute dies.
    parameter int unsigned SubstitutePolicy = 0,
    // A stuck or rejected slot may also drain heads of another logical core
    // that died before it (see stuck_drain): one counter per (slot, logical
    // core) pair. 0 = only its own logical core (no counters).
    parameter bit          ForeignStuckDrain = 1'b1,
    // CSR number of the heartbeat write (see bingo_hw_manager_csr_to_fifo).
    parameter logic [11:0] CsrHeartbeatAddr = 12'h5fd,
    // AXI interface types
    // The task queue holds tasks to be scheduled to the devices
    // Host writes the task queue via 64bit AXI Lite
    parameter int unsigned HostAxiLiteAddrWidth = 48,
    parameter int unsigned HostAxiLiteDataWidth = 64,
    // Device writes the done queue via 32bit AXI Lite
    parameter int unsigned DeviceAxiLiteAddrWidth = 48,
    parameter int unsigned DeviceAxiLiteDataWidth = 32,
    // AXI Lite Interface types for host and device
    parameter type host_axi_lite_req_t = logic,
    parameter type host_axi_lite_resp_t = logic,
    parameter type device_axi_lite_req_t = logic,
    parameter type device_axi_lite_resp_t = logic,
    parameter type csr_req_t = logic,
    parameter type csr_rsp_t = logic,
    // FIFO Depths
    parameter int unsigned TaskQueueDepth = 32,
    parameter int unsigned ChipletDoneQueueDepth = 32,
    parameter int unsigned DoneQueueDepth = 32,
    parameter int unsigned CheckoutQueueDepth = 8,
    parameter int unsigned ReadyQueueDepth = 8,
    // Waiting queue of each core index, shared by the clusters: a task waits
    // there for its dependency check before it is placed on a slot
    parameter int unsigned WaitingQueueDepth = 8,
    parameter int unsigned EventLogDepth = 0,
    parameter int unsigned EventLogAgeWidth = 6,
    // Power-domain counters (bingo_hw_manager_pm_counters, pm_count_o) of the
    // domains PmCountBase .. PmCountBase + PmCountDomains - 1; 0 = none
    parameter int unsigned PmCountBase = 0,
    parameter int unsigned PmCountDomains = 0,
    // Division registers of the clock/reset controller the PM writes (DFS):
    // 0 = the packed ones (the PM writes the 8-byte word of eight domains),
    // 1 = one register per domain and its own valid register (the PM writes
    // only its domain; see bingo_hw_manager_pm DivisionPerDomain)
    parameter bit          PmDivisionPerDomain = 1'b0,
    // Streams of the level 3 transport: BINGO_HW_MANAGER_TYPEDEF_REMOTE_DISPATCH_T
    // (the desc a host_axi_lite_data_t) and _REMOTE_DONE_T (bingo_hw_manager/typedef.svh)
    parameter type         remote_dispatch_t = logic,
    parameter type         remote_done_t = logic,
    // Level 3 export queues: one per peer of the transport (e.g.
    // bingo_hw_manager_remote_link NumPeers), each deep enough for a whole
    // checkout queue, so a peer without credits only holds its own exports
    parameter int unsigned RemoteNumPeers = 1,
    parameter int unsigned RemoteExportFifoDepth = CheckoutQueueDepth + 1,
    // Address Offsets
    parameter int unsigned ReadyQueueAddrOffset = 4096,
    // Dependent parameters, DO NOT OVERRIDE!
    parameter type chip_id_t = logic [ChipIdWidth-1:0],
    parameter type host_axi_lite_addr_t = logic [HostAxiLiteAddrWidth-1:0],
    parameter type host_axi_lite_data_t = logic [HostAxiLiteDataWidth-1:0],
    parameter type device_axi_lite_addr_t = logic [DeviceAxiLiteAddrWidth-1:0],
    parameter type device_axi_lite_data_t = logic [DeviceAxiLiteDataWidth-1:0],
    // One bit per (core, cluster) slot
    parameter type slot_mask_t = logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0],
    // Flat slot id (core + cluster * NUM_CORES_PER_CLUSTER) of the remote interface
    parameter int unsigned RemoteSlotIdWidth = cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET),
    parameter int unsigned RemotePeerIdWidth = (RemoteNumPeers > 1) ? $clog2(RemoteNumPeers) : 1,
    parameter int unsigned PmCountPorts = (PmCountDomains != 0) ? PmCountDomains : 1
) (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,
    /// Chip ID for multi-chip addressing
    input chip_id_t chip_id_i,
    // ==== System bus and core interfaces ==================================
    /// Interface to the system
    // For the task queue, we have two interfaces:
    // 1. Host writes to the task queue via 64bit AXI Lite interface
    // Host -----> Task Queue
    // Here this queue holds all the tasks to be scheduled to the devices
    // Hence this is a slave AXI Lite interface
    input  host_axi_lite_addr_t                 task_queue_base_addr_i,
    input  host_axi_lite_req_t                  task_queue_axi_lite_req_i,
    output host_axi_lite_resp_t                 task_queue_axi_lite_resp_o,
    // 2. The Hw Manager issues the read request to the address specified by the host via the following inputs
    // Hence this is a master AXI Lite interface
    input host_axi_lite_addr_t                  task_list_base_addr_i, // The task list base address specified by the host
    input device_axi_lite_data_t                num_task_i,            // The number of tasks specified by the host
    // Control signals to start the HW Manager (from the reg gen modules)
    input  device_axi_lite_data_t               bingo_hw_manager_start_i,
    output device_axi_lite_data_t               bingo_hw_manager_reset_start_o,
    output logic                                bingo_hw_manager_reset_start_en_o,
    output host_axi_lite_req_t                  task_queue_axi_lite_req_o,
    input  host_axi_lite_resp_t                 task_queue_axi_lite_resp_i,
    /// The chiplet set interface to other chiplets
    // HW Manager -----> Other chiplets
    input  host_axi_lite_addr_t                 chiplet_mailbox_base_addr_i,
    output host_axi_lite_req_t                  to_remote_chiplet_axi_lite_req_o,
    input  host_axi_lite_resp_t                 to_remote_chiplet_axi_lite_resp_i,
    /// The chiplet done interface from other chiplets
    input  host_axi_lite_req_t                  from_remote_axi_lite_req_i,
    output host_axi_lite_resp_t                 from_remote_axi_lite_resp_o,
    /// The done queue interface to the devices
    // Devices -----> Done Queue
    // Here this queue holds all the completed tasks info from the devices
    // The device cores will write completed tasks into this queue via 32bit AXI Lite
    input  device_axi_lite_addr_t               done_queue_base_addr_i,
    input  device_axi_lite_req_t                done_queue_axi_lite_req_i,
    output device_axi_lite_resp_t               done_queue_axi_lite_resp_o,
    /// The ready queue interface to the devices
    // HW scheduler -----> Ready Queue
    // Here the ready queue holds the tasks that are ready to be executed by the devices
    // The device cores will read tasks from this queue via 32bit AXI Lite
    // Each core has its own ready queue interface
    input  device_axi_lite_addr_t               ready_queue_base_addr_i,
    input  device_axi_lite_req_t                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_req_i,
    output device_axi_lite_resp_t               [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_resp_o,
    /// CSR Req/Resp Interface: the cores read the ready queue and write the done queue
    input  csr_req_t                            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_i,
    input  slot_mask_t                                                                                       csr_req_valid_i,
    output slot_mask_t                                                                                       csr_req_ready_o,
    output csr_rsp_t                            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_o,
    output slot_mask_t                                                                                       csr_rsp_valid_o,
    input  slot_mask_t                                                                                       csr_rsp_ready_i,
    // ==== Host configuration (quad periph registers) and its read-back =====
    // Power CSRs
    input  bingo_hw_manager_pkg::pm_csr_t       pm_csr_i = '0,
    // External access wake (bingo_hw_manager_power_view): a request from outside
    // into a cluster's memory this cycle (e.g. the host reading its L1)
    input logic [NUM_CLUSTERS_PER_CHIPLET-1:0]  bingo_hw_manager_cluster_access_i = '0,
    // Core parking (bingo_hw_manager_slot_table). Bit (core + cluster*NUM_CORES) asks
    // that logical slot to drain, then send later executing tasks to a live
    // core of its type. 0 leaves placement unchanged. park_fail_o is sticky for
    // a slot until its request bit drops (no substitute, or the slot runs
    // another slot's tasks, or the substitute died and none was left). Clearing
    // the request of a parked slot moves it back: its new tasks wait until none
    // of its tasks is left on another core, then run on the slot again.
    input  device_axi_lite_data_t               bingo_hw_manager_park_req_i = '0,
    output device_axi_lite_data_t               bingo_hw_manager_park_fail_o,
    // Watchdog and fault precursor CSRs
    input  bingo_hw_manager_pkg::wd_risk_csr_t  wd_risk_csr_i = '0,
    // Fault precursors: uses the park_req bit order; a set bit keeps that slot's
    // late-beat count at 0
    input  device_axi_lite_data_t               bingo_hw_manager_risk_clear_i = '0, 
    // Runtime type thresholds
    input  logic [2**CoreTypeIdWidth-1:0][31:0] wd_type_h_i = '0,
    input  logic [2**CoreTypeIdWidth-1:0][31:0] wd_type_c_i = '0,
    // Compile-time task-time estimates (bingo_hw_manager_wd_est, BINGO_WD_EST,
    // bingo_hw_manager_pkg::wd_est_wr_t): a write pulse stores data [9:0] for
    // core type [19:16], class [14:12]. Until a class is learned, the learned
    // bounds start from its estimate. 0: none.
    input  logic                               wd_est_we_i = 1'b0,
    input  logic [31:0]                        wd_est_data_i = '0,
    output device_axi_lite_data_t               bingo_hw_manager_risk_o,
    input device_axi_lite_addr_t                bingo_hw_manager_pm_base_addr_i,
    input device_axi_lite_data_t                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    bingo_hw_manager_core_power_domain_i,
    // DVFS: CLINT doorbell address and published request
    input  device_axi_lite_addr_t               bingo_hw_manager_dvfs_clint_msip_addr_i,
    output device_axi_lite_data_t               bingo_hw_manager_dvfs_request_o,
    // AXI Lite Master Interface
    output host_axi_lite_req_t                  pm_axi_lite_req_o,
    input  host_axi_lite_resp_t                 pm_axi_lite_resp_i,
    // Conditional execution: CERF (Conditional Execution Register File) interface
    input  logic                                cerf_write_en_i,
    input  logic [31:0]                         cerf_write_data_i,
    output logic [31:0]                         cerf_state_o,
    // Degradation (bingo_hw_manager_cerf_fallback): per core type, once any slot of that
    // type is stuck or rejected, clear one CERF group and set another.
    // Enable 0 leaves the CERF unchanged. evt is sticky until that enable drops.
    input  logic [2**CoreTypeIdWidth-1:0]       cerf_fb_en_i = '0,
    input  logic [2**CoreTypeIdWidth-1:0][4:0]  cerf_fb_clear_i = '0,
    input  logic [2**CoreTypeIdWidth-1:0][4:0]  cerf_fb_set_i = '0,
    output logic [2**CoreTypeIdWidth-1:0]       cerf_fb_evt_o,
    // Fence fallback (bingo_hw_manager_slot_table): per core type, a fenced or parked
    // slot of that type takes no substitute at any level (it is not exported
    // either), so a fence makes it stuck and the degradation above applies.
    // 0 = off. Set it before the first fence or park.
    input  logic [2**CoreTypeIdWidth-1:0]       bingo_hw_manager_fence_fb_i = '0,
    // Substitute choice (bingo_hw_manager_slot_table, bingo_hw_manager_pkg::sub_cfg_t):
    // spare clusters are searched first for a substitute, and a cluster stands
    // in for another only within a shared partition. The default is the choice
    // of before. A change applies to the substitutes chosen after it: set it
    // before the first fence or park. The default is SubCfgDefault written out
    // (not every tool takes a package constant as a port default).
    input  bingo_hw_manager_pkg::sub_cfg_t      sub_cfg_i = {32'h0, 32'hffff_ffff},
    // Observation-only event log
    input  bingo_hw_manager_pkg::evlog_ctrl_t   evlog_ctrl_i = '0,
    output bingo_hw_manager_pkg::evlog_status_t evlog_status_o,
    // Load monitor output (upstream, observation only; CSR readable)
    output logic [10:0]                         load_total_pending_o,
    // Power-domain counters: per counted domain, bingo_hw_manager_pkg PmcIdle .. PmcActive
    output logic [PmCountPorts-1:0][bingo_hw_manager_pkg::PmCounters-1:0][31:0] pm_count_o,
    // ==== Status outputs (quad periph status registers) ====================
    // Watchdog: confirmed dead cores (sticky). The system may reset / isolate them.
    output slot_mask_t                                                                                       core_fenced_o,
    // Replay: a fenced core holds a task that no live core may run (level 3:
    // on this chiplet, or on the remote chiplet that rejected its export)
    output logic                                replay_stuck_o,
    // Sticky no-replay blocks, indexed like core_fenced_o; a subset of stuck.
    output slot_mask_t                                                     replay_blocked_o,
    // Watchdog: busy cores without heartbeat for WatchdogHeartbeatTimeoutCycles
    // (not sticky, cleared by a heartbeat or a done)
    output slot_mask_t                                                                                       core_dead_suspect_o,
    // A ready task waits in the slot's ready queue: lets a reader of the CSR
    // ready queue (which stalls while it is empty) poll without blocking.
    // Always 0 with the AXI-Lite mailbox queues, which have their own status.
    output slot_mask_t                                                                                       ready_queue_pending_o,
    // Sticky bus errors (SLVERR / DECERR) of the manager's AXI-Lite masters:
    // [0] a task descriptor read (the descriptor is dropped and the fetch
    // stops, bingo_hw_manager_task_queue_master), [1] a write of the PM, [2] the
    // DVFS read of the PM (bingo_hw_manager_pm). The chiplet dep-set master
    // gets its B response from the D2D link, which answers every write.
    output logic [2:0]                          bus_error_o,

    // ==== Level 3 remote dispatch ==========================================
    // Level 3 remote dispatch (SubstituteLevelMask[2]; unused and tied off
    // otherwise, all inputs have defaults). valid/ready streams.
    // Export: a task of this chiplet that no live core here may run. Its
    // logical slot (proxy_slot, flat id) stays its proxy until the done returns.
    output logic                                remote_dispatch_valid_o,
    input  logic                                remote_dispatch_ready_i = 1'b0,
    output remote_dispatch_t                    remote_dispatch_o,
    // Import: a task exported by another chiplet, run on a core of the same type here
    input  logic                                remote_dispatch_valid_i = 1'b0,
    output logic                                remote_dispatch_ready_o,
    input  remote_dispatch_t                    remote_dispatch_i = '0,
    // Done of an imported task, to be delivered to chiplet remote_done_o.chip, or
    // a reject: no live core here may run the imported task (none of its type
    // was live on arrival, or its core died and none is left)
    output logic                                remote_done_valid_o,
    input  logic                                remote_done_ready_i = 1'b0,
    output remote_done_t                        remote_done_o,
    // Done of an exported task (from the chiplet that ran it), or its reject: the
    // proxy slot becomes stuck (replay_stuck_o), after the dones that arrived
    // before it retired its earlier entries. Its chip is not read.
    input  logic                                remote_done_valid_i = 1'b0,
    output logic                                remote_done_ready_o,
    input  remote_done_t                        remote_done_i = '0,
    // Core types the transport can export (it has a target chiplet for them),
    // e.g. bingo_hw_manager_remote_link target_valid_o. A fenced core of another
    // type without a local substitute is stuck, as without level 3, instead of
    // waiting forever in an export queue. Default: every type.
    input  logic [2**CoreTypeIdWidth-1:0]       remote_export_type_en_i = '1,
    // Peer (export queue) of each core type, and the peers whose next export
    // the transport takes at once (a free credit), e.g. remote_link
    // target_peer_o / peer_ready_o. Exports only leave a queue whose peer is
    // ready, round robin, so a peer without credits does not hold the others.
    input  logic [2**CoreTypeIdWidth-1:0][RemotePeerIdWidth-1:0] remote_export_type_peer_i = '0,
    input  logic [RemoteNumPeers-1:0]           remote_export_peer_ready_i = '1,
    // Origin side: cycles a proxy slot may wait for the remote done of its
    // exported head before it gives up as on a reject (stops, replay_stuck_o)
    // and sets remote_timeout_o; 0 = wait forever
    input  device_axi_lite_data_t               remote_proxy_timeout_i = '0,
    // Sticky: a proxy slot gave up waiting for a remote done (see above)
    output logic                                remote_timeout_o,
    // Sticky: the done at the head of a proxy slot's done queue does not
    // belong to its exported head task (the slot then stops retiring), or a
    // remote done / reject arrived for a slot that is no proxy (not fenced, or
    // out of range; dropped)
    output logic                                remote_done_mismatch_o
);
    import bingo_hw_manager_pkg::*;
    // --------Type definitions and signal declarations--------------------//
    // Task type (two bits, gating included): values and meaning in bingo_hw_manager_pkg
    typedef logic [1:0]                                  bingo_hw_manager_task_type_t;
    // Task ID
    typedef logic [TaskIdWidth-1:0                     ] bingo_hw_manager_task_id_t;
    // Assigned Chiplet ID
    typedef logic [ChipIdWidth-1:0                     ] bingo_hw_manager_assigned_chiplet_id_t;
    // Assigned Cluster ID
    typedef logic [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_assigned_cluster_id_t;
    // Assigned Core ID
    typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0   ] bingo_hw_manager_assigned_core_id_t;
    // Dependency check info struct
    typedef logic [NUM_CORES_PER_CLUSTER-1:0]            bingo_hw_manager_dep_code_t;
    // Per-edge identity tag. Carried alongside the dep code so
    // it flows through every existing dep_check_info / dep_set_info copy unchanged.
    typedef logic [DepTagWidth-1:0]                      bingo_hw_manager_dep_tag_t;
    typedef struct packed{
        bingo_hw_manager_dep_tag_t                   dep_check_tag;
        bingo_hw_manager_dep_code_t                  dep_check_code;
        logic                                        dep_check_en;
    } bingo_hw_manager_dep_check_info_t;
    // Dependency set info struct
    typedef struct packed{
        bingo_hw_manager_dep_tag_t                   dep_set_tag;
        bingo_hw_manager_dep_code_t                  dep_set_code;
        bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id;
        logic                                        dep_set_all_chiplet;
        logic                                        dep_set_en;
    } bingo_hw_manager_dep_set_info_t;

    // Task info struct (includes the conditional execution fields)
    typedef struct packed{
        logic [WdClassWidth-1:0]                     wd_class;
        logic                                        is_exit;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // Conditional execution (CERF)
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
    } bingo_hw_manager_task_desc_t;

    // The watchdog only sees dispatches (ready queue pops) in the CSR interface mode.
    if ((WatchdogConfirmTimeoutCycles != 0) && (READY_AND_DONE_QUEUE_INTERFACE_TYPE != 1)) begin : gen_replay_intf_check
        initial begin
        $error("WatchdogConfirmTimeoutCycles (task replay) needs READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1 (CSR)");
        $finish;
        end
    end

    // Retain the legacy width/offset of is_exit. Class is optional metadata
    // in the low reserved bits, never an extension of the host descriptor.
    localparam int unsigned WdTaskDescWidth = $bits(bingo_hw_manager_task_desc_t);
    localparam int unsigned TaskDescWidth = WdTaskDescWidth - WdClassWidth;
    localparam int unsigned ReservedBitsForTaskDesc = HostAxiLiteDataWidth - TaskDescWidth;
    localparam bit WdClassAvail = (ReservedBitsForTaskDesc >= WdClassWidth);
    if (TaskDescWidth>HostAxiLiteDataWidth) begin : gen_task_desc_width_check
        initial begin
        $error("Task Descriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", TaskDescWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end

    // Every queue holds at least one entry: a fifo_v3 of depth 0 passes its
    // input straight through, and push, pop and empty could form a loop
    if (TaskQueueDepth < 1 || ChipletDoneQueueDepth < 1 || DoneQueueDepth < 1 ||
        CheckoutQueueDepth < 1 || ReadyQueueDepth < 1 || WaitingQueueDepth < 1 ||
        RemoteExportFifoDepth < 1) begin : gen_queue_depth_check
        initial begin
        $error("Queue depths must be at least 1 (task %0d, chiplet done %0d, done %0d, checkout %0d, ready %0d, waiting %0d, remote export %0d)",
               TaskQueueDepth, ChipletDoneQueueDepth, DoneQueueDepth, CheckoutQueueDepth, ReadyQueueDepth,
               WaitingQueueDepth, RemoteExportFifoDepth);
        $finish;
        end
    end
    // 64bit Task Descriptor with reserved bits
    typedef struct packed{
        logic [ReservedBitsForTaskDesc-1:0]          reserved_bits;
        logic                                        is_exit;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // Conditional execution (CERF)
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
    } bingo_hw_manager_task_desc_full_t;

    function automatic logic [WdClassWidth-1:0] get_class(
        input bingo_hw_manager_task_desc_full_t f);
        return WdClassAvail ? WdClassWidth'(f.reserved_bits) : '0;
    endfunction

    function automatic bingo_hw_manager_task_desc_full_t set_class(
        input bingo_hw_manager_task_desc_full_t f,
        input logic [WdClassWidth-1:0] wd_class);
        bingo_hw_manager_task_desc_full_t result;
        result = f;
        if (WdClassAvail)
            result.reserved_bits =
                ((f.reserved_bits >> WdClassWidth) << WdClassWidth) | wd_class;
        return result;
    endfunction

    if (!WdClassAvail) begin : gen_wd_class
`ifndef SYNTHESIS
        // A7: the watchdog bounds learned per core type and task class
        // (bingo_hw_manager_wd_adapt), which then learn per type only. The
        // text stays: simulation transcripts of such configurations show it.
        initial $info("A7 class unavailable: %0d reserved bits", ReservedBitsForTaskDesc);
`endif
    end
`ifndef SYNTHESIS
    // The counts of bingo_hw_manager_pkg follow from the last item of their enum
    initial begin
        automatic pm_counter_e  pm_counter  = pm_counter_e'(0);
        automatic evlog_group_e evlog_group = evlog_group_e'(0);
        if (pm_counter.num() != PmCounters || evlog_group.num() != EvlogGroups)
            $error("bingo_hw_manager_pkg: PmCounters or EvlogGroups is not the size of its enum");
    end
`endif

    // Level 3 remote dispatch
    localparam bit RemoteEn = SubstituteLevelMask[2];
    if (RemoteEn && (READY_AND_DONE_QUEUE_INTERFACE_TYPE != 1)) begin : gen_remote_intf_check
        initial begin
        $error("SubstituteLevelMask[2] (remote dispatch) needs READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1 (CSR)");
        $finish;
        end
    end
    // bingo_hw_manager_remote_link only carries task_type and task_id of the
    // descriptor and finds them at fixed bit positions (its DescTaskTypeLsb /
    // DescTaskIdLsb defaults): keep them in sync with the layout above
    localparam int unsigned RemoteLinkDescTaskTypeLsb = 7;
    localparam int unsigned RemoteLinkDescTaskIdLsb   = 9;
    if (RemoteEn) begin : gen_remote_desc_check
        initial begin
            automatic bingo_hw_manager_task_desc_full_t probe = '0;
            automatic host_axi_lite_data_t expected = '0;
            probe.task_type = '1;
            probe.task_id   = '1;
            expected[RemoteLinkDescTaskTypeLsb +: 2]         = '1;
            expected[RemoteLinkDescTaskIdLsb +: TaskIdWidth] = '1;
            if (($bits(bingo_hw_manager_task_type_t) != 2) || (host_axi_lite_data_t'(probe) != expected)) begin
                $error("Descriptor layout does not match bingo_hw_manager_remote_link (task_type at %0d, task_id at %0d)",
                       RemoteLinkDescTaskTypeLsb, RemoteLinkDescTaskIdLsb);
                $finish;
            end
        end
    end
    typedef logic [RemoteSlotIdWidth-1:0] remote_slot_t;
    // Side tag of each checkout entry (only stored with RemoteEn)
    typedef struct packed{
        logic                                    exported;    // proxy entry: runs on another chiplet
        logic                                    imported;    // runs here for another chiplet
        bingo_hw_manager_assigned_chiplet_id_t   origin_chip; // imported: origin chiplet
        remote_slot_t                            proxy_slot;  // imported: proxy slot on the origin chiplet
    } remote_tag_t;
    typedef struct packed{
        bingo_hw_manager_task_desc_full_t        desc;
        logic [CoreTypeIdWidth-1:0]              core_type;
        remote_slot_t                            proxy_slot;
    } remote_export_t;

    function automatic bingo_hw_manager_task_desc_full_t desc_to_full(input bingo_hw_manager_task_desc_t d);
        bingo_hw_manager_task_desc_full_t f;
        f = '0;
        f.is_exit             = d.is_exit;
        f.dep_set_info        = d.dep_set_info;
        f.dep_check_info      = d.dep_check_info;
        f.assigned_core_id    = d.assigned_core_id;
        f.assigned_cluster_id = d.assigned_cluster_id;
        f.assigned_chiplet_id = d.assigned_chiplet_id;
        f.task_id             = d.task_id;
        f.task_type           = d.task_type;
        f.cond_exec_en        = d.cond_exec_en;
        f.cond_exec_group_id  = d.cond_exec_group_id;
        f.cond_exec_invert    = d.cond_exec_invert;
        return set_class(f, d.wd_class);
    endfunction

    function automatic bingo_hw_manager_task_desc_t full_to_desc(input bingo_hw_manager_task_desc_full_t f);
        bingo_hw_manager_task_desc_t d;
        d.wd_class            = get_class(f);
        d.is_exit             = f.is_exit;
        d.dep_set_info        = f.dep_set_info;
        d.dep_check_info      = f.dep_check_info;
        d.assigned_core_id    = f.assigned_core_id;
        d.assigned_cluster_id = f.assigned_cluster_id;
        d.assigned_chiplet_id = f.assigned_chiplet_id;
        d.task_id             = f.task_id;
        d.task_type           = f.task_type;
        d.cond_exec_en        = f.cond_exec_en;
        d.cond_exec_group_id  = f.cond_exec_group_id;
        d.cond_exec_invert    = f.cond_exec_invert;
        return d;
    endfunction

    // Done info struct
    typedef struct packed{
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_t;

    localparam int unsigned DoneInfoWidth = $bits(bingo_hw_manager_done_info_t);
    localparam int unsigned ReservedBitsForDoneInfo = DeviceAxiLiteDataWidth - DoneInfoWidth;
    if (DoneInfoWidth>DeviceAxiLiteDataWidth) begin : gen_done_info_width_check
        initial begin
        $error("Done info width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", DoneInfoWidth, DeviceAxiLiteDataWidth);
        $finish;
        end
    end

    typedef struct packed{
        logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_full_t;

    typedef struct packed{
        bingo_hw_manager_task_id_t           task_id;
    } bingo_hw_manager_ready_task_desc_t;
    // Check the width
    localparam int unsigned ReadyTaskDescWidth = $bits(bingo_hw_manager_ready_task_desc_t);
    localparam int unsigned ReservedBitsForReadyTaskDesc = DeviceAxiLiteDataWidth - ReadyTaskDescWidth;
    if (ReadyTaskDescWidth>DeviceAxiLiteDataWidth) begin : gen_ready_task_desc_width_check
        initial begin
        $error("Ready Task Descriptor width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", ReadyTaskDescWidth, DeviceAxiLiteDataWidth);
        $finish;
        end
    end
    typedef struct packed{
        logic [ReservedBitsForReadyTaskDesc-1:0] reserved_bits;
        bingo_hw_manager_task_id_t           task_id;
    } bingo_hw_manager_ready_task_desc_full_t;
    //----- End of Type definitions ------------------------------------//

    //----- Start of Signal declarations -------------------------------//

    /////////////////////////////////////////////////////////
    // Task Queue Signals
    /////////////////////////////////////////////////////////
    // The task queue holds the tasks to be scheduled to the devices
    bingo_hw_manager_task_desc_full_t  cur_task_desc_full;
    bingo_hw_manager_task_desc_t       cur_task_desc;
    logic [HostAxiLiteDataWidth-1:0]   task_queue_mbox_data;
    logic                              task_queue_mbox_empty;
    logic                              task_queue_mbox_pop;
    logic                              fetch_bus_error;   // master mode: a descriptor read failed
    logic [1:0]                        pm_bus_error;

    /////////////////////////////////////////////////////////
    // Dependency sets between chiplets (bingo_hw_manager_chiplet_link)
    /////////////////////////////////////////////////////////
    // The link takes the dep set of a retiring checkout head for another
    // chiplet; the head of the chiplet mailbox (dep sets of other chiplets)
    slot_mask_t                                                     chiplet_set_ready;
    bingo_hw_manager_task_desc_full_t                               remote_set;
    logic                                                           remote_set_valid;
    /////////////////////////////////////////////////////////
    // Dependency unit (bingo_hw_manager_dep_unit)
    /////////////////////////////////////////////////////////
    // The task queue head may enter its waiting queue
    logic                                                           dep_task_ready;
    // The waiting queue head of each core, and the checked heads offered to
    // the placement (bingo_hw_manager_router), per physical cluster
    bingo_hw_manager_task_desc_t [NUM_CORES_PER_CLUSTER-1:0]        waiting_dep_check_task_desc;
    logic                        [NUM_CORES_PER_CLUSTER-1:0]        waiting_dep_check_queue_empty;
    slot_mask_t                                                     dep_offer_valid;
    slot_mask_t                                                     dep_offer_ready;
    // The dependency unit takes the dep set of a retiring checkout head, and
    // the head of the chiplet done mailbox
    slot_mask_t                                                     local_set_ready;
    logic                                                           remote_set_ready;

    //////////////////////
    // Ready queue signals
    //////////////////////
    // Ready task info
    bingo_hw_manager_ready_task_desc_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_data_in;
    slot_mask_t                                                                                       ready_queue_push;
    slot_mask_t                                                                                       ready_queue_full;
    // ready queue data_o/empty_o/pop_i signals are only for CSR interface.
    // HeMAiA occamy_quad_ctrl.sv.tpl reads ready_queue_pop and ready_queue_data_out by name (QUAD_CTRL_BINGO_*): a rename must be made there too
    slot_mask_t                                                                                        ready_queue_pop;
    bingo_hw_manager_ready_task_desc_full_t  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_data_out;
    slot_mask_t                                                                                        ready_queue_empty;

    //////////////////////
    // Checkout queue signals
    //////////////////////
    bingo_hw_manager_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_out;
    bingo_hw_manager_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_in;
    slot_mask_t                                                                              checkout_queue_push;
    slot_mask_t                                                                              checkout_queue_pop;
    slot_mask_t                                                                              checkout_queue_full;
    slot_mask_t                                                                              checkout_queue_empty;
    // Level 3: one spare entry lets a replay rotation (pop + push) run on a full queue
    localparam int unsigned CheckoutFifoDepth = CheckoutQueueDepth + (RemoteEn ? 1 : 0);
    localparam int unsigned CheckoutUsageWidth = (CheckoutFifoDepth > 1) ? $clog2(CheckoutFifoDepth) : 1;
    slot_mask_t                                                                              checkout_queue_full_raw;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0][CheckoutUsageWidth-1:0] checkout_queue_usage;
    remote_tag_t                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_remote_tag_in;
    remote_tag_t                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_remote_tag_out;
    // Checkout head imported from another chiplet: retires into the remote done stream
    slot_mask_t                                                                              checkout_head_imported;
    slot_mask_t                                                                              remote_head_mismatch;
    // The head may retire this cycle (bingo_hw_manager_checkout_queue), and the
    // retiring head offered to the local dependency matrix or to another chiplet
    slot_mask_t                                                                              checkout_retire_valid;
    slot_mask_t                                                                              checkout_local_set_valid;
    slot_mask_t                                                                              checkout_chiplet_set_valid;
    // Level 3 export (origin side)
    slot_mask_t                                                             route_remote_grant;
    logic                                  replay_rotate;
    remote_export_t                        export_in;
    logic                                  export_push;
    // Per core type: its export queue has room
    logic [2**CoreTypeIdWidth-1:0]         export_type_ready;
    // Level 3 import (executor side)
    // Level 3 remote dones
    remote_done_t [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] remote_done_arb_data;
    logic         [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] remote_done_arb_valid;
    logic         [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] remote_done_arb_ready;
    // Level 3 rejects: executor side (one pending reject), origin side (sticky
    // per proxy slot)
    logic                                                              reject_pending;
    slot_mask_t                                                        remote_rejected_q;

    ///////////////////////////////////////
    // Per (Core, Cluster) Done Queue signals
    // Each (core, cluster) pair has its own done queue FIFO.
    // This fully eliminates HOL blocking: completions for different
    // cores AND different clusters drain independently.
    ///////////////////////////////////////
    slot_mask_t                                                                                 done_q_pop;
    slot_mask_t                                                                                 done_q_empty;
    // HeMAiA occamy_quad_ctrl.sv.tpl reads done_q_data_in and done_q_push by name (QUAD_CTRL_BINGO_*): a rename must be made there too
    bingo_hw_manager_done_info_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_data_in;
    slot_mask_t                                                                                 done_q_push;
    ///////////////////////////////////////
    // Conditional execution (CERF): state and per-core conditional skip signals
    logic [31:0] cerf_state;
    assign cerf_state_o = cerf_state;  // read-back for SW
    logic [NUM_CORES_PER_CLUSTER-1:0] cond_exec_skip;

    // CERF: per-core conditional skip evaluation.
    // Only valid when there IS a task being processed (queue not empty).
    // When cond_exec_en==0 (default), this is always 0 regardless of CERF state.
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin: gen_cerf_skip
        logic cerf_group_active_for_core;
        assign cerf_group_active_for_core = cerf_state[waiting_dep_check_task_desc[c].cond_exec_group_id];
        assign cond_exec_skip[c] = !waiting_dep_check_queue_empty[c] &&
                                    waiting_dep_check_task_desc[c].cond_exec_en &&
                                    (waiting_dep_check_task_desc[c].cond_exec_invert ?
                                        cerf_group_active_for_core : !cerf_group_active_for_core);
    end

    // Core status signals
    ///////////////////////////////////////
    slot_mask_t                                                     heartbeat_valid;
    slot_mask_t                                                     core_status_waiting_task;
    slot_mask_t                                                     exited_q;
    // Port structs of slot vectors (bingo_hw_manager/typedef.svh), indexed
    // [core][cluster] like the nets of this module
    `BINGO_HW_MANAGER_TYPEDEF_SLOT_STATE_T(slot_state_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_SMT_T(smt_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
        cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER), cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET))
    `BINGO_HW_MANAGER_TYPEDEF_PARK_T(park_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_CTRL_QUEUE_T(ctrl_queue_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
        CheckoutUsageWidth + 1)
    `BINGO_HW_MANAGER_TYPEDEF_CTRL_HOST_T(ctrl_host_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_CTRL_VIEW_T(ctrl_view_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_TYPE_CFG_T(type_cfg_t, 2**CoreTypeIdWidth)
    `BINGO_HW_MANAGER_TYPEDEF_CERF_FB_T(cerf_fb_t, CoreTypeIdWidth)
    `BINGO_HW_MANAGER_TYPEDEF_WAITING_T(waiting_t, bingo_hw_manager_task_desc_t, NUM_CORES_PER_CLUSTER)
    `BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_T(checkout_t, bingo_hw_manager_task_desc_t, remote_tag_t,
        NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET, CheckoutUsageWidth)
    `BINGO_HW_MANAGER_TYPEDEF_READY_T(ready_t, bingo_hw_manager_ready_task_desc_full_t,
        NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET, WdClassWidth)
    `BINGO_HW_MANAGER_TYPEDEF_SELECT_T(select_t, NUM_CORES_PER_CLUSTER,
        cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER), cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET))
    `BINGO_HW_MANAGER_TYPEDEF_ROUTE_T(route_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
        cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER))
    `BINGO_HW_MANAGER_TYPEDEF_PM_SLOT_T(pm_slot_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_REMAP_REQ_T(remap_req_t, cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER),
                                          cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET))
    `BINGO_HW_MANAGER_TYPEDEF_REMAP_SEL_T(remap_sel_t, cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER),
                                          cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET))
    `BINGO_HW_MANAGER_TYPEDEF_DONE_T(done_t, bingo_hw_manager_done_info_full_t,
        NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_DONE_REMOTE_T(done_remote_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_CSR_DONE_T(csr_done_t, bingo_hw_manager_done_info_full_t)
    `BINGO_HW_MANAGER_TYPEDEF_CORE_STATUS_T(core_status_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_REPLAY_HEAD_T(replay_head_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
        cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER), cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET))
    `BINGO_HW_MANAGER_TYPEDEF_REPLAY_STEP_T(replay_step_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
        cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER), cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET))
    `BINGO_HW_MANAGER_TYPEDEF_REPLAY_SLOT_T(replay_slot_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_REPLAY_L3_T(replay_l3_t, CoreTypeIdWidth)
    `BINGO_HW_MANAGER_TYPEDEF_REPLAY_STATUS_T(replay_status_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_REPLAY_OP_T(replay_op_t, bingo_hw_manager_task_desc_t,
        NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_REMOTE_DISPATCH_T(remote_dispatch_out_t, bingo_hw_manager_task_desc_full_t,
        chip_id_t, remote_slot_t, CoreTypeIdWidth)
    `BINGO_HW_MANAGER_TYPEDEF_REMOTE_DISPATCH_T(remote_dispatch_in_t, bingo_hw_manager_task_desc_t,
        chip_id_t, remote_slot_t, CoreTypeIdWidth)
    `BINGO_HW_MANAGER_TYPEDEF_PROXY_T(proxy_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_IMPORT_T(import_t, bingo_hw_manager_task_desc_t, remote_tag_t,
        NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
        cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER), cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET))
    // ... and of one slot's queues
    `BINGO_HW_MANAGER_TYPEDEF_TASK_PUSH_T(task_push_t, bingo_hw_manager_task_desc_t)
    `BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_ROUTE_T(checkout_route_t, bingo_hw_manager_task_desc_t)
    `BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_REPLAY_T(checkout_replay_t, bingo_hw_manager_task_desc_t, remote_tag_t)
    `BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_IMPORT_T(checkout_import_t, bingo_hw_manager_task_desc_t, remote_tag_t)
    `BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_ENTRY_T(checkout_entry_t, bingo_hw_manager_task_desc_t, remote_tag_t)
    `BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_OCC_T(checkout_occ_t, CheckoutUsageWidth)
    `BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_HEAD_T(checkout_head_t, bingo_hw_manager_task_desc_t, remote_tag_t)
    `BINGO_HW_MANAGER_TYPEDEF_READY_PUSH_T(ready_push_t, bingo_hw_manager_ready_task_desc_full_t)
    `BINGO_HW_MANAGER_TYPEDEF_READY_HEAD_T(ready_head_t, bingo_hw_manager_ready_task_desc_full_t, WdClassWidth)
    // Control plane (bingo_hw_manager_ctrl): what it reads of every slot, and
    // its view of every slot (PM idle, boost, derate, watchdog tick, risk, ...)
    slot_state_t                                                    slot_state;
    ctrl_view_t                                                     ctrl_view;
    // Late beats (bingo_hw_manager_watchdog). HeMAiA occamy_quad_ctrl.sv.tpl reads it by name (QUAD_CTRL_BINGO_*): a rename must be made there too
    slot_mask_t                                                     wd_late;
    logic [31:0][7:0]                                               pm_domain_level;
    // Configuration of the PM from the host (the levels are the low bytes of the
    // CSRs), and the power state and configured levels as the control plane
    // and the power-domain counters read them
    pm_cfg_t                                                        pm_cfg;
    pm_view_t                                                       pm_view;
    assign pm_view = '{enable:       pm_cfg.enable,
                       dvfs:         pm_cfg.dvfs,
                       idle_level:   pm_cfg.idle_level,
                       normal_level: pm_cfg.normal_level,
                       boost_level:  pm_cfg.boost_level,
                       dvfs_level:   pm_cfg.dvfs_level,
                       domain_level: pm_domain_level};
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0][5:0] ctrl_slot_domain;
    // Power domain of each slot (PmMaxDomains: none), decoded once for the PM,
    // the control plane and the power-domain counters
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin : gen_slot_domain_core
        for (genvar cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin : gen_slot_domain_cluster
            assign ctrl_slot_domain[c][cl] = (bingo_hw_manager_core_power_domain_i[c][cl] < PmMaxDomains) ?
                6'(bingo_hw_manager_core_power_domain_i[c][cl]) : 6'(PmMaxDomains);
        end
    end
    logic [31:0] pm_access_level;
    // Validate all 32 bits before the PM narrows the divider to eight bits.
    assign pm_access_level =
        (pm_csr_i.access_level > 32'(pm_csr_i.normal_level[7:0]) &&
         pm_csr_i.access_level < 32'(pm_csr_i.idle_level[7:0])) ?
        pm_csr_i.access_level : 32'd0;
    assign pm_cfg = '{enable:       pm_csr_i.enable_idle_pm[0],
                      dvfs:         pm_csr_i.pm_mode[0],
                      idle_level:   pm_csr_i.idle_level[7:0],
                      normal_level: pm_csr_i.normal_level[7:0],
                      access_level: pm_access_level[7:0],
                      boost_level:  pm_csr_i.boost_level[7:0],
                      derate_level: wd_risk_csr_i.risk_policy.derate_level,
                      dvfs_level:   pm_csr_i.dvfs_ack[7:0]};
    slot_mask_t                                                     core_available;
    slot_mask_t                                                     core_dead_suspect;
    // Confirmed dead (sticky): the slot's ready reads, dones and heartbeats are ignored.
    // HeMAiA occamy_quad_ctrl.sv.tpl reads it by name (QUAD_CTRL_BINGO_*): a rename must be made there too
    slot_mask_t                                                     core_fenced;
    // Fenced and all its outstanding tasks moved to other cores (sticky)
    slot_mask_t                                                     core_retired;
    // Checkout queue head executes on a core (normal / gating): retires with its done
    slot_mask_t                                                     checkout_head_exec;
    // Stuck or rejected slot whose head may still retire without running: its
    // own logical core, nothing of that core elsewhere, not imported
    slot_mask_t                                                     stuck_drain;
    // ... and the head is a task the current CERF skips (retires as skipped)
    slot_mask_t                                                     stuck_head_skip;

    // Replay (see bingo_hw_manager_replay_ctrl)
    logic                                replay_pending;      // a slot is fenced, neither retired nor stuck
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0] replay_move_cluster; // a MOVE step may push into the cluster
    slot_mask_t                                                     replay_ready_flush;
    // Checkout output held by the replay controller (being moved or partly moved)
    slot_mask_t                                                     replay_hold_slot;
    slot_mask_t                                                     replay_pop;
    slot_mask_t                                                     replay_push;
    slot_mask_t                                                     replay_push_ready;
    // The checkout heads as the replay controller sees them (bingo_hw_manager_replay_path)
    replay_head_t                          replay_head;
    // One MOVE step of the replay controller
    replay_step_t                          replay_step;
    logic                                  replay_exit_absorb;
    smt_t                                  smt;
    slot_mask_t                                                     exit_absorb;
    bingo_hw_manager_assigned_core_id_t    replay_src_core;
    bingo_hw_manager_assigned_cluster_id_t replay_src_cluster;
    // Fenced slot that no live core can take over (sticky); replay_stuck: any
    slot_mask_t                                                     replay_stuck_slot;
    logic                                  replay_stuck;
    bingo_hw_manager_task_desc_t           replay_data;
    // Fenced slots whose first executing entry was moved (for top_assert)
    slot_mask_t                                                     replay_exec_moved;

    // Placement of the waiting queue heads (bingo_hw_manager_router): per
    // logical core its physical slot, per physical slot the routed task
    select_t                               remap_select;
    route_t                                route;

    // Number of tasks of logical core [core] (cluster [cluster]) that were remapped
    // to another physical core and are still in that core's checkout queue.
    localparam int unsigned RemapOutstandingWidth =
        $clog2(NUM_CORES_PER_CLUSTER * CheckoutQueueDepth + 1);
    logic [RemapOutstandingWidth-1:0] remap_outstanding_q [NUM_CORES_PER_CLUSTER][NUM_CLUSTERS_PER_CHIPLET];
    // Of those, the ones in the checkout queue of physical slot [p][pcl]:
    // moved_in_q[p][pcl][core][cluster] (ForeignStuckDrain only)
    logic [RemapOutstandingWidth-1:0] moved_in_q [NUM_CORES_PER_CLUSTER][NUM_CLUSTERS_PER_CHIPLET][NUM_CORES_PER_CLUSTER][NUM_CLUSTERS_PER_CHIPLET];

    // Watchdog counter wide enough for the configured timeouts (saturating timer).
    localparam int unsigned WatchdogMaxTimeoutCycles =
        (WatchdogConfirmTimeoutCycles > WatchdogHeartbeatTimeoutCycles) ?
        WatchdogConfirmTimeoutCycles : WatchdogHeartbeatTimeoutCycles;
    localparam int unsigned WatchdogCounterWidth = $clog2(WatchdogMaxTimeoutCycles + 1) + 1;
    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(wd_event_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(wd_task_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET, WdClassWidth)
    `BINGO_HW_MANAGER_TYPEDEF_WD_LEARNED_T(wd_learned_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(wd_est_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET)
    `BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(wd_bound_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
                                         WatchdogCounterWidth, WdClassWidth)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(wd_status_t, NUM_CORES_PER_CLUSTER, NUM_CLUSTERS_PER_CHIPLET,
                                          WatchdogCounterWidth)
    // What the watchdog times, its thresholds (bingo_hw_manager_wd_bounds) and what it reports
    wd_event_t   wd_event;
    wd_bound_t   wd_bound;
    wd_status_t  wd_status;
    // The bounds learned by bingo_hw_manager_wd_adapt
    wd_task_t    wd_task;
    wd_learned_t wd_learned;
    // The compile-time estimate of each slot's task (bingo_hw_manager_wd_est)
    wd_est_t     wd_est;
    // The total-time budget of each slot (bingo_hw_manager_wd_budget): a fence
    // request for the watchdog and a late beat for the fault precursors
    slot_mask_t                                                     wd_budget_fence, wd_budget_late;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0][WdClassWidth-1:0] wd_class_q, ready_class;
    slot_mask_t                                                     wd_moved_q, ready_moved;
    // The waiting queue heads, and the checkout, ready and done queues of every slot
    waiting_t  waiting_heads;
    checkout_t checkout_queue;
    ready_t    ready_queue;
    done_t     done_queue;
    assign waiting_heads  = '{desc:  waiting_dep_check_task_desc,
                              empty: waiting_dep_check_queue_empty,
                              skip:  cond_exec_skip};
    assign checkout_queue = '{push:          checkout_queue_push,
                              push_desc:     checkout_queue_data_in,
                              push_tag:      checkout_remote_tag_in,
                              exit_absorb:   exit_absorb,
                              pop:           checkout_queue_pop,
                              full:          checkout_queue_full,
                              full_raw:      checkout_queue_full_raw,
                              usage:         checkout_queue_usage,
                              empty:         checkout_queue_empty,
                              head:          checkout_queue_data_out,
                              head_tag:      checkout_remote_tag_out,
                              head_imported: checkout_head_imported,
                              head_exec:     checkout_head_exec};
    assign ready_queue    = '{push:      ready_queue_push,
                              push_data: ready_queue_data_in,
                              full:      ready_queue_full,
                              empty:     ready_queue_empty,
                              pop:       ready_queue_pop,
                              data:      ready_queue_data_out,
                              wd_class:  ready_class,
                              moved:     ready_moved};
    // The done queues drive done_queue; the nets of each field keep their names
    assign done_q_push    = done_queue.push;
    assign done_q_data_in = done_queue.push_data;
    assign done_q_empty   = done_queue.empty;
    // Level 3: what the remote dones and rejects of exported tasks do to the
    // done queues
    done_remote_t done_remote;
    // Level 3, executor side: the import taken this cycle (bingo_hw_manager_remote_import)
    import_t      imported;
    // --------Finish Type definitions and signal declarations--------------------//

    // --------Module initializations---------------------------------------------//
    // Sections: task queue, dependency sets between chiplets, dependency unit,
    // ready, checkout and done queues, power manager, watchdog, control plane,
    // task replay, placement of new tasks, level 3, event log and assertions,
    // load monitor, CERF. Not quite the data flow (placement comes after the
    // queues it fills): the instances keep their order, since the order of
    // simulation prints within one time step follows it.

    //////////////////////////////////////////////////////////////////////
    // Task Queue
    /////////////////////////////////////////////////////////////////////
    if (TASK_QUEUE_TYPE == 0 ) begin : gen_bingo_hw_manager_task_queue_default_slave
        // Default AXI Lite Slave Task Queue
        bingo_hw_manager_write_mailbox #(
            .MailboxDepth(TaskQueueDepth               ),
            .IrqEdgeTrig (1'b0                         ),
            .IrqActHigh  (1'b1                         ),
            .AxiAddrWidth(HostAxiLiteAddrWidth         ),
            .AxiDataWidth(HostAxiLiteDataWidth         ),
            .ChipIdWidth (ChipIdWidth                  ),
            .req_lite_t  (host_axi_lite_req_t          ),
            .resp_lite_t (host_axi_lite_resp_t         )
        ) i_bingo_hw_manager_task_queue_slave (
            .clk_i       (clk_i                     ),
            .rst_ni      (rst_ni                    ),
            .chip_id_i   (chip_id_i                 ),
            .test_i      (1'b0                      ),
            .req_i       (task_queue_axi_lite_req_i ),
            .resp_o      (task_queue_axi_lite_resp_o),
            .irq_o       (/*not used*/              ),
            .base_addr_i (task_queue_base_addr_i    ),
            .mbox_data_o (task_queue_mbox_data      ),
            .mbox_pop_i  (task_queue_mbox_pop       ),
            .mbox_empty_o(task_queue_mbox_empty     ),
            .mbox_flush_i('0                        )
        );
        // Tie off the unused master interface signals
        assign task_queue_axi_lite_req_o = '0;
        assign bingo_hw_manager_reset_start_o    = '0;
        assign bingo_hw_manager_reset_start_en_o = 1'b0;
        assign fetch_bus_error                   = 1'b0;
    end
    else begin : gen_bingo_hw_manager_task_queue_master
        // AXI Lite Master Task Queue
        // The Hw Manager issues the read request to the address specified by the host via the following inputs
        // Hence this is a master AXI Lite interface
        bingo_hw_manager_task_queue_master #(
            .TaskQueueDepth               (TaskQueueDepth               ),
            .TaskIdWidth                  (TaskIdWidth                  ),
            .req_lite_t                   (host_axi_lite_req_t          ),
            .resp_lite_t                  (host_axi_lite_resp_t         ),
            .addr_t                       (host_axi_lite_addr_t         ),
            .data_t                       (host_axi_lite_data_t         )
        ) i_bingo_hw_manager_task_queue_master (
            .clk_i                     (clk_i                                ),
            .rst_ni                    (rst_ni                               ),
            .task_list_base_addr_i     (task_list_base_addr_i                ),
            .num_task_i                (num_task_i                           ),
            .start_i                   (bingo_hw_manager_start_i             ),
            .reset_start_o             (bingo_hw_manager_reset_start_o       ),
            .reset_start_en_o          (bingo_hw_manager_reset_start_en_o    ),
            .task_queue_axi_lite_req_o (task_queue_axi_lite_req_o            ),
            .task_queue_axi_lite_resp_i(task_queue_axi_lite_resp_i           ),
            .task_queue_data_o         (task_queue_mbox_data                 ),
            .task_queue_pop_i          (task_queue_mbox_pop                  ),
            .task_queue_empty_o        (task_queue_mbox_empty                ),
            .bus_error_o               (fetch_bus_error                      )
        );
        // Tie off the unused slave interface signals
        assign task_queue_axi_lite_resp_o = '0;
    end
    // The task queue head enters the dependency unit
    assign task_queue_mbox_pop = dep_task_ready && !task_queue_mbox_empty;
    assign cur_task_desc_full = bingo_hw_manager_task_desc_full_t'(task_queue_mbox_data);
    assign cur_task_desc = full_to_desc(cur_task_desc_full);

    //////////////////////////////////////////////////////////////////////
    // Dependency sets between chiplets: out, the retiring checkout heads whose
    // dep set names another chiplet; in, the chiplet mailbox
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_chiplet_link #(
        .NumCores             ( NUM_CORES_PER_CLUSTER             ),
        .NumClusters          ( NUM_CLUSTERS_PER_CHIPLET          ),
        .ChipIdWidth          ( ChipIdWidth                       ),
        .HostAxiLiteAddrWidth ( HostAxiLiteAddrWidth              ),
        .HostAxiLiteDataWidth ( HostAxiLiteDataWidth              ),
        .MailboxDepth         ( ChipletDoneQueueDepth             ),
        .host_axi_lite_req_t  ( host_axi_lite_req_t               ),
        .host_axi_lite_resp_t ( host_axi_lite_resp_t              ),
        .task_desc_t          ( bingo_hw_manager_task_desc_t      ),
        .task_desc_full_t     ( bingo_hw_manager_task_desc_full_t )
    ) i_chiplet_link (
        .clk_i                       ( clk_i                             ),
        .rst_ni                      ( rst_ni                            ),
        .chip_id_i                   ( chip_id_i                         ),
        .mailbox_base_addr_i         ( chiplet_mailbox_base_addr_i       ),
        .set_i                       ( checkout_queue_data_out           ),
        .set_valid_i                 ( checkout_chiplet_set_valid        ),
        .set_ready_o                 ( chiplet_set_ready                 ),
        .to_remote_axi_lite_req_o    ( to_remote_chiplet_axi_lite_req_o  ),
        .to_remote_axi_lite_resp_i   ( to_remote_chiplet_axi_lite_resp_i ),
        .from_remote_axi_lite_req_i  ( from_remote_axi_lite_req_i        ),
        .from_remote_axi_lite_resp_o ( from_remote_axi_lite_resp_o       ),
        .remote_set_o                ( remote_set                        ),
        .remote_set_valid_o          ( remote_set_valid                  ),
        .remote_set_ready_i          ( remote_set_ready                  )
    );

    //////////////////////////////////////////////////////////////////////
    // Dependency unit: the waiting queue of each core, the dependency check
    // of its head, the dependency matrices and the dependency sets into them
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_dep_unit #(
        .NumCores          ( NUM_CORES_PER_CLUSTER             ),
        .NumClusters       ( NUM_CLUSTERS_PER_CHIPLET          ),
        .WaitingQueueDepth ( WaitingQueueDepth                 ),
        .DepTagWidth       ( DepTagWidth                       ),
        .task_desc_t       ( bingo_hw_manager_task_desc_t      ),
        .remote_desc_t     ( bingo_hw_manager_task_desc_full_t )
    ) i_dep_unit (
        .clk_i              ( clk_i                            ),
        .rst_ni             ( rst_ni                           ),
        .task_i             ( cur_task_desc                    ),
        .task_valid_i       ( !task_queue_mbox_empty           ),
        .task_ready_o       ( dep_task_ready                   ),
        .head_o             ( waiting_dep_check_task_desc      ),
        .head_empty_o       ( waiting_dep_check_queue_empty    ),
        // Physical cluster: the logical one unless the task goes to a substitute
        .offer_cluster_i    ( remap_select.cluster             ),
        .offer_valid_o      ( dep_offer_valid                  ),
        .offer_ready_i      ( dep_offer_ready                  ),
        .set_i              ( checkout_queue_data_out          ),
        .set_valid_i        ( checkout_local_set_valid         ),
        .set_ready_o        ( local_set_ready                  ),
        .remote_set_i       ( remote_set                       ),
        .remote_set_valid_i ( remote_set_valid                 ),
        .remote_set_ready_o ( remote_set_ready                 )
    );

    //////////////////////////////////////////////////////////////////////
    // Ready Queue
    //////////////////////////////////////////////////////////////////////
    // A task routed to a slot enters its checkout queue and, if it runs on a
    // core (route.ready_push, see bingo_hw_manager_router), its ready queue
    // (bingo_hw_manager_ready_queue), where the core reads its id.
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_ready_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_ready_queue_per_core_per_cluster
            task_push_t  route_in, replay_in, import_in;
            ready_push_t push;
            ready_head_t head;
            assign route_in  = '{valid: route.ready_push[core][cluster],
                                 desc:  waiting_dep_check_task_desc[route.src_core[core][cluster]]};
            assign replay_in = '{valid: replay_push_ready[core][cluster], desc: replay_data};
            assign import_in = '{valid: imported.push[core][cluster], desc: imported.desc};
            bingo_hw_manager_ready_queue #(
                .InterfaceType ( READY_AND_DONE_QUEUE_INTERFACE_TYPE     ),
                .Core          ( core                                    ),
                .Cluster       ( cluster                                 ),
                .Depth         ( ReadyQueueDepth                         ),
                .WdClassWidth  ( WdClassWidth                            ),
                .ChipIdWidth   ( ChipIdWidth                             ),
                .CoreIdWidth   ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
                .ClusterIdWidth( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
                .AxiAddrWidth  ( DeviceAxiLiteAddrWidth                  ),
                .AxiDataWidth  ( DeviceAxiLiteDataWidth                  ),
                .task_desc_t   ( bingo_hw_manager_task_desc_t            ),
                .ready_desc_t  ( bingo_hw_manager_ready_task_desc_full_t ),
                .req_lite_t    ( device_axi_lite_req_t                   ),
                .resp_lite_t   ( device_axi_lite_resp_t                  ),
                .addr_t        ( device_axi_lite_addr_t                  ),
                .task_push_t   ( task_push_t                             ),
                .ready_push_t  ( ready_push_t                            ),
                .ready_head_t  ( ready_head_t                            )
            ) i_ready (
                .clk_i           ( clk_i                                                           ),
                .rst_ni          ( rst_ni                                                          ),
                .chip_id_i       ( chip_id_i                                                       ),
                .route_i         ( route_in                                                        ),
                .replay_i        ( replay_in                                                       ),
                .import_i        ( import_in                                                       ),
                .push_o          ( push                                                            ),
                .full_o          ( ready_queue_full[core][cluster]                                 ),
                .flush_i         ( replay_ready_flush[core][cluster]                               ),
                .pop_i           ( ready_queue_pop[core][cluster]                                  ),
                .head_o          ( head                                                            ),
                .base_addr_i     ( ready_queue_base_addr_i +
                                   (core + cluster * NUM_CORES_PER_CLUSTER) * ReadyQueueAddrOffset ),
                .axi_lite_req_i  ( ready_queue_axi_lite_req_i[core][cluster]                       ),
                .axi_lite_resp_o ( ready_queue_axi_lite_resp_o[core][cluster]                      )
            );
            assign ready_queue_push[core][cluster]     = push.valid;
            assign ready_queue_data_in[core][cluster]  = push.data;
            assign ready_queue_empty[core][cluster]    = head.empty;
            assign ready_queue_data_out[core][cluster] = head.data;
            assign ready_class[core][cluster]          = head.wd_class;
            assign ready_moved[core][cluster]          = head.moved;
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Checkout Queue
    //////////////////////////////////////////////////////////////////////
    // Every task placed on a physical slot waits in its checkout queue until it
    // retires (see bingo_hw_manager_checkout_queue): with its own done if it ran
    // on a core, at once if it runs on no core, never from a stuck slot unless
    // it runs on no core. The retiring head sets its dependencies here or on
    // another chiplet; an imported head goes back to its origin instead.
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_checkout_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_checkout_queue_per_core_per_cluster
            localparam int unsigned Slot = core + cluster * NUM_CORES_PER_CLUSTER;
            checkout_route_t  route_in;
            checkout_replay_t replay_in;
            checkout_import_t import_in;
            checkout_entry_t  push;
            checkout_occ_t    occ;
            checkout_head_t   head;
            retire_req_t      retire;
            retire_rsp_t      retire_rsp;
            assign route_in  = '{valid:       route.fire[core][cluster],
                                 desc:        waiting_dep_check_task_desc[route.src_core[core][cluster]],
                                 skip:        cond_exec_skip[route.src_core[core][cluster]],
                                 exit_absorb: route.exit_absorb[core][cluster],
                                 remote:      route.remote[core][cluster]};
            assign replay_in = '{push:        replay_push[core][cluster],
                                 desc:        replay_data,
                                 tag:         checkout_remote_tag_out[replay_src_core][replay_src_cluster],
                                 rotate:      replay_rotate,
                                 exit_absorb: replay_exit_absorb,
                                 pop:         replay_pop[core][cluster],
                                 hold:        replay_hold_slot[core][cluster]};
            assign import_in = '{valid: imported.push[core][cluster], desc: imported.desc, tag: imported.tag};
            assign retire_rsp = '{local_set:   local_set_ready[core][cluster],
                                  chiplet_set: chiplet_set_ready[core][cluster],
                                  remote_done: remote_done_arb_ready[Slot]};
            bingo_hw_manager_checkout_queue #(
                .NumCores          ( NUM_CORES_PER_CLUSTER                            ),
                .NumClusters       ( NUM_CLUSTERS_PER_CHIPLET                         ),
                .Core              ( core                                             ),
                .Cluster           ( cluster                                          ),
                .Depth             ( CheckoutQueueDepth                               ),
                .TaskIdWidth       ( TaskIdWidth                                      ),
                .CoreIdWidth       ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
                .ClusterIdWidth    ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
                .RemoteEn          ( RemoteEn                                         ),
                .ForeignStuckDrain ( ForeignStuckDrain                                ),
                .OutstandingWidth  ( RemapOutstandingWidth                            ),
                .task_desc_t       ( bingo_hw_manager_task_desc_t                     ),
                .remote_tag_t      ( remote_tag_t                                     ),
                .chip_id_t         ( chip_id_t                                        ),
                .checkout_route_t  ( checkout_route_t                                 ),
                .checkout_replay_t ( checkout_replay_t                                ),
                .checkout_import_t ( checkout_import_t                                ),
                .checkout_entry_t  ( checkout_entry_t                                 ),
                .checkout_occ_t    ( checkout_occ_t                                   ),
                .checkout_head_t   ( checkout_head_t                                  ),
                .slot_state_t      ( slot_state_t                                     ),
                .done_t            ( done_t                                           )
            ) i_checkout (
                .clk_i             ( clk_i                                          ),
                .rst_ni            ( rst_ni                                         ),
                .chip_id_i         ( chip_id_i                                      ),
                .replay_i          ( replay_in                                      ),
                .import_i          ( import_in                                      ),
                .route_i           ( route_in                                       ),
                .push_o            ( push                                           ),
                .pop_o             ( checkout_queue_pop[core][cluster]              ),
                .occ_o             ( occ                                            ),
                .head_o            ( head                                           ),
                .slot_i            ( slot_state                                     ),
                .cerf_state_i      ( cerf_state                                     ),
                .outstanding_i     ( remap_outstanding_q                            ),
                .moved_in_i        ( moved_in_q[core][cluster]                      ),
                .stuck_drain_o     ( stuck_drain[core][cluster]                     ),
                .stuck_head_skip_o ( stuck_head_skip[core][cluster]                 ),
                .done_i            ( done_queue                                     ),
                .done_pop_o        ( done_q_pop[core][cluster]                      ),
                .remote_mismatch_o ( remote_head_mismatch[core][cluster]            ),
                .retire_o          ( retire                                         ),
                .retire_i          ( retire_rsp                                     )
            );
            assign checkout_queue_push[core][cluster]         = push.valid;
            assign checkout_queue_data_in[core][cluster]      = push.desc;
            assign checkout_remote_tag_in[core][cluster]      = push.tag;
            assign exit_absorb[core][cluster]                 = push.exit_absorb;
            assign checkout_queue_full[core][cluster]         = occ.full;
            assign checkout_queue_full_raw[core][cluster]     = occ.full_raw;
            assign checkout_queue_empty[core][cluster]        = occ.empty;
            assign checkout_queue_usage[core][cluster]        = occ.usage;
            assign checkout_queue_data_out[core][cluster]     = head.desc;
            assign checkout_remote_tag_out[core][cluster]     = head.tag;
            assign checkout_head_imported[core][cluster]      = head.imported;
            assign checkout_head_exec[core][cluster]          = head.exec;
            assign checkout_retire_valid[core][cluster]       = retire.valid;
            assign checkout_local_set_valid[core][cluster]    = retire.local_set;
            assign checkout_chiplet_set_valid[core][cluster]  = retire.chiplet_set;
            assign remote_done_arb_valid[Slot]                = retire.remote_done;
            assign remote_done_arb_data[Slot] = '{
                chip:       checkout_remote_tag_out[core][cluster].origin_chip,
                proxy_slot: checkout_remote_tag_out[core][cluster].proxy_slot,
                task_id:    checkout_queue_data_out[core][cluster].task_id,
                reject:     1'b0
            };
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Core interface and done queues
    //////////////////////////////////////////////////////////////////////
    // READY_AND_DONE_QUEUE_INTERFACE_TYPE selects how the cores reach the manager:
    //   1: CSR requests (bingo_hw_manager_csr_port) carry ready reads, done writes
    //      and heartbeats. The port also isolates a fenced core: its ready reads
    //      stall, its heartbeats are ignored and its dones are dropped.
    //   0: The cores use the mailboxes of the ready queues and of the done queues.
    //      There are no heartbeats (heartbeat_valid is tied to 0).
    //
    // Each (core, cluster) slot has its own done queue
    // (bingo_hw_manager_done_queues), so the dones of one slot never block those
    // of another. The done of a task exported to another chiplet (level 3) returns
    // from the chiplet that ran it into the done queue of the task's proxy slot.
    csr_done_t                        csr_done;
    logic                             csr_done_ready;
    if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==1) begin: gen_csr_to_fifo_intf
        core_status_t core_status;
        bingo_hw_manager_csr_port #(
            .NumCores         ( NUM_CORES_PER_CLUSTER             ),
            .NumClusters      ( NUM_CLUSTERS_PER_CHIPLET          ),
            .TaskIdWidth      ( TaskIdWidth                       ),
            .CsrHeartbeatAddr ( CsrHeartbeatAddr                  ),
            .csr_req_t        ( csr_req_t                         ),
            .csr_rsp_t        ( csr_rsp_t                         ),
            .data_t           ( device_axi_lite_data_t            ),
            .done_info_t      ( bingo_hw_manager_done_info_full_t ),
            .chip_id_t        ( chip_id_t                         ),
            .slot_state_t     ( slot_state_t                      ),
            .ready_t          ( ready_t                           ),
            .core_status_t    ( core_status_t                     ),
            .csr_done_t       ( csr_done_t                        )
        ) i_csr_port (
            .clk_i           ( clk_i           ),
            .rst_ni          ( rst_ni          ),
            .chip_id_i       ( chip_id_i       ),
            .csr_req_i       ( csr_req_i       ),
            .csr_req_valid_i ( csr_req_valid_i ),
            .csr_req_ready_o ( csr_req_ready_o ),
            .csr_rsp_o       ( csr_rsp_o       ),
            .csr_rsp_valid_o ( csr_rsp_valid_o ),
            .csr_rsp_ready_i ( csr_rsp_ready_i ),
            .slot_i          ( slot_state      ),
            .ready_i         ( ready_queue     ),
            .ready_pop_o     ( ready_queue_pop ),
            .core_o          ( core_status     ),
            .done_o          ( csr_done        ),
            .done_ready_i    ( csr_done_ready  )
        );
        assign heartbeat_valid          = core_status.heartbeat;
        assign core_status_waiting_task = core_status.waiting;
        assign exited_q                 = core_status.exited;
    end else begin: gen_no_csr_to_fifo_intf
        // A core waits for a task while its read of the ready mailbox is
        // pending (ar_valid high, r_ready low); the mailbox pops itself
        for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin : gen_waiting_core
            for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin : gen_waiting_cluster
                assign core_status_waiting_task[core][cluster] = ready_queue_axi_lite_req_i[core][cluster].ar_valid &&
                                                                 !ready_queue_axi_lite_req_i[core][cluster].r_ready;
            end
        end
        assign ready_queue_pop = '0;
        // Tie the csr signals to zero
        assign csr_req_ready_o = '0;
        assign csr_rsp_o       = '0;
        assign csr_rsp_valid_o = '0;
        assign heartbeat_valid = '0;
        assign exited_q        = '0;
        assign csr_done        = '0;
    end

    bingo_hw_manager_done_queues #(
        .NumCores      ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters   ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .InterfaceType ( READY_AND_DONE_QUEUE_INTERFACE_TYPE              ),
        .Depth         ( DoneQueueDepth                                   ),
        .RemoteEn      ( RemoteEn                                         ),
        .TaskIdWidth   ( TaskIdWidth                                      ),
        .CoreIdWidth   ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .ChipIdWidth   ( ChipIdWidth                                      ),
        .AxiAddrWidth  ( DeviceAxiLiteAddrWidth                           ),
        .AxiDataWidth  ( DeviceAxiLiteDataWidth                           ),
        .done_info_t   ( bingo_hw_manager_done_info_full_t                ),
        .remote_done_t ( remote_done_t                                    ),
        .req_lite_t    ( device_axi_lite_req_t                            ),
        .resp_lite_t   ( device_axi_lite_resp_t                           ),
        .slot_state_t  ( slot_state_t                                     ),
        .csr_done_t    ( csr_done_t                                       ),
        .done_remote_t ( done_remote_t                                    ),
        .done_t        ( done_t                                           )
    ) i_done_queues (
        .clk_i               ( clk_i                      ),
        .rst_ni              ( rst_ni                     ),
        .chip_id_i           ( chip_id_i                  ),
        .csr_done_i          ( csr_done                   ),
        .csr_done_ready_o    ( csr_done_ready             ),
        .base_addr_i         ( done_queue_base_addr_i     ),
        .axi_lite_req_i      ( done_queue_axi_lite_req_i  ),
        .axi_lite_resp_o     ( done_queue_axi_lite_resp_o ),
        .slot_i              ( slot_state                 ),
        .remote_done_valid_i ( remote_done_valid_i        ),
        .remote_done_ready_o ( remote_done_ready_o        ),
        .remote_done_i       ( remote_done_i              ),
        .remote_o            ( done_remote                ),
        .done_o              ( done_queue                 ),
        .pop_i               ( done_q_pop                 )
    );

    //////////////////////////////////////////////////////////////////////
    // Power Manager
    //////////////////////////////////////////////////////////////////////
    // What the PM reads of every slot (see pm_slot_t): its power domain, and the
    // idle, access, boost and derate views of the control plane. A fenced slot
    // counts as idle, so a dead core does not keep its domain at the normal level.
    pm_slot_t pm_slot;
    assign pm_slot = '{domain:      ctrl_slot_domain,
                       idle:        ctrl_view.idle,
                       access_only: ctrl_view.access_only,
                       boost:       ctrl_view.boost,
                       derate:      ctrl_view.derate};
    bingo_hw_manager_pm #(
        .NUM_CLUSTERS_PER_CHIPLET ( NUM_CLUSTERS_PER_CHIPLET          ),
        .NUM_CORES_PER_CLUSTER    ( NUM_CORES_PER_CLUSTER             ),
        .CfgBusWidth              ( DeviceAxiLiteDataWidth            ),
        .HOST_DVFS_MSIP_BIT       ( HOST_DVFS_MSIP_BIT                ),
        .DivisionPerDomain        ( PmDivisionPerDomain               ),
        .req_lite_t               ( host_axi_lite_req_t               ),
        .resp_lite_t              ( host_axi_lite_resp_t              ),
        .addr_t                   ( host_axi_lite_addr_t              ),
        .data_t                   ( host_axi_lite_data_t              ),
        .pm_slot_t                ( pm_slot_t                         )
    ) i_bingo_hw_manager_pm (
        .clk_i                 ( clk_i                                   ),
        .rst_ni                ( rst_ni                                  ),
        .cfg_i                 ( pm_cfg                                  ),
        .slot_i                ( pm_slot                                 ),
        .pm_base_addr_i        ( bingo_hw_manager_pm_base_addr_i         ),
        // DVFS mode: monitor + notify host
        .dvfs_clint_msip_addr_i( bingo_hw_manager_dvfs_clint_msip_addr_i ),
        .dvfs_request_o        ( bingo_hw_manager_dvfs_request_o         ),
        .domain_level_o        ( pm_domain_level                         ),
        // Interface to Host AXI Lite
        .pm_axi_lite_req_o     ( pm_axi_lite_req_o                       ),
        .pm_axi_lite_resp_i    ( pm_axi_lite_resp_i                      ),
        .bus_error_o           ( pm_bus_error                            )
    );
    assign bus_error_o = {pm_bus_error, fetch_bus_error};
    // Power-domain counters (observation only): cycles of each counted domain
    // per clock level the PM applied, and cycles with an active slot (one that
    // is neither waiting for a task, nor exited, nor fenced: the PM's idle
    // view before the idle entry delay and the holds of bingo_hw_manager_ctrl)
    if (PmCountDomains != 0) begin : gen_pm_counters
        bingo_hw_manager_pm_counters #(
            .NumCores    ( NUM_CORES_PER_CLUSTER    ),
            .NumClusters ( NUM_CLUSTERS_PER_CHIPLET ),
            .FirstDomain ( PmCountBase              ),
            .NumDomains  ( PmCountDomains           )
        ) i_pm_counters (
            .clk_i          ( clk_i                                                 ),
            .rst_ni         ( rst_ni                                                ),
            .pm_i           ( pm_view                                               ),
            .slot_domain_i  ( ctrl_slot_domain                                      ),
            .slot_active_i  ( ~(core_status_waiting_task | exited_q | core_fenced) ),
            .count_o        ( pm_count_o                                            )
        );
    end else begin : gen_no_pm_counters
        assign pm_count_o = '0;
    end

    //////////////////////////////////////////////////////////////////////
    // Watchdog, threshold selection, and adaptive learning
    //////////////////////////////////////////////////////////////////////
    // Three submodules monitor core progress in normal-clock ticks:
    //   i_watchdog   monitors each slot's states from dispatch or heartbeat signals   
    //   i_wd_bounds  selects each slot's suspect, confirm, and late thresholds
    //                from parameters, per-type CSRs, risk_confirm, and wd_learned
    //   i_wd_adapt   learns per-(type, class) bounds from completed tasks

    // wd_event is a vector of signals that indicate the events that happen to each slot
    assign wd_event = '{dispatch:  ready_queue_pop,
                        done:      done_q_push,
                        heartbeat: heartbeat_valid,  // from CSR port
                        waiting:   core_status_waiting_task, // from CSR port
                        tick:      ctrl_view.wd_tick};
    bingo_hw_manager_watchdog #(
        .NumCores(NUM_CORES_PER_CLUSTER),
        .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CounterWidth(WatchdogCounterWidth),
        .HeartbeatTimeoutCycles(WatchdogHeartbeatTimeoutCycles),
        .ConfirmTimeoutCycles(WatchdogConfirmTimeoutCycles),
        .CoreMask(WatchdogCoreMask),
        .CoreTypeIdWidth(CoreTypeIdWidth),
        .CoreTypeId(CoreTypeId),
        .wd_event_t(wd_event_t),
        .wd_bound_t(wd_bound_t),
        .wd_status_t(wd_status_t)
    ) i_watchdog (
        .clk_i       ( clk_i           ),
        .rst_ni      ( rst_ni          ),
        .event_i     ( wd_event        ),
        .bound_i     ( wd_bound        ),
        .fence_req_i ( wd_budget_fence ), // from wd_budget
        .status_o    ( wd_status       )
    );

    // core's state: available -> fenced -> dead_suspect -> late
    assign core_available    = wd_status.available; // not used in the design
    assign core_dead_suspect = wd_status.dead_suspect;
    assign core_fenced       = wd_status.fenced;
    assign wd_late           = wd_status.late | wd_budget_late;  // fault precursor
    
    // top outputs signals 
    assign core_fenced_o = core_fenced;
    assign core_dead_suspect_o = core_dead_suspect;
    assign ready_queue_pending_o = (READY_AND_DONE_QUEUE_INTERFACE_TYPE == 0) ? '0 : ~ready_queue_empty;
`ifndef SYNTHESIS
    // Testbench observation point, not read by the design (each slot uses
    // wd_bound.risk_valid): the value tb_bingo_hw_manager_watchdog_risk_confirm
    // compares the effective threshold with. Validate the full CSR before
    // narrowing it. A valid R is below C and fits.
    logic [WatchdogCounterWidth-1:0] wd_risk_confirm;
    assign wd_risk_confirm = (WatchdogConfirmTimeoutCycles != 0 &&
                             wd_risk_csr_i.risk_confirm > WatchdogHeartbeatTimeoutCycles &&
                             wd_risk_csr_i.risk_confirm < WatchdogConfirmTimeoutCycles) ?
                             WatchdogCounterWidth'(wd_risk_csr_i.risk_confirm) : '0;
`endif
    // choose the thresholds of each slot from three sources:
    // - type_h_i, type_c_i: from host
    // - risk_i: risk bitmap from ctrl_view
    // - learned_i: learned bounds from wd_adapt
    // - learned_i, class_i: learned thresholds in rtl
    bingo_hw_manager_wd_bounds #(
        .NumCores(NUM_CORES_PER_CLUSTER),
        .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CounterWidth(WatchdogCounterWidth),
        .HeartbeatTimeoutCycles(WatchdogHeartbeatTimeoutCycles),
        .ConfirmTimeoutCycles(WatchdogConfirmTimeoutCycles),
        .CoreTypeIdWidth(CoreTypeIdWidth),
        .WdClassWidth(WdClassWidth),
        .CoreTypeId(CoreTypeId),
        .data_t(device_axi_lite_data_t),
        .wd_learned_t(wd_learned_t),
        .wd_bound_t(wd_bound_t)
    ) i_wd_bounds (
        .type_h_i       ( wd_type_h_i                     ),
        .type_c_i       ( wd_type_c_i                     ),
        .late_i         ( wd_risk_csr_i.risk_late    ),
        .risk_confirm_i ( wd_risk_csr_i.risk_confirm ),
        .risk_i         ( ctrl_view.risk                  ), // registered ctrl risk bitmap
        .learned_i      ( wd_learned                      ),
        .class_i        ( wd_class_q                      ),
        .bound_o        ( wd_bound                        )
    );
    // Latched when a core takes its next task (ready queue pop): the task's
    // class (wd_class_q) and whether it runs away from its own logical core
    // (wd_moved_q)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            wd_class_q <= '0;
            wd_moved_q <= '0;
        end else begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++)
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
                    if (ready_queue_pop[c][cl] && !done_q_push[c][cl] && !core_fenced[c][cl]) begin
                        wd_class_q[c][cl] <= ready_class[c][cl];
                        wd_moved_q[c][cl] <= ready_moved[c][cl];
                    end
        end
    end
    // Per-slot task info for the watchdog adaptation (wd_adapt):
    // wd_class:           class of the task the slot runs
    // wd_moved:           whether the task moved to another slot
    // fast:               live flag, set while the slot's clock domain runs faster than normal
    assign wd_task = '{wd_class: wd_class_q, moved: wd_moved_q, fast: ctrl_view.wd_fast};
    // The CSR words of the estimates, the learned bounds and the budget, with fields
    wd_est_wr_t     wd_est_wr;
    assign wd_est_wr     = wd_est_wr_t'(wd_est_data_i);
    bingo_hw_manager_wd_est #(
        .NumCores(NUM_CORES_PER_CLUSTER), .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .WdAdaptTypeBits(WdAdaptTypeBits), .WdClassWidth(WdClassWidth),
        .CoreTypeIdWidth(CoreTypeIdWidth), .CoreMask(WatchdogCoreMask), .CoreTypeId(CoreTypeId),
        .wd_est_t(wd_est_t)
    ) i_wd_est (
        .clk_i(clk_i), 
        .rst_ni(rst_ni), 
        .we_i(wd_est_we_i), 
        .data_i(wd_est_wr),
        .class_i(wd_class_q), 
        .est_o(wd_est)
    );
    bingo_hw_manager_wd_adapt #(
        .NumCores(NUM_CORES_PER_CLUSTER), .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CounterWidth(WatchdogCounterWidth), .WdAdaptTypeBits(WdAdaptTypeBits),
        .WdClassWidth(WdClassWidth), .CoreTypeIdWidth(CoreTypeIdWidth),
        .CoreMask(WatchdogCoreMask), .CoreTypeId(CoreTypeId),
        .wd_event_t(wd_event_t), .wd_status_t(wd_status_t),
        .wd_task_t(wd_task_t), .wd_learned_t(wd_learned_t), .wd_est_t(wd_est_t)
    ) i_wd_adapt (
        .clk_i(clk_i), 
        .rst_ni(rst_ni), 
        .ctrl_i(wd_risk_csr_i.wd_adapt),
        .late_ctrl_i(wd_risk_csr_i.wd_late),
        .event_i(wd_event), 
        .status_i(wd_status), 
        .task_i(wd_task),
        .h_eff_i(wd_bound.h_static), 
        .c_eff_i(wd_bound.c_static),
        .est_i(wd_est), 
        .est_floor_i(wd_risk_csr_i.wd_budget.est_floor),
        .learned_o(wd_learned)
    );
    bingo_hw_manager_wd_budget #(
        .NumCores(NUM_CORES_PER_CLUSTER), .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CounterWidth(WatchdogCounterWidth), .CoreMask(WatchdogCoreMask),
        .wd_event_t(wd_event_t), .wd_status_t(wd_status_t), .wd_task_t(wd_task_t),
        .wd_est_t(wd_est_t)
    ) i_wd_budget (
        .clk_i(clk_i), 
        .rst_ni(rst_ni), 
        .ctrl_i(wd_risk_csr_i.wd_budget),
        .late_ctrl_i(wd_risk_csr_i.wd_late),
        .event_i(wd_event), 
        .status_i(wd_status), 
        .task_i(wd_task), 
        .est_i(wd_est),
        .fence_o(wd_budget_fence), 
        .late_o(wd_budget_late)
    );

`ifndef SYNTHESIS
    bit wd_late_log;
    initial wd_late_log = $test$plusargs("bingo_adapt_log");
    always @(posedge clk_i) begin
        if (rst_ni && wd_late_log && wd_risk_csr_i.wd_late.en) begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++)
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
                    if (wd_late[c][cl])
                        $display("[BINGO_ADAPT_LATE] %0t slot=%0d core=%0d cluster=%0d type=%0d class=%0d interval=%0d threshold=%0d source=%s",
                                 $time, c + cl * NUM_CORES_PER_CLUSTER, c, cl,
                                 CoreTypeId[c][cl], wd_class_q[c][cl], wd_status.interval[c][cl],
                                 wd_bound.late[c][cl], wd_bound.late_adaptive[c][cl] ? "adaptive" : "static");
        end
    end
`endif

    //////////////////////////////////////////////////////////////////////
    // Control plane (bingo_hw_manager_ctrl)
    //////////////////////////////////////////////////////////////////////
    // bingo_hw_manager_ctrl keeps the slot state that placement, replay and power
    // share, and makes the decisions they only read: the slot mapping table
    // (smt), core parking, the at-risk slots, the idle, boost and derate views
    // of the PM, and the CERF degradation. This section prepares its inputs
    // (slot state, queues, host settings, power state) and instantiates it.

    // The table changes this cycle: at init, on a new fence, or on a park or
    // unpark commit
    logic                                                           smt_update;
    // Parking. The request mask is bit (core + cluster * NUM_CORES).
    slot_mask_t                                                     park_req;
    // HeMAiA occamy_quad_ctrl.sv.tpl reads risk_clear by name (QUAD_CTRL_BINGO_*): a rename must be made there too
    slot_mask_t                                                     risk_clear;
    park_t                                                          park;
    // Logical slots with tasks in another core's checkout queue
    slot_mask_t                                                     park_moved;
    // HOLD or UNPARK: no new task of the slot may be placed
    slot_mask_t                                                     park_block;
    always_comb begin
        for (int unsigned c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
            for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                park_moved[c][cl] = (remap_outstanding_q[c][cl] != '0);
            end
        end
    end
    assign park_block = park.hold | park.unpark;
    slot_mask_t                                                     park_slot_push;
    // CERF degradation request (ctrl) and the cycle the register file commits it
    cerf_fb_t                    cerf_fb;
    logic                        cerf_fb_done;
    always_comb begin
        bingo_hw_manager_park_fail_o = '0;
        bingo_hw_manager_risk_o = '0;
        for (int unsigned c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
            for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                int unsigned idx;
                idx = c + cl * NUM_CORES_PER_CLUSTER;
                // Parking needs the CSR ready queues (their empty flag ends the
                // drain); with AXI-Lite mailboxes a request fails at once
                park_req[c][cl] = (READY_AND_DONE_QUEUE_INTERFACE_TYPE == 1) &&
                                  (idx < $bits(bingo_hw_manager_park_req_i)) &&
                                  bingo_hw_manager_park_req_i[idx];
                park_slot_push[c][cl] = checkout_queue_push[c][cl] || ready_queue_push[c][cl];
                risk_clear[c][cl] = (idx < $bits(bingo_hw_manager_risk_clear_i)) &&
                                    bingo_hw_manager_risk_clear_i[idx];
                if (idx < $bits(bingo_hw_manager_risk_o)) bingo_hw_manager_risk_o[idx] = ctrl_view.risk[c][cl];
                if (idx < $bits(bingo_hw_manager_park_fail_o)) begin
                    bingo_hw_manager_park_fail_o[idx] = park.fail[c][cl] ||
                        ((READY_AND_DONE_QUEUE_INTERFACE_TYPE != 1) && bingo_hw_manager_park_req_i[idx]);
                end
            end
        end
    end
    // Load of a slot: its checkout queue occupancy (full = highest). This is the
    // load the substitute choice (SubstitutePolicy 1) and the boost
    // (boost_load_min) use, not bingo_hw_manager_load_monitor below.
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0][CheckoutUsageWidth:0] ctrl_load;
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin : gen_ctrl_load_core
        for (genvar cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin : gen_ctrl_load_cluster
            assign ctrl_load[c][cl] = {checkout_queue_full_raw[c][cl], checkout_queue_usage[c][cl]};
        end
    end
    // Inputs of the control plane: slot state, queues, host settings, power state
    ctrl_queue_t ctrl_queue;
    ctrl_host_t  ctrl_host;
    type_cfg_t   type_cfg;
    ctrl_cfg_t   ctrl_cfg;
    assign slot_state = '{fenced:   core_fenced,
                          retired:  core_retired,
                          stuck:    replay_stuck_slot,
                          rejected: remote_rejected_q};
    assign ctrl_queue = '{waiting:        core_status_waiting_task | exited_q,
                          checkout_empty: checkout_queue_empty,
                          ready_empty:    ready_queue_empty,
                          push:           park_slot_push,
                          moved:          park_moved,
                          load:           ctrl_load};
    assign ctrl_host  = '{park_req:   park_req,
                          risk_clear: risk_clear,
                          domain:     ctrl_slot_domain};
    assign type_cfg   = '{cerf_fb_en:    cerf_fb_en_i,
                          cerf_fb_clear: cerf_fb_clear_i,
                          cerf_fb_set:   cerf_fb_set_i,
                          fence_fb:      bingo_hw_manager_fence_fb_i};
    assign ctrl_cfg   = '{idle_delay:     pm_csr_i.idle_entry_delay,
                          access_hold:    pm_csr_i.access_wake_hold,
                          recovery_hold:  pm_csr_i.recovery_hold,
                          risk_thresh:    wd_risk_csr_i.risk_policy.thresh,
                          risk_action:    wd_risk_csr_i.risk_policy.action,
                          risk_epoch:     wd_risk_csr_i.risk_epoch,
                          boost_policy:   pm_csr_i.boost_policy.policy,
                          boost_credit:   pm_csr_i.boost_policy.credit,
                          boost_load_min: pm_csr_i.boost_policy.load_min,
                          sub:            sub_cfg_i};
    bingo_hw_manager_ctrl #(
        .NumCores(NUM_CORES_PER_CLUSTER),
        .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CoreIdWidth(cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)),
        .ClusterIdWidth(cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)),
        .CoreTypeIdWidth(CoreTypeIdWidth),
        .CoreTypeId(CoreTypeId),
        .SubstituteLevelMask(SubstituteLevelMask),
        .SubstituteL2TypeEn(SubstituteL2TypeEn),
        .SubstitutePolicy(SubstitutePolicy),
        .LoadWidth(CheckoutUsageWidth + 1),
        .ParkSupported(READY_AND_DONE_QUEUE_INTERFACE_TYPE == 1),
        .slot_state_t(slot_state_t),
        .ctrl_queue_t(ctrl_queue_t),
        .ctrl_host_t(ctrl_host_t),
        .ctrl_view_t(ctrl_view_t),
        .type_cfg_t(type_cfg_t),
        .smt_t(smt_t),
        .park_t(park_t),
        .cerf_fb_t(cerf_fb_t)
    ) i_ctrl (
        .clk_i            ( clk_i                             ),
        .rst_ni           ( rst_ni                            ),
        .slot_i           ( slot_state                        ),//cores status,from watchdog
        .late_i           ( wd_late                           ),//late of cores,from watchdog
        .queue_i          ( ctrl_queue                        ),
        .host_i           ( ctrl_host                         ),
        .type_cfg_i       ( type_cfg                          ),
        .cfg_i            ( ctrl_cfg                          ),
        .pm_i             ( pm_view                           ),
        .cluster_access_i ( bingo_hw_manager_cluster_access_i ),
        .cerf_fb_done_i   ( cerf_fb_done                      ),
        .view_o           ( ctrl_view                         ),//Per slot: idle, boost and derate for the PM, watchdog tick, risk, ...
        .smt_o            ( smt                               ),
        .smt_update_o     ( smt_update                        ),
        .park_o           ( park                              ),
        .cerf_fb_o        ( cerf_fb                           ),
        .cerf_fb_evt_o    ( cerf_fb_evt_o                     )
    );

    //////////////////////////////////////////////////////////////////////
    // Task Replay
    //////////////////////////////////////////////////////////////////////
    // A fenced core's checkout queue holds all its dispatched, unfinished tasks
    // in order (the head is the one it was running). The replay controller
    // (bingo_hw_manager_replay_ctrl) moves them to live cores, one MOVE step at
    // a time; its data path (bingo_hw_manager_replay_path) presents each
    // checkout head to it and carries out the steps on the queues.
    // Level 3: a fence-fallback type is not exported, as a type the transport
    // has no target for
    logic [2**CoreTypeIdWidth-1:0] remote_export_type_en;
    assign remote_export_type_en = remote_export_type_en_i & ~bingo_hw_manager_fence_fb_i;

    replay_slot_t   replay_slot;
    replay_l3_t     replay_l3;
    replay_status_t replay_status;
    assign replay_slot = '{fenced:         core_fenced,
                           done_empty:     done_q_empty,
                           checkout_empty: checkout_queue_empty,
                           checkout_full:  checkout_queue_full,
                           ready_full:     ready_queue_full,
                           imported:       checkout_head_imported};
    assign replay_l3   = '{export_ready: export_type_ready,
                           type_en:      remote_export_type_en,
                           bounce_ready: !reject_pending};
    bingo_hw_manager_replay_ctrl #(
        .NumCores(NUM_CORES_PER_CLUSTER),
        .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CoreIdWidth(cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)),
        .ClusterIdWidth(cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)),
        .CoreTypeIdWidth(CoreTypeIdWidth),
        .CoreTypeId(CoreTypeId),
        .SubstituteLevelMask(SubstituteLevelMask),
        .replay_slot_t(replay_slot_t),
        .replay_head_t(replay_head_t),
        .replay_l3_t(replay_l3_t),
        .smt_t(smt_t),
        .replay_step_t(replay_step_t),
        .replay_status_t(replay_status_t)
    ) i_replay_ctrl (
        .clk_i        ( clk_i         ),
        .rst_ni       ( rst_ni        ),
        .slot_i       ( replay_slot   ),
        .head_i       ( replay_head   ),
        .l3_i         ( replay_l3     ),
        .smt_i        ( smt           ),
        .smt_update_i ( smt_update    ),
        .step_o       ( replay_step   ),
        .status_o     ( replay_status )
    );
    // The status and step fields the rest of the top reads, under the names it
    // uses (the testbenches read the other fields of replay_step directly)
    assign core_retired        = replay_status.retired;
    assign replay_ready_flush  = replay_status.ready_flush;
    assign replay_hold_slot    = replay_status.hold;
    assign replay_stuck_slot   = replay_status.stuck;
    assign replay_blocked_o    = replay_status.blocked;
    assign replay_exec_moved   = replay_status.exec_moved;
    assign replay_src_core     = replay_step.src_core;
    assign replay_src_cluster  = replay_step.src_cluster;
    assign replay_rotate       = replay_step.rotate;
    assign replay_stuck   = (|replay_stuck_slot) || (|remote_rejected_q);
    assign replay_stuck_o = replay_stuck;
    // What the replay controller's MOVE step does to the queues
    replay_op_t   replay_op;
    bingo_hw_manager_replay_path #(
        .NumCores        ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters     ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .CoreIdWidth     ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth  ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .CoreTypeIdWidth ( CoreTypeIdWidth                                  ),
        .CoreTypeId      ( CoreTypeId                                       ),
        .RemoteEn        ( RemoteEn                                         ),
        .task_desc_t     ( bingo_hw_manager_task_desc_t                     ),
        .checkout_t      ( checkout_t                                       ),
        .smt_t           ( smt_t                                            ),
        .slot_state_t    ( slot_state_t                                     ),
        .replay_head_t   ( replay_head_t                                    ),
        .replay_step_t   ( replay_step_t                                    ),
        .replay_op_t     ( replay_op_t                                      )
    ) i_replay_path (
        .checkout_i       ( checkout_queue        ),
        .smt_i            ( smt                   ),
        .remote_type_en_i ( remote_export_type_en ),
        .head_o           ( replay_head           ),
        .slot_i           ( slot_state            ),
        .step_i           ( replay_step           ),
        .op_o             ( replay_op             ),
        .pending_o        ( replay_pending        ),
        .move_cluster_o   ( replay_move_cluster   )
    );
    assign replay_data        = replay_op.data;
    assign replay_exit_absorb = replay_op.exit_absorb;
    assign replay_pop         = replay_op.pop;
    assign replay_push        = replay_op.push;
    assign replay_push_ready  = replay_op.push_ready;

    //////////////////////////////////////////////////////////////////////
    // Placement of new tasks
    //////////////////////////////////////////////////////////////////////
    // Each checked waiting queue head goes to its logical slot, to the
    // substitute the control plane chose for it (retired or parked slot), or
    // stays on its proxy slot and is exported (level 3); see
    // bingo_hw_manager_router.
    bingo_hw_manager_router #(
        .NumCores            ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters         ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .CoreIdWidth         ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth      ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .CoreTypeIdWidth     ( CoreTypeIdWidth                                  ),
        .CoreTypeId          ( CoreTypeId                                       ),
        .SubstituteLevelMask ( SubstituteLevelMask                              ),
        .RemoteEn            ( RemoteEn                                         ),
        .OutstandingWidth    ( RemapOutstandingWidth                            ),
        .waiting_t           ( waiting_t                                        ),
        .slot_state_t        ( slot_state_t                                     ),
        .smt_t               ( smt_t                                            ),
        .park_t              ( park_t                                           ),
        .checkout_t          ( checkout_t                                       ),
        .ready_t             ( ready_t                                          ),
        .select_t            ( select_t                                         ),
        .route_t             ( route_t                                          ),
        .remap_req_t         ( remap_req_t                                      ),
        .remap_sel_t         ( remap_sel_t                                      )
    ) i_router (
        .waiting_i             ( waiting_heads                            ),
        .offer_valid_i         ( dep_offer_valid                          ),
        .offer_ready_o         ( dep_offer_ready                          ),
        .slot_i                ( slot_state                               ),
        .remote_type_en_i      ( remote_export_type_en                    ),
        .smt_i                 ( smt                                      ),
        .smt_update_i          ( smt_update                               ),
        .park_i                ( park                                     ),
        .outstanding_i         ( remap_outstanding_q                      ),
        .replay_pending_i      ( replay_pending                           ),
        .replay_move_cluster_i ( replay_move_cluster                      ),
        .checkout_i            ( checkout_queue                           ),
        .ready_i               ( ready_queue                              ),
        .export_grant_i        ( route_remote_grant                       ),
        .select_o              ( remap_select                             ),
        .route_o               ( route                                    )
    );

    // Tasks of each logical slot that sit in the checkout queue of another slot
    bingo_hw_manager_remap_count #(
        .NumCores          ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters       ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .CoreIdWidth       ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth    ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .Width             ( RemapOutstandingWidth                            ),
        .ForeignStuckDrain ( ForeignStuckDrain                                ),
        .task_desc_t       ( bingo_hw_manager_task_desc_t                     ),
        .checkout_t        ( checkout_t                                       )
    ) i_remap_count (
        .clk_i         ( clk_i               ),
        .rst_ni        ( rst_ni              ),
        .checkout_i    ( checkout_queue      ),
        .outstanding_o ( remap_outstanding_q ),
        .moved_in_o    ( moved_in_q          )
    );

    //////////////////////////////////////////////////////////////////////
    // Level 3: remote dispatch (SubstituteLevelMask[2])
    //////////////////////////////////////////////////////////////////////
    // A task of a fenced slot that no live core of this chiplet may run goes to
    // another chiplet.
    //
    // Origin side:
    //   - The task stays in the checkout queue of its fenced slot D, marked
    //     exported, and a copy leaves for the other chiplet
    //     (bingo_hw_manager_remote_export).
    //   - D is its proxy: the remote done enters D's done queue and retires the
    //     head with the normal dep_set.
    //   - A proxy whose export is rejected or times out stops
    //     (bingo_hw_manager_remote_proxy).
    //
    // Executor side:
    //   - The task runs as a task of the lowest slot of its core type (its home),
    //     on that slot or on its live stand-in (bingo_hw_manager_remote_import).
    //   - Its dependencies were checked on the origin, and it sets none here.
    //   - Its done goes back to the origin, or a reject if no live core here may
    //     run it (bingo_hw_manager_remote_reply).
    bingo_hw_manager_task_desc_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] route_desc_full;
    // The proxy slots of the exported tasks, and the exports to the transport
    proxy_t                                                               proxy;
    remote_dispatch_out_t                                                 remote_dispatch_out;
    remote_dispatch_in_t                                                  remote_dispatch_in;
    // Level 3, executor side: a reject for the origin (bingo_hw_manager_remote_reply)
    logic                                                                 import_reject_valid;
    remote_done_t                                                         import_reject_out;
    always_comb begin
        for (int unsigned c = 0; c < NUM_CORES_PER_CLUSTER; c++)
            for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
                route_desc_full[c][cl] = desc_to_full(waiting_dep_check_task_desc[route.src_core[c][cl]]);
    end
    bingo_hw_manager_remote_export #(
        .NumCores          ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters       ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .RemoteEn          ( RemoteEn                                         ),
        .CoreTypeIdWidth   ( CoreTypeIdWidth                                  ),
        .CoreTypeId        ( CoreTypeId                                       ),
        .CoreIdWidth       ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth    ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .NumPeers          ( RemoteNumPeers                                   ),
        .PeerIdWidth       ( RemotePeerIdWidth                                ),
        .FifoDepth         ( RemoteExportFifoDepth                            ),
        .task_desc_full_t  ( bingo_hw_manager_task_desc_full_t                ),
        .remote_slot_t     ( remote_slot_t                                    ),
        .remote_export_t   ( remote_export_t                                  ),
        .chip_id_t         ( chip_id_t                                        ),
        .replay_step_t     ( replay_step_t                                    ),
        .route_t           ( route_t                                          ),
        .checkout_t        ( checkout_t                                       ),
        .remote_dispatch_t ( remote_dispatch_out_t                            )
    ) i_remote_export (
        .clk_i            ( clk_i                         ),
        .rst_ni           ( rst_ni                        ),
        .chip_id_i        ( chip_id_i                     ),
        .step_i           ( replay_step                   ),
        .replay_desc_i    ( desc_to_full(replay_data)     ),
        .route_i          ( route                         ),
        .route_desc_i     ( route_desc_full               ),
        .checkout_i       ( checkout_queue                ),
        .route_grant_o    ( route_remote_grant            ),
        .type_ready_o     ( export_type_ready             ),
        .export_push_o    ( export_push                   ),
        .export_o         ( export_in                     ),
        .type_peer_i      ( remote_export_type_peer_i     ),
        .peer_ready_i     ( remote_export_peer_ready_i    ),
        .dispatch_valid_o ( remote_dispatch_valid_o       ),
        .dispatch_ready_i ( remote_dispatch_ready_i       ),
        .dispatch_o       ( remote_dispatch_out           )
    );
    bingo_hw_manager_remote_proxy #(
        .NumCores      ( NUM_CORES_PER_CLUSTER    ),
        .NumClusters   ( NUM_CLUSTERS_PER_CHIPLET ),
        .RemoteEn      ( RemoteEn                 ),
        .checkout_t    ( checkout_t               ),
        .done_t        ( done_t                   ),
        .done_remote_t ( done_remote_t            ),
        .proxy_t       ( proxy_t                  )
    ) i_remote_proxy (
        .clk_i            ( clk_i                       ),
        .rst_ni           ( rst_ni                      ),
        .checkout_i       ( checkout_queue              ),
        .head_mismatch_i  ( remote_head_mismatch        ),
        .done_i           ( done_queue                  ),
        .remote_i         ( done_remote                 ),
        .timeout_cycles_i ( 32'(remote_proxy_timeout_i) ),
        .proxy_o          ( proxy                       )
    );
    assign remote_dispatch_o = '{desc:        host_axi_lite_data_t'(remote_dispatch_out.desc),
                                 core_type:   remote_dispatch_out.core_type,
                                 origin_chip: remote_dispatch_out.origin_chip,
                                 proxy_slot:  remote_dispatch_out.proxy_slot};
    assign remote_rejected_q             = proxy.rejected;
    assign remote_timeout_o              = proxy.timeout_any;
    assign remote_done_mismatch_o        = proxy.mismatch;

    assign remote_dispatch_in = '{desc:        full_to_desc(bingo_hw_manager_task_desc_full_t'(remote_dispatch_i.desc)),
                                  core_type:   remote_dispatch_i.core_type,
                                  origin_chip: remote_dispatch_i.origin_chip,
                                  proxy_slot:  remote_dispatch_i.proxy_slot};
    bingo_hw_manager_remote_import #(
        .NumCores                  ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters               ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .RemoteEn                  ( RemoteEn                                         ),
        .CoreTypeIdWidth           ( CoreTypeIdWidth                                  ),
        .CoreTypeId                ( CoreTypeId                                       ),
        .ImportSubstituteLevelMask ( ImportSubstituteLevelMask                        ),
        .SubstituteL2TypeEn        ( SubstituteL2TypeEn                               ),
        .CoreIdWidth               ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth            ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .task_desc_t               ( bingo_hw_manager_task_desc_t                     ),
        .remote_tag_t              ( remote_tag_t                                     ),
        .remote_done_t             ( remote_done_t                                    ),
        .chip_id_t                 ( chip_id_t                                        ),
        .remote_dispatch_t         ( remote_dispatch_in_t                             ),
        .slot_state_t              ( slot_state_t                                     ),
        .replay_step_t             ( replay_step_t                                    ),
        .route_t                   ( route_t                                          ),
        .checkout_t                ( checkout_t                                       ),
        .ready_t                   ( ready_t                                          ),
        .import_t                  ( import_t                                         )
    ) i_remote_import (
        .clk_i               ( clk_i                                                        ),
        .rst_ni              ( rst_ni                                                       ),
        .chip_id_i           ( chip_id_i                                                    ),
        .dispatch_valid_i    ( remote_dispatch_valid_i                                      ),
        .dispatch_ready_o    ( remote_dispatch_ready_o                                      ),
        .dispatch_i          ( remote_dispatch_in                                           ),
        .slot_i              ( slot_state                                                   ),
        .replay_pending_i    ( replay_pending                                               ),
        .step_i              ( replay_step                                                  ),
        .replay_push_i       ( replay_push                                                  ),
        .route_i             ( route                                                        ),
        .checkout_i          ( checkout_queue                                               ),
        .ready_i             ( ready_queue                                                  ),
        .import_o            ( imported                                                     ),
        .bounce_tag_i        ( checkout_remote_tag_out[replay_src_core][replay_src_cluster] ),
        .bounce_desc_i       ( replay_data                                                  ),
        .reject_valid_o      ( import_reject_valid                                          ),
        .reject_o            ( import_reject_out                                            ),
        .reject_pending_i    ( reject_pending                                               )
    );
    bingo_hw_manager_remote_reply #(
        .NumSlots      ( NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET ),
        .RemoteEn      ( RemoteEn                                         ),
        .remote_done_t ( remote_done_t                                    )
    ) i_remote_reply (
        .clk_i               ( clk_i                 ),
        .rst_ni              ( rst_ni                ),
        .reject_valid_i      ( import_reject_valid   ),
        .reject_i            ( import_reject_out     ),
        .reject_pending_o    ( reject_pending        ),
        .done_i              ( remote_done_arb_data  ),
        .done_valid_i        ( remote_done_arb_valid ),
        .done_ready_o        ( remote_done_arb_ready ),
        .remote_done_valid_o ( remote_done_valid_o   ),
        .remote_done_ready_i ( remote_done_ready_i   ),
        .remote_done_o       ( remote_done_o         )
    );

    //////////////////////////////////////////////////////////////////////
    // Control event log (observation only)
    //////////////////////////////////////////////////////////////////////
    if (EventLogDepth != 0) begin : gen_evlog
        localparam int unsigned Types = 2**CoreTypeIdWidth;
        localparam int unsigned Events = EvlogGroups * NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET + Types;
        logic [Events-1:0]       events;
        logic [Events-1:0][15:0] args;
        evlog_move_t             move;
        // The threshold that would confirm a fence of the slot now, the argument
        // of its fence record (the host decodes it): 4 the total-time budget,
        // else where the confirm threshold comes from (wd_bound.confirm_src: 3 the
        // learned C, 1 the at-risk R, 2 the per-type C, 0 the parameter C)
        logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0][2:0] fence_reason;
        always_comb begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++)
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
                    fence_reason[c][cl] = wd_budget_fence[c][cl] ? 3'd4 : {1'b0, wd_bound.confirm_src[c][cl]};
        end
        bingo_hw_manager_evlog_events #(
            .NumCores        ( NUM_CORES_PER_CLUSTER                            ),
            .NumClusters     ( NUM_CLUSTERS_PER_CHIPLET                         ),
            .CoreIdWidth     ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
            .ClusterIdWidth  ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
            .CoreTypeIdWidth ( CoreTypeIdWidth                                  ),
            .task_desc_t     ( bingo_hw_manager_task_desc_t                     ),
            .slot_state_t    ( slot_state_t                                     ),
            .ctrl_view_t     ( ctrl_view_t                                      ),
            .park_t          ( park_t                                           ),
            .checkout_t      ( checkout_t                                       ),
            .type_cfg_t      ( type_cfg_t                                       ),
            .cerf_fb_t       ( cerf_fb_t                                        ),
            .replay_step_t   ( replay_step_t                                    )
        ) i_events (
            .clk_i          ( clk_i             ),
            .rst_ni         ( rst_ni            ),
            .slot_i         ( slot_state        ),
            .suspect_i      ( core_dead_suspect ),
            .blocked_i      ( replay_blocked_o  ),
            .view_i         ( ctrl_view         ),
            .park_i         ( park              ),
            .fence_reason_i ( fence_reason      ),
            .checkout_i     ( checkout_queue    ),
            .cerf_fb_i      ( cerf_fb           ),
            .cerf_fb_done_i ( cerf_fb_done      ),
            .type_cfg_i     ( type_cfg          ),
            .cerf_fb_evt_i  ( cerf_fb_evt_o     ),
            .step_i         ( replay_step       ),
            .move_desc_i    ( replay_data       ),
            .events_o       ( events            ),
            .args_o         ( args              ),
            .move_o         ( move              )
        );
        bingo_hw_manager_evlog #(
            .NumCores(NUM_CORES_PER_CLUSTER),
            .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
            .NumTypes(Types),
            .Depth(EventLogDepth),
            .AgeWidth(EventLogAgeWidth)
        ) i_evlog (
            .clk_i, .rst_ni, .enable_i(evlog_ctrl_i.enable),
            .clear_i(evlog_ctrl_i.clear), .pop_i(evlog_ctrl_i.pop),
            .event_i(events), .arg_i(args),
            .move_i(move.valid), .move_code_i(move.code), .move_slot_i(move.slot), .move_arg_i(move.arg),
            .head_o(evlog_status_o.head), .count_o(evlog_status_o.count), .dropped_o(evlog_status_o.dropped)
        );
    end else begin : gen_no_evlog
        assign evlog_status_o = '0;
    end

`ifndef SYNTHESIS
    // Watchdog, parking, remap, replay and level 3 activity in the simulation
    // log, and the slot state of the previous cycle for the invariants below
    slot_state_t slot_log_q;
    bingo_hw_manager_top_log #(
        .NumCores          ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters       ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .CoreIdWidth       ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth    ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .TaskIdWidth       ( TaskIdWidth                                      ),
        .RemoteSlotIdWidth ( RemoteSlotIdWidth                                ),
        .OutstandingWidth  ( RemapOutstandingWidth                            ),
        .task_desc_t       ( bingo_hw_manager_task_desc_t                     ),
        .remote_export_t   ( remote_export_t                                  ),
        .chip_id_t         ( chip_id_t                                        ),
        .slot_state_t      ( slot_state_t                                     ),
        .park_t            ( park_t                                           ),
        .smt_t             ( smt_t                                            ),
        .waiting_t         ( waiting_t                                        ),
        .route_t           ( route_t                                          ),
        .checkout_t        ( checkout_t                                       ),
        .replay_step_t     ( replay_step_t                                    ),
        .import_t          ( import_t                                         ),
        .done_remote_t     ( done_remote_t                                    ),
        .proxy_t           ( proxy_t                                          )
    ) i_top_log (
        .clk_i                 ( clk_i                         ),
        .rst_ni                ( rst_ni                        ),
        .chip_id_i             ( chip_id_i                     ),
        .slot_i                ( slot_state                    ),
        .suspect_i             ( core_dead_suspect             ),
        .blocked_i             ( replay_blocked_o              ),
        .park_i                ( park                          ),
        .smt_i                 ( smt                           ),
        .outstanding_i         ( remap_outstanding_q           ),
        .checkout_i            ( checkout_queue                ),
        .waiting_i             ( waiting_heads                 ),
        .route_i               ( route                         ),
        .step_i                ( replay_step                   ),
        .replay_desc_i         ( replay_data                   ),
        .export_push_i         ( export_push                   ),
        .export_i              ( export_in                     ),
        .imported_i            ( imported                      ),
        .import_origin_chip_i  ( remote_dispatch_i.origin_chip ),
        .import_proxy_slot_i   ( remote_dispatch_i.proxy_slot  ),
        .done_out_valid_i      ( remote_done_valid_o           ),
        .done_out_ready_i      ( remote_done_ready_i           ),
        .done_out_reject_i     ( remote_done_o.reject          ),
        .done_out_task_id_i    ( remote_done_o.task_id         ),
        .done_out_chip_i       ( remote_done_o.chip            ),
        .done_out_proxy_slot_i ( remote_done_o.proxy_slot      ),
        .done_in_valid_i       ( remote_done_valid_i           ),
        .done_in_ready_i       ( remote_done_ready_o           ),
        .done_in_reject_i      ( remote_done_i.reject          ),
        .done_in_task_id_i     ( remote_done_i.task_id         ),
        .done_in_proxy_slot_i  ( remote_done_i.proxy_slot      ),
        .done_remote_i         ( done_remote                   ),
        .proxy_i               ( proxy                         ),
        .slot_log_o            ( slot_log_q                    )
    );

    // Invariants of the replay, remap and retire paths
    bingo_hw_manager_top_assert #(
        .NumCores           ( NUM_CORES_PER_CLUSTER                            ),
        .NumClusters        ( NUM_CLUSTERS_PER_CHIPLET                         ),
        .CheckoutQueueDepth ( CheckoutQueueDepth                               ),
        .ForeignStuckDrain  ( ForeignStuckDrain                                ),
        .CoreIdWidth        ( cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)    ),
        .ClusterIdWidth     ( cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET) ),
        .OutstandingWidth   ( RemapOutstandingWidth                            ),
        .task_desc_t        ( bingo_hw_manager_task_desc_t                     ),
        .remote_export_t    ( remote_export_t                                  ),
        .chip_id_t          ( chip_id_t                                        ),
        .slot_state_t       ( slot_state_t                                     ),
        .replay_step_t      ( replay_step_t                                    ),
        .replay_op_t        ( replay_op_t                                      ),
        .waiting_t          ( waiting_t                                        ),
        .route_t            ( route_t                                          ),
        .ready_t            ( ready_t                                          ),
        .checkout_t         ( checkout_t                                       ),
        .done_t             ( done_t                                           ),
        .done_remote_t      ( done_remote_t                                    )
    ) i_top_assert (
        .clk_i              ( clk_i                      ),
        .rst_ni             ( rst_ni                     ),
        .chip_id_i          ( chip_id_i                  ),
        .task_queue_empty_i ( task_queue_mbox_empty      ),
        .task_queue_pop_i   ( task_queue_mbox_pop        ),
        .task_head_i        ( cur_task_desc              ),
        .slot_i             ( slot_state                 ),
        .blocked_i          ( replay_blocked_o           ),
        .slot_log_i         ( slot_log_q                 ),
        .step_i             ( replay_step                ),
        .replay_op_i        ( replay_op                  ),
        .exec_moved_i       ( replay_exec_moved          ),
        .export_push_i      ( export_push                ),
        .export_i           ( export_in                  ),
        .waiting_i          ( waiting_heads              ),
        .route_i            ( route                      ),
        .park_block_i       ( park_block                 ),
        .outstanding_i      ( remap_outstanding_q        ),
        .moved_in_i         ( moved_in_q                 ),
        .ready_i            ( ready_queue                ),
        .checkout_i         ( checkout_queue             ),
        .stuck_drain_i      ( stuck_drain                ),
        .stuck_head_skip_i  ( stuck_head_skip            ),
        .done_i             ( done_queue                 ),
        .done_pop_i         ( done_q_pop                 ),
        .remote_i           ( done_remote                )
    );
`endif

    //////////////////////////////////////////////////////////////////////
    // Load monitor (upstream, observation only)
    //////////////////////////////////////////////////////////////////////
    // The control plane does not read it: its load is the checkout occupancy
    // (ctrl_load). The per-slot counts are left open; load_total_pending_o is
    // not connected in HeMAiA and only read by tb_stimulus_pm_fault_aware.
    bingo_hw_manager_load_monitor #(
        .NumCores   (NUM_CORES_PER_CLUSTER),
        .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CounterWidth(8)
    ) i_load_monitor (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .task_dispatched_i  (ready_queue_pop),
        .task_done_i        (done_q_push),
        .clear_i            (ctrl_view.load_clear),
        .pending_per_core_o (/* CSR readable — connect when needed */),
        .total_pending_o    (load_total_pending_o)
    );

    //////////////////////////////////////////////////////////////////////
    // Conditional execution: Conditional Execution Register File (CERF)
    //////////////////////////////////////////////////////////////////////

    bingo_hw_manager_cond_exec_controller #(
        .NumGroups(32)
    ) i_cerf (
        .clk_i            ( clk_i                  ),
        .rst_ni           ( rst_ni                 ),
        .cerf_state_o     ( cerf_state             ),
        .cerf_write_data_i( cerf_write_data_i      ),
        .cerf_write_en_i  ( cerf_write_en_i        ),
        .policy_req_i     ( cerf_fb.req            ),
        .policy_clear_i   ( cerf_fb.clear          ),
        .policy_set_i     ( cerf_fb.set            ),
        .policy_done_o    ( cerf_fb_done           )
    );

endmodule
