// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Constants that more than one bingo_hw_manager module, or the host software,
// relies on: the task types of a descriptor, the device CSRs of the ready and
// done queues, the power domains and their counters, the event log codes, and
// the port structs of fixed width.
package bingo_hw_manager_pkg;
    // Task type of a descriptor (two bits, written by the host compiler bingo_dfg.py)
    localparam logic [1:0] TaskNormal   = 2'b00; // runs on its core
    localparam logic [1:0] TaskDummy    = 2'b01; // dependency set / check only: retires in the manager, never dispatched
    localparam logic [1:0] TaskGating   = 2'b10; // runs, then writes the CERF groups it selected
    localparam logic [1:0] TaskNoReplay = 2'b11; // runs like a normal task, but is never replayed once it may
                                                 // have started (it is not idempotent)
    // Device CSRs of the ready and done queues (a core reads its next task / writes its done)
    localparam logic [11:0] CsrReady = 12'h5fe;
    localparam logic [11:0] CsrDone  = 12'h5ff;
    // Power domains 0 .. PmMaxDomains-1. A slot configured with a larger domain
    // belongs to none (the host writes BINGO_PM_NO_DOMAIN, 99, for the host and
    // tied-off slots; libbingo bingo_api.h). The top maps every such value to
    // PmMaxDomains.
    localparam int unsigned PmMaxDomains = 32;
    // Power-domain counters (bingo_hw_manager_pm_counters), per counted domain,
    // in this order. The host reads them by index: add new ones at the end.
    typedef enum int unsigned {
        PmcIdle,    // manager cycles at the idle level
        PmcNormal,  //                at the normal level
        PmcBoost,   //                at the boost level
        PmcOther,   //                at any other level (access servo, derate)
        PmcActive   // manager cycles in which a slot of the domain is active
    } pm_counter_e;
    localparam int unsigned PmCounters = int'(PmcActive) + 1;  // PmcActive is the last

    // Source of the confirm threshold a slot uses (bingo_hw_manager_wd_bounds,
    // wd_bound_t confirm_src). The values are the codes of the event log's fence
    // record (4 there is the total-time budget), which the host decodes.
    localparam logic [1:0] WdConfirmParam   = 2'd0; // ConfirmTimeoutCycles
    localparam logic [1:0] WdConfirmRisk    = 2'd1; // the at-risk R (risk_confirm_i)
    localparam logic [1:0] WdConfirmType    = 2'd2; // the core type's C (type_c_i)
    localparam logic [1:0] WdConfirmLearned = 2'd3; // the learned C (bingo_hw_manager_wd_adapt)

    // CSR words of the host (quad periph registers; the field names are the
    // register fields). The top takes them grouped in pm_csr_t and wd_risk_csr_t.

    // BINGO_WD_ADAPT (bingo_hw_manager_wd_adapt, reset 0: learned H and C off)
    typedef struct packed {
        logic [19:0] floor;        // [31:12] lower bound of the learned H (ticks)
        logic [3:0]  warmup;       // [11:8]  executions before a class counts as learned (0: 1)
        logic [2:0]  sh_c;         // [7:5]   C = max(M << SH_C, 2 H)
        logic [2:0]  sh_h;         // [4:2]   H = max(M << SH_H, FLOOR)
        logic        load_guard;   // [1]     a learned bound needs a peak load no higher than learned
        logic        en;           // [0]     learned H and C on
    } wd_adapt_csr_t;

    // BINGO_WD_LATE (bingo_hw_manager_wd_adapt, bingo_hw_manager_wd_budget; reset 0)
    typedef struct packed {
        logic [19:0] lfloor;       // [31:12] lower bound of the learned Late (ticks)
        logic        rsvd11;       // [11]
        logic [1:0]  frac;         // [10:9]  Late = (M + (M >> 2) * FRAC) << SH_L
        logic [1:0]  moved_sh;     // [8:7]   M and E_tot << MOVED_SH for a task away from its own slot
        logic        local_only;   // [6]     learn only executions on their own slot at the normal level
        logic [1:0]  rsvd4;        // [5:4]
        logic [2:0]  sh_l;         // [3:1]
        logic        en;           // [0]     learned Late on
    } wd_late_csr_t;

    // BINGO_WD_BUDGET (bingo_hw_manager_wd_budget, reset 0: off)
    typedef struct packed {
        logic [19:0] bfloor;       // [31:12] lower bound of the budget (ticks)
        logic [3:0]  rsvd8;        // [11:8]
        logic        est_floor;    // [7]     the estimate is a lower bound of the learned H, C and Late
        logic [1:0]  frac_b;       // [6:5]   late at the done after E_tot + (E_tot >> 2) * FRAC_B
        logic [2:0]  sh_b;         // [4:2]   budget = max(E_tot << SH_B, BFLOOR)
        logic        action;       // [1]     at the budget: 0 one late beat, 1 a fence
        logic        en;           // [0]
    } wd_budget_csr_t;

    // BINGO_WD_EST write (bingo_hw_manager_wd_est)
    typedef struct packed {
        logic [11:0] rsvd20;       // [31:20]
        logic [3:0]  core_type;    // [19:16]
        logic        rsvd15;       // [15]
        logic [2:0]  wd_class;     // [14:12]
        logic [1:0]  rsvd10;       // [11:10]
        logic [9:0]  entry;        // [9:0]   [7:0] E_tot (8-bit float), [9:8] S
    } wd_est_wr_t;

    // BINGO_RISK_POLICY (bingo_hw_manager_risk, bingo_hw_manager_ctrl)
    typedef struct packed {
        logic [15:0] rsvd16;       // [31:16]
        logic [7:0]  derate_level; // [15:8]  level of a derated domain
        logic [1:0]  rsvd6;        // [7:6]
        logic [1:0]  action;       // [5:4]   what an at-risk slot does: [0] park, [1] derate its domain
        logic [3:0]  thresh;       // [3:0]   late beats that make a slot at risk (0: off)
    } risk_policy_csr_t;

    // BINGO_BOOST_POLICY (bingo_hw_manager_level_policy)
    typedef struct packed {
        logic [7:0]  rsvd24;       // [31:24]
        logic [7:0]  load_min;     // [23:16] minimum load (checkout occupancy) of a boosted core
        logic [3:0]  rsvd12;       // [15:12]
        logic [3:0]  credit;       // [11:8]  boosted domains per lost core (0: no limit)
        logic [6:0]  rsvd1;        // [7:1]
        logic        policy;       // [0]     0 the substitutes of fenced cores, 1 capacity
    } boost_policy_csr_t;

    // Port structs of fixed width. The ones whose width depends on the
    // parameters of the top are macros in bingo_hw_manager/typedef.svh.

    // Power CSRs of the host, as the words it writes. The levels are clock
    // dividers (see pm_cfg_t) in the low byte of their word.
    typedef struct packed {
        logic [31:0]       enable_idle_pm;   // [0] idle PM on
        logic [31:0]       pm_mode;          // [0] 1: DVFS, 0: DFS
        logic [31:0]       idle_level;       // a domain whose slots all wait for a task
        logic [31:0]       normal_level;     // a busy domain
        // A domain busy only with accesses from outside; used only if between
        // the normal and the idle level (all 32 bits compared), else normal
        logic [31:0]       access_level;
        // A domain whose core runs a dead core's tasks: a faster divider than
        // the normal level; 0 disables the boost
        logic [31:0]       boost_level;
        logic [31:0]       dvfs_ack;         // DVFS: the level the host has applied
        // Cycles a core must be idle before it lets its domain drop to the idle
        // level (bingo_hw_manager_power_view); 0 = at once
        logic [31:0]       idle_entry_delay;
        // Cycles a cluster's domain stays awake after the last access from
        // outside (bingo_hw_manager_power_view); 0 = off
        logic [31:0]       access_wake_hold;
        // Cycles the live substitute of a fenced slot does not count as idle
        // (bingo_hw_manager_power_view); 0 = off
        logic [31:0]       recovery_hold;
        boost_policy_csr_t boost_policy;     // which cores get the boost level
    } pm_csr_t;

    // Watchdog and fault precursor CSRs of the host
    typedef struct packed {
        // A heartbeat or done of a busy core whose watchdog timer reached this
        // is late (bingo_hw_manager_risk); 0 = off
        logic [31:0]      risk_late;
        logic [31:0]      risk_confirm;      // confirm threshold R of an at-risk slot
        risk_policy_csr_t risk_policy;
        logic [31:0]      risk_epoch;        // the late-beat counts halve every that many cycles (0: never)
        wd_adapt_csr_t    wd_adapt;
        wd_late_csr_t     wd_late;
        wd_budget_csr_t   wd_budget;         // total-time budget against the task-time estimates
    } wd_risk_csr_t;

    // Observation-only event log (bingo_hw_manager_evlog). clear and pop trigger
    // once per value change.
    typedef struct packed {
        logic        enable;
        logic [31:0] clear;
        logic [31:0] pop;
    } evlog_ctrl_t;
    typedef struct packed {
        logic [63:0] head;
        logic [31:0] count;
        logic [15:0] dropped;
    } evlog_status_t;

    // Host configuration of the control plane (bingo_hw_manager_ctrl)
    // Substitute choice of the slot mapping table (bingo_hw_manager_slot_table),
    // from the host:
    //   spare      clusters searched first for a substitute, one bit per cluster
    //              (e.g. a cluster the compiler leaves empty as a cold spare);
    //              0 = none (the order of before)
    //   partition  SubPartBits per cluster (cluster i at [SubPartBits * i +:
    //              SubPartBits]): the partitions it belongs to. A slot of another
    //              cluster may stand in for a slot only if their clusters share a
    //              partition; the same cluster always may (level 1). Clusters from
    //              32 / SubPartBits on belong to every partition. All ones = one
    //              partition (the choice of before)
    localparam int unsigned SubPartBits = 4;
    typedef struct packed {
        logic [31:0] spare;
        logic [31:0] partition;
    } sub_cfg_t;
    localparam sub_cfg_t SubCfgDefault = '{spare: '0, partition: '1};

    typedef struct packed {
        logic [31:0] idle_delay;     // cycles a slot must be idle before the PM may count it as idle (0: at once)
        logic [31:0] access_hold;    // cycles a cluster's slots stay awake after an external access (0: off)
        logic [31:0] recovery_hold;  // cycles the substitute of a fenced slot stays awake (0: off)
        logic [3:0]  risk_thresh;    // late beats that make a slot at risk (0: off)
        logic [1:0]  risk_action;    // what an at-risk slot does: [0] park, [1] derate its domain
        logic [31:0] risk_epoch;     // cycles between two halvings of the late-beat counts (0: never)
        logic        boost_policy;   // 0: boost the substitutes of fenced cores, 1: capacity
        logic [3:0]  boost_credit;   // boosted domains per lost slot (0: no limit)
        logic [7:0]  boost_load_min; // minimum load of a capacity boost candidate
        sub_cfg_t    sub;            // substitute choice (see sub_cfg_t)
    } ctrl_cfg_t;

    // Configuration of the PM (bingo_hw_manager_pm) from the host. The levels
    // are clock dividers: the larger one is the slower clock.
    typedef struct packed {
        logic       enable;       // idle PM on
        logic       dvfs;         // 1: DVFS (notify the host of one chip level), 0: DFS (per domain)
        logic [7:0] idle_level;   // a domain whose slots all wait for a task
        logic [7:0] normal_level; // a busy domain
        logic [7:0] access_level; // DFS: a domain busy only with accesses from outside (0: normal)
        logic [7:0] boost_level;  // a domain with a boosted slot, recovery or capacity boost (0: off)
        logic [7:0] derate_level; // a domain with an at-risk slot runs no faster (0: off)
        logic [7:0] dvfs_level;   // DVFS: the level the host has applied (its acknowledge register)
    } pm_cfg_t;

    // Power state and configured levels (clock dividers) of the PM
    // (bingo_hw_manager_pm), as the control plane and the power-domain
    // counters read them
    typedef struct packed {
        logic             enable;       // idle PM on
        logic             dvfs;         // DVFS mode: one chip level, acknowledged by the host
        logic [7:0]       idle_level;   // the idle level
        logic [7:0]       normal_level; // the normal level
        logic [7:0]       boost_level;  // the boost level (0: off)
        logic [7:0]       dvfs_level;   // DVFS: the level the host has applied
        logic [31:0][7:0] domain_level; // DFS: the level last applied to each domain
    } pm_view_t;

    // Retirement of the head of one slot's checkout queue
    // (bingo_hw_manager_checkout_queue): the head may leave (valid), and the
    // path it is offered to; the ready of that path
    typedef struct packed {
        logic valid;       // the head may retire this cycle
        logic local_set;   // its dep_set, into the local dependency matrix
        logic chiplet_set; // its dep_set, to another chiplet
        logic remote_done; // imported: its done, back to the origin chiplet
    } retire_req_t;
    typedef struct packed {
        logic local_set;
        logic chiplet_set;
        logic remote_done;
    } retire_rsp_t;

    // Event log (bingo_hw_manager_evlog). The top raises one pulse per (group,
    // slot) and one per core type for a CERF fallback; the log turns the pulse
    // into a record with the group's code. The host decodes the codes, so they
    // are an interface: add new ones, never renumber.
    typedef enum int unsigned {
        EvgSuspect,     // watchdog: suspect
        EvgClear,       //           suspect cleared before the fence
        EvgFence,       //           fenced (arg: which threshold confirmed)
        EvgStuck,       // replay: slot stuck
        EvgBlocked,     //         slot blocked
        EvgRisk,        // late heartbeat: at risk
        EvgParked,      // parked
        EvgParkFail,    // park failed
        EvgRetired,     // fenced slot retired (all its tasks moved)
        EvgRecHold,     // recovery hold entered / left (arg: new state)
        EvgExitAbsorb   // exit task absorbed (arg: logical slot, task)
    } evlog_group_e;
    localparam int unsigned EvlogGroups = int'(EvgExitAbsorb) + 1;  // EvgExitAbsorb is the last
    // The per-type pulses sit between the first EvlogGroupsBeforeTypes groups
    // (EvgSuspect .. EvgRetired) and the rest
    localparam int unsigned EvlogGroupsBeforeTypes = int'(EvgRecHold);

    localparam logic [7:0] EvSuspect    = 8'h01;
    localparam logic [7:0] EvClear      = 8'h02;
    localparam logic [7:0] EvFence      = 8'h03;
    localparam logic [7:0] EvMove       = 8'h04; // replay moved a task (arg: destination slot, task)
    localparam logic [7:0] EvStuck      = 8'h05;
    localparam logic [7:0] EvBlocked    = 8'h06;
    localparam logic [7:0] EvRisk       = 8'h07;
    localparam logic [7:0] EvParked     = 8'h08;
    localparam logic [7:0] EvParkFail   = 8'h09;
    localparam logic [7:0] EvCerfFb     = 8'h0a; // CERF fallback of a core type (slot field: the type)
    localparam logic [7:0] EvRetired    = 8'h0b;
    localparam logic [7:0] EvRecHold    = 8'h0c;
    localparam logic [7:0] EvMoveDummy  = 8'h0d; // replay moved a task that runs on no core
    localparam logic [7:0] EvBounce     = 8'h0e; // replay found no destination
    localparam logic [7:0] EvExitAbsorb = 8'h0f;

    function automatic logic [7:0] evlog_group_code(input evlog_group_e group);
        case (group)
            EvgSuspect:  return EvSuspect;
            EvgClear:    return EvClear;
            EvgFence:    return EvFence;
            EvgStuck:    return EvStuck;
            EvgBlocked:  return EvBlocked;
            EvgRisk:     return EvRisk;
            EvgParked:   return EvParked;
            EvgParkFail: return EvParkFail;
            EvgRetired:  return EvRetired;
            EvgRecHold:  return EvRecHold;
            default:     return EvExitAbsorb;
        endcase
    endfunction

    // A move record of the log: the replay moved, bounced or rotated a task
    // (code EvMove, EvMoveDummy or EvBounce), from slot {cluster, core}, arg
    // {destination slot (4'hf: rotated, 0: bounced), task id}
    typedef struct packed {
        logic        valid;
        logic [7:0]  code;
        logic [7:0]  slot;
        logic [15:0] arg;
    } evlog_move_t;

    // Position of a pulse in the event vector of the log
    function automatic int unsigned evlog_idx(
        input evlog_group_e group, input int unsigned slot,
        input int unsigned num_slots, input int unsigned num_types);
        return int'(group) * num_slots + ((int'(group) >= EvlogGroupsBeforeTypes) ? num_types : 0) + slot;
    endfunction
    function automatic int unsigned evlog_type_idx(
        input int unsigned core_type, input int unsigned num_slots);
        return EvlogGroupsBeforeTypes * num_slots + core_type;
    endfunction
endpackage
