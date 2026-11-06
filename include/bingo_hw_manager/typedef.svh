// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Port structs of the bingo_hw_manager submodules whose width depends on the
// parameters of the top (number of cores and clusters, id widths). A package
// cannot take parameters, so these are macros, as the AXI types of
// axi/typedef.svh: bingo_hw_manager_top defines each type once and hands it
// to its submodules as a type parameter. The structs of fixed width are in
// bingo_hw_manager_pkg.
//
// Most fields are slot vectors, indexed [core][cluster] like the rest of the
// top: one struct carries several per-slot signals that travel together, and
// a module reads a whole vector (slot_i.fenced) or one slot
// (slot_i.fenced[c][cl]) as before.
//
// Three words for the slots:
//   logical slot   the (core, cluster) a task's descriptor names
//                  (assigned_core_id, assigned_cluster_id). The slot mapping
//                  table and the parking state are indexed by it.
//   physical slot  the (core, cluster) that holds and runs the task: the
//                  logical slot, or its substitute once that one is fenced or
//                  parked. The checkout, ready and done queues are indexed by it.
//   core index     the core within its cluster. The waiting queues are one per
//                  core index, shared by the clusters: the tasks of (c, 0),
//                  (c, 1), ... wait in one queue, in the order they were pushed
//                  (bingo_hw_manager_dep_unit). The placement calls a waiting
//                  queue a "logical core" (waiting_t, select_t,
//                  bingo_hw_manager_router); its head belongs to the logical
//                  slot (that core index, the head's assigned_cluster_id).

`ifndef BINGO_HW_MANAGER_TYPEDEF_SVH_
`define BINGO_HW_MANAGER_TYPEDEF_SVH_

// State of every slot that the control plane, the placement and the replay read:
//   fenced    confirmed dead, sticky (bingo_hw_manager_watchdog)
//   retired   fenced and all its outstanding tasks moved (bingo_hw_manager_replay_ctrl)
//   stuck     fenced with a task no live core may run (bingo_hw_manager_replay_ctrl)
//   rejected  level 3: its export was rejected or timed out (bingo_hw_manager_remote_export)
`define BINGO_HW_MANAGER_TYPEDEF_SLOT_STATE_T(slot_state_t, NumCores, NumClusters) \
  typedef struct packed {                                                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0] fenced;                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0] retired;                             \
    logic [(NumCores)-1:0][(NumClusters)-1:0] stuck;                               \
    logic [(NumCores)-1:0][(NumClusters)-1:0] rejected;                            \
  } slot_state_t;

// Slot mapping table (bingo_hw_manager_slot_table), indexed by logical slot:
// found: the slot has a substitute, at physical slot (core, cluster)
`define BINGO_HW_MANAGER_TYPEDEF_SMT_T(smt_t, NumCores, NumClusters, CoreIdWidth, ClusterIdWidth) \
  typedef struct packed {                                                                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     found;                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CoreIdWidth)-1:0]    core;                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(ClusterIdWidth)-1:0] cluster;                      \
  } smt_t;

// Core parking (bingo_hw_manager_slot_table), per slot:
//   hold    draining before the move (no new task of the slot is placed)
//   parked  its later executing tasks run on its substitute
//   unpark  moving back: new tasks wait until none of its tasks is elsewhere
//   fail    the park failed; sticky until the slot's request drops
`define BINGO_HW_MANAGER_TYPEDEF_PARK_T(park_t, NumCores, NumClusters) \
  typedef struct packed {                                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0] hold;                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0] parked;                  \
    logic [(NumCores)-1:0][(NumClusters)-1:0] unpark;                  \
    logic [(NumCores)-1:0][(NumClusters)-1:0] fail;                    \
  } park_t;

// The queues of every slot as the control plane reads them:
//   waiting         the core polls its ready queue (or has exited)
//   checkout_empty  its checkout queue is empty
//   ready_empty     its ready queue is empty
//   push            a task enters its checkout or ready queue this cycle
//   moved           tasks of this logical slot sit in another slot's checkout queue
//   load            checkout queue occupancy (full = highest)
`define BINGO_HW_MANAGER_TYPEDEF_CTRL_QUEUE_T(ctrl_queue_t, NumCores, NumClusters, LoadWidth) \
  typedef struct packed {                                                                     \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                waiting;                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                checkout_empty;                  \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                ready_empty;                     \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                push;                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                moved;                           \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(LoadWidth)-1:0] load;                          \
  } ctrl_queue_t;

// What the host(CVA6 core) sets per slot for the control plane:
//   park_req    park the slot (see bingo_hw_manager_slot_table)
//   risk_clear  keep the slot's late-beat count at 0 (bingo_hw_manager_risk)
//   domain      power domain of the slot (>= 32: none, see bingo_hw_manager_pkg PmMaxDomains)
`define BINGO_HW_MANAGER_TYPEDEF_CTRL_HOST_T(ctrl_host_t, NumCores, NumClusters) \
  typedef struct packed {                                                        \
    logic [(NumCores)-1:0][(NumClusters)-1:0]      park_req;                     \
    logic [(NumCores)-1:0][(NumClusters)-1:0]      risk_clear;                   \
    logic [(NumCores)-1:0][(NumClusters)-1:0][5:0] domain;                       \
  } ctrl_host_t;

// What the control plane tells the rest of the manager about every slot:
//   idle         the PM may count the slot as idle (bingo_hw_manager_power_view)
//   access_only  otherwise idle, awake only because its cluster is accessed
//   boost        the PM runs its domain at the boost level (bingo_hw_manager_level_policy)
//   derate       the PM runs its domain no faster than the derate level
//   rec_hold     recovery hold active (for the event log, not a PM input)
//   load_clear   the load monitor clears its pending count
//   wd_tick      its watchdog timer advances this cycle (bingo_hw_manager_wd_tick)
//   wd_fast      its domain runs faster than the normal level
//   risk         at risk (bingo_hw_manager_risk)
`define BINGO_HW_MANAGER_TYPEDEF_CTRL_VIEW_T(ctrl_view_t, NumCores, NumClusters) \
  typedef struct packed {                                                        \
    logic [(NumCores)-1:0][(NumClusters)-1:0] idle;                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0] access_only;                       \
    logic [(NumCores)-1:0][(NumClusters)-1:0] boost;                             \
    logic [(NumCores)-1:0][(NumClusters)-1:0] derate;                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0] rec_hold;                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0] load_clear;                        \
    logic [(NumCores)-1:0][(NumClusters)-1:0] wd_tick;                           \
    logic [(NumCores)-1:0][(NumClusters)-1:0] wd_fast;                           \
    logic [(NumCores)-1:0][(NumClusters)-1:0] risk;                              \
  } ctrl_view_t;

// Host table per core type (0 = off):
//   cerf_fb_en     degrade the CERF once a slot of the type is stuck or rejected
//                  (bingo_hw_manager_cerf_fallback): clear group cerf_fb_clear,
//                  set group cerf_fb_set
//   fence_fb       fence fallback: a fenced or parked slot of the type takes no
//                  substitute at any level (bingo_hw_manager_slot_table)
`define BINGO_HW_MANAGER_TYPEDEF_TYPE_CFG_T(type_cfg_t, NumTypes) \
  typedef struct packed {                                         \
    logic [(NumTypes)-1:0]      cerf_fb_en;                       \
    logic [(NumTypes)-1:0][4:0] cerf_fb_clear;                    \
    logic [(NumTypes)-1:0][4:0] cerf_fb_set;                      \
    logic [(NumTypes)-1:0]      fence_fb;                         \
  } type_cfg_t;

// One CERF degradation (bingo_hw_manager_cerf_fallback), held until the CERF
// commits it: clear group clear, set group set, for core type core_type
`define BINGO_HW_MANAGER_TYPEDEF_CERF_FB_T(cerf_fb_t, CoreTypeIdWidth) \
  typedef struct packed {                                              \
    logic                       req;                                   \
    logic [(CoreTypeIdWidth)-1:0] core_type;                           \
    logic [4:0]                 clear;                                 \
    logic [4:0]                 set;                                   \
  } cerf_fb_t;

// Heads of the waiting queues, one per core index (shared by the clusters), once checked:
//   desc   the head (task_desc_t: bingo_hw_manager_task_desc_t of the top)
//   empty  the waiting queue is empty
//   skip   the CERF skips the head (it runs on no core)
`define BINGO_HW_MANAGER_TYPEDEF_WAITING_T(waiting_t, task_desc_t, NumCores) \
  typedef struct packed {                                                    \
    task_desc_t [(NumCores)-1:0] desc;                                       \
    logic       [(NumCores)-1:0] empty;                                      \
    logic       [(NumCores)-1:0] skip;                                       \
  } waiting_t;

// The checkout queues of every slot (bingo_hw_manager_checkout_queue):
//   push, push_desc, push_tag  an entry is pushed this cycle, and the entry with its side tag
//   exit_absorb                ... and it is an exit that enters as a dummy
//   pop                        the head leaves (retired, or moved by the replay)
//   full                       no room for a new task (level 3 keeps a spare entry)
//   full_raw, usage, empty     occupancy of the FIFO
//   head, head_tag             the head and its side tag (remote_tag_t of the top)
//   head_imported              the head runs here for another chiplet
//   head_exec                  the head runs on a core: it retires with its done
`define BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_T(checkout_t, task_desc_t, remote_tag_t, NumCores, NumClusters, UsageWidth) \
  typedef struct packed {                                                                                             \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 push;                                            \
    task_desc_t  [(NumCores)-1:0][(NumClusters)-1:0]                 push_desc;                                       \
    remote_tag_t [(NumCores)-1:0][(NumClusters)-1:0]                 push_tag;                                        \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 exit_absorb;                                     \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 pop;                                             \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 full;                                            \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 full_raw;                                        \
    logic        [(NumCores)-1:0][(NumClusters)-1:0][(UsageWidth)-1:0] usage;                                         \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 empty;                                           \
    task_desc_t  [(NumCores)-1:0][(NumClusters)-1:0]                 head;                                            \
    remote_tag_t [(NumCores)-1:0][(NumClusters)-1:0]                 head_tag;                                        \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 head_imported;                                   \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                 head_exec;                                       \
  } checkout_t;

// The ready queues of every slot (bingo_hw_manager_ready_queue):
//   push, push_data  an entry is pushed this cycle, and the word the core reads
//                    (ready_desc_t: bingo_hw_manager_ready_task_desc_full_t of the top)
//   full, empty      occupancy
//   pop, data        the core reads the head (CSR interface)
//   wd_class, moved  the class of the head and whether it left its logical slot
`define BINGO_HW_MANAGER_TYPEDEF_READY_T(ready_t, ready_desc_t, NumCores, NumClusters, WdClassWidth) \
  typedef struct packed {                                                                            \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                   push;                         \
    ready_desc_t [(NumCores)-1:0][(NumClusters)-1:0]                   push_data;                    \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                   full;                         \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                   empty;                        \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                   pop;                          \
    ready_desc_t [(NumCores)-1:0][(NumClusters)-1:0]                   data;                         \
    logic        [(NumCores)-1:0][(NumClusters)-1:0][(WdClassWidth)-1:0] wd_class;                   \
    logic        [(NumCores)-1:0][(NumClusters)-1:0]                   moved;                        \
  } ready_t;

// Placement of the waiting queue heads (bingo_hw_manager_router), per logical
// core (waiting queue, i.e. core index): the head may go (valid) to physical
// slot (core, cluster)
`define BINGO_HW_MANAGER_TYPEDEF_SELECT_T(select_t, NumCores, CoreIdWidth, ClusterIdWidth) \
  typedef struct packed {                                                                  \
    logic [(NumCores)-1:0]                       valid;                                    \
    logic [(NumCores)-1:0][(CoreIdWidth)-1:0]    core;                                     \
    logic [(NumCores)-1:0][(ClusterIdWidth)-1:0] cluster;                                  \
  } select_t;

// What the router does for every destination slot:
//   valid        a waiting queue head is routed to the slot, from logical core src_core
//   exit_absorb  it is an exit absorbed into a dummy (it runs on no core)
//   remote       level 3: it is exported, the slot is its proxy
//   fire         it enters the slot's checkout queue this cycle
//   ready_push   ... and its ready queue (it runs on a core)
`define BINGO_HW_MANAGER_TYPEDEF_ROUTE_T(route_t, NumCores, NumClusters, CoreIdWidth) \
  typedef struct packed {                                                             \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                    valid;               \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CoreIdWidth)-1:0] src_core;            \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                    exit_absorb;         \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                    remote;              \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                    fire;                \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                    ready_push;          \
  } route_t;

// The done queues of every slot (bingo_hw_manager_done_queues):
//   push, push_data  a done is pushed this cycle (done_info_t: bingo_hw_manager_done_info_full_t of the top)
//   head, empty      the head of each queue
`define BINGO_HW_MANAGER_TYPEDEF_DONE_T(done_t, done_info_t, NumCores, NumClusters) \
  typedef struct packed {                                                           \
    logic       [(NumCores)-1:0][(NumClusters)-1:0] push;                           \
    done_info_t [(NumCores)-1:0][(NumClusters)-1:0] push_data;                      \
    done_info_t [(NumCores)-1:0][(NumClusters)-1:0] head;                           \
    logic       [(NumCores)-1:0][(NumClusters)-1:0] empty;                          \
  } done_t;

// What the remote dones and rejects of exported tasks (level 3) do to the
// done queues: push, a remote done enters the done queue of its proxy slot;
// reject, a reject marks the proxy slot (it stops); stray, a remote done or
// reject for a slot that is no proxy is dropped
`define BINGO_HW_MANAGER_TYPEDEF_DONE_REMOTE_T(done_remote_t, NumCores, NumClusters) \
  typedef struct packed {                                                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0] push;                                  \
    logic [(NumCores)-1:0][(NumClusters)-1:0] reject;                                \
    logic                                     stray;                                 \
  } done_remote_t;

// A done write of a core (bingo_hw_manager_csr_port) to the done queues:
// valid, and the done info (done_info_t of the top)
`define BINGO_HW_MANAGER_TYPEDEF_CSR_DONE_T(csr_done_t, done_info_t) \
  typedef struct packed {                                            \
    logic       valid;                                               \
    done_info_t info;                                                \
  } csr_done_t;

// What the CSR requests of the cores say about them (bingo_hw_manager_csr_port):
//   heartbeat  a heartbeat this cycle (ignored once fenced)
//   waiting    the core waits for a task (its ready read stalls)
//   exited     the core reported its exit (bit 31 of a heartbeat), until its next ready read
`define BINGO_HW_MANAGER_TYPEDEF_CORE_STATUS_T(core_status_t, NumCores, NumClusters) \
  typedef struct packed {                                                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0] heartbeat;                             \
    logic [(NumCores)-1:0][(NumClusters)-1:0] waiting;                               \
    logic [(NumCores)-1:0][(NumClusters)-1:0] exited;                                \
  } core_status_t;

// One task pushed into the queue of one slot by one source (the router, the
// replay, a level 3 import): valid, and the task
`define BINGO_HW_MANAGER_TYPEDEF_TASK_PUSH_T(task_push_t, task_desc_t) \
  typedef struct packed {                                              \
    logic       valid;                                                 \
    task_desc_t desc;                                                  \
  } task_push_t;

// What the router pushes into the checkout queue of one slot:
//   valid, desc   the routed waiting queue head
//   skip          the CERF skips it at dispatch: it enters as a dummy
//   exit_absorb   an exit absorbed here (see bingo_hw_manager_router): it enters as a dummy
//   remote        level 3: it is exported, the slot is its proxy
`define BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_ROUTE_T(checkout_route_t, task_desc_t) \
  typedef struct packed {                                                        \
    logic       valid;                                                           \
    task_desc_t desc;                                                            \
    logic       skip;                                                            \
    logic       exit_absorb;                                                     \
    logic       remote;                                                          \
  } checkout_route_t;

// What the replay (bingo_hw_manager_replay_path) does to the checkout queue of one slot:
//   push, desc, tag  push a moved entry, with its side tag on the source slot
//   rotate           level 3: the entry goes back to its own slot, exported
//   exit_absorb      the moved entry is an exit absorbed into a dummy
//   pop              take the head (it moves to another slot)
//   hold             hold the head while a MOVE drains the queue
`define BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_REPLAY_T(checkout_replay_t, task_desc_t, remote_tag_t) \
  typedef struct packed {                                                                        \
    logic        push;                                                                           \
    task_desc_t  desc;                                                                           \
    remote_tag_t tag;                                                                            \
    logic        rotate;                                                                         \
    logic        exit_absorb;                                                                    \
    logic        pop;                                                                            \
    logic        hold;                                                                           \
  } checkout_replay_t;

// A task of another chiplet pushed into the checkout queue of one slot (level
// 3): valid, the task and its side tag (origin chiplet and proxy slot)
`define BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_IMPORT_T(checkout_import_t, task_desc_t, remote_tag_t) \
  typedef struct packed {                                                                        \
    logic        valid;                                                                          \
    task_desc_t  desc;                                                                           \
    remote_tag_t tag;                                                                            \
  } checkout_import_t;

// The entry pushed into the checkout queue of one slot this cycle (valid,
// desc, side tag); exit_absorb: an exit that enters it as a dummy
`define BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_ENTRY_T(checkout_entry_t, task_desc_t, remote_tag_t) \
  typedef struct packed {                                                                      \
    logic        valid;                                                                        \
    task_desc_t  desc;                                                                         \
    remote_tag_t tag;                                                                          \
    logic        exit_absorb;                                                                  \
  } checkout_entry_t;

// Occupancy of the checkout queue of one slot: full (level 3 keeps a spare
// entry for replay rotations), full_raw, empty and usage of the FIFO
`define BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_OCC_T(checkout_occ_t, UsageWidth) \
  typedef struct packed {                                                   \
    logic                    full;                                          \
    logic                    full_raw;                                      \
    logic                    empty;                                         \
    logic [(UsageWidth)-1:0] usage;                                         \
  } checkout_occ_t;

// The head of the checkout queue of one slot: the task and its side tag;
// imported: it runs here for another chiplet; exec: it runs on a core, so it
// retires with its done
`define BINGO_HW_MANAGER_TYPEDEF_CHECKOUT_HEAD_T(checkout_head_t, task_desc_t, remote_tag_t) \
  typedef struct packed {                                                                    \
    task_desc_t  desc;                                                                       \
    remote_tag_t tag;                                                                        \
    logic        imported;                                                                   \
    logic        exec;                                                                       \
  } checkout_head_t;

// The entry pushed into the ready queue of one slot: valid, and the word the
// core reads (ready_desc_t: bingo_hw_manager_ready_task_desc_full_t of the top)
`define BINGO_HW_MANAGER_TYPEDEF_READY_PUSH_T(ready_push_t, ready_desc_t) \
  typedef struct packed {                                                 \
    logic        valid;                                                   \
    ready_desc_t data;                                                    \
  } ready_push_t;

// The head of the ready queue of one slot (CSR interface): empty, the word
// the core reads, the class of the task and whether it left its logical slot
`define BINGO_HW_MANAGER_TYPEDEF_READY_HEAD_T(ready_head_t, ready_desc_t, WdClassWidth) \
  typedef struct packed {                                                               \
    logic                      empty;                                                   \
    ready_desc_t               data;                                                    \
    logic [(WdClassWidth)-1:0] wd_class;                                                \
    logic                      moved;                                                   \
  } ready_head_t;

// The checkout heads as the replay controller (bingo_hw_manager_replay_ctrl)
// sees them (bingo_hw_manager_replay_path):
//   logical_core, logical_cluster  the logical slot of the head
//   no_exec                        it runs on no core (a dummy, or an exit absorbed when it moves)
//   no_replay                      it must not be replayed (task_type 11)
//   exported                       level 3: it was exported by this slot
`define BINGO_HW_MANAGER_TYPEDEF_REPLAY_HEAD_T(replay_head_t, NumCores, NumClusters, CoreIdWidth, ClusterIdWidth) \
  typedef struct packed {                                                                                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CoreIdWidth)-1:0]    logical_core;                                 \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(ClusterIdWidth)-1:0] logical_cluster;                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                       no_exec;                                      \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                       no_replay;                                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                       exported;                                     \
  } replay_head_t;

// What the replay controller (bingo_hw_manager_replay_ctrl) reads of every slot:
//   fenced           confirmed dead (bingo_hw_manager_watchdog)
//   done_empty       its done queue is empty
//   checkout_empty, checkout_full, ready_full   its checkout and ready queues
//   imported         level 3: its checkout head was imported from another chiplet
`define BINGO_HW_MANAGER_TYPEDEF_REPLAY_SLOT_T(replay_slot_t, NumCores, NumClusters) \
  typedef struct packed {                                                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0] fenced;                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0] done_empty;                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0] checkout_empty;                      \
    logic [(NumCores)-1:0][(NumClusters)-1:0] checkout_full;                       \
    logic [(NumCores)-1:0][(NumClusters)-1:0] ready_full;                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0] imported;                            \
  } replay_slot_t;

// Level 3 as the replay controller sees it, per core type (index: CoreTypeId):
//   export_ready   the export queue of the type has room
//   type_en        the type has an export target
// and bounce_ready: the reject register takes a bounced entry
`define BINGO_HW_MANAGER_TYPEDEF_REPLAY_L3_T(replay_l3_t, CoreTypeIdWidth) \
  typedef struct packed {                                                \
    logic [2**(CoreTypeIdWidth)-1:0] export_ready;                       \
    logic [2**(CoreTypeIdWidth)-1:0] type_en;                            \
    logic                            bounce_ready;                       \
  } replay_l3_t;

// What the replay controller reports of every slot:
//   retired      fenced and all its outstanding tasks moved (sticky)
//   ready_flush  its ready queue is flushed (being drained)
//   hold         its checkout output is held: being moved, or partly moved
//                and waiting to resume
//   stuck        its next entry no live core may run (sticky); its checkout
//                output stays held
//   blocked      replay protection stopped it (task_type 11, sticky, implies stuck)
//   exec_moved   its first executing entry (the one that may have started) was
//                moved: read only by the checks of bingo_hw_manager_top_assert
`define BINGO_HW_MANAGER_TYPEDEF_REPLAY_STATUS_T(replay_status_t, NumCores, NumClusters) \
  typedef struct packed {                                                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0] retired;                                 \
    logic [(NumCores)-1:0][(NumClusters)-1:0] ready_flush;                             \
    logic [(NumCores)-1:0][(NumClusters)-1:0] hold;                                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0] stuck;                                   \
    logic [(NumCores)-1:0][(NumClusters)-1:0] blocked;                                 \
    logic [(NumCores)-1:0][(NumClusters)-1:0] exec_moved;                              \
  } replay_status_t;

// One MOVE step of the replay controller (bingo_hw_manager_replay_ctrl):
//   move                    the slots being moved (fenced, not retired)
//   fire                    the step moves the head of slot (src_core, src_cluster)
//                           to slot (dst_core, dst_cluster) this cycle
//   push_ready              ... and into the ready queue of the destination
//   bounce                  level 3: the head is an imported entry no live core may run: it is dropped
//   rotate, exported        level 3: the head goes back to its own slot, and is exported
`define BINGO_HW_MANAGER_TYPEDEF_REPLAY_STEP_T(replay_step_t, NumCores, NumClusters, CoreIdWidth, ClusterIdWidth) \
  typedef struct packed {                                                                                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0] move;                                                               \
    logic                                     fire;                                                               \
    logic                                     push_ready;                                                         \
    logic                                     bounce;                                                             \
    logic                                     rotate;                                                             \
    logic                                     exported;                                                           \
    logic [(CoreIdWidth)-1:0]                 src_core;                                                           \
    logic [(ClusterIdWidth)-1:0]              src_cluster;                                                        \
    logic [(CoreIdWidth)-1:0]                 dst_core;                                                           \
    logic [(ClusterIdWidth)-1:0]              dst_cluster;                                                        \
  } replay_step_t;

// What a MOVE step does to the queues (bingo_hw_manager_replay_path):
//   data                the entry it moves (an absorbed exit rewritten as a dummy)
//   exit_absorb         the entry is an exit absorbed into a dummy
//   pop                 the source slot gives up its checkout head
//   push, push_ready    the destination takes it into its checkout and ready queue
`define BINGO_HW_MANAGER_TYPEDEF_REPLAY_OP_T(replay_op_t, task_desc_t, NumCores, NumClusters) \
  typedef struct packed {                                                                     \
    task_desc_t                               data;                                           \
    logic                                     exit_absorb;                                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0] pop;                                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0] push;                                           \
    logic [(NumCores)-1:0][(NumClusters)-1:0] push_ready;                                     \
  } replay_op_t;

// A task exported to another chiplet (level 3), as the transport carries it:
//   desc         the descriptor: a word at the ports of the top and of the
//                transport (remote_dispatch_t of the top),
//                bingo_hw_manager_task_desc_full_t towards the transport and
//                bingo_hw_manager_task_desc_t once imported inside the top
//   core_type    CoreTypeId of its logical slot on the origin chiplet
//   origin_chip  the origin chiplet
//   proxy_slot   its proxy slot on the origin chiplet (flat id), which takes its done
`define BINGO_HW_MANAGER_TYPEDEF_REMOTE_DISPATCH_T(remote_dispatch_t, desc_t, chip_id_t, remote_slot_t, CoreTypeIdWidth) \
  typedef struct packed {                                                                                                \
    desc_t                      desc;                                                                                    \
    logic [(CoreTypeIdWidth)-1:0] core_type;                                                                             \
    chip_id_t                   origin_chip;                                                                             \
    remote_slot_t               proxy_slot;                                                                              \
  } remote_dispatch_t;

// A done or a reject of an imported task, as the transport carries it:
//   chip        the origin chiplet it goes to (0 and not read once received)
//   proxy_slot  its proxy slot on that chiplet (flat id)
//   task_id     the task
//   reject      no live core here may run the task, instead of its done
`define BINGO_HW_MANAGER_TYPEDEF_REMOTE_DONE_T(remote_done_t, chip_id_t, remote_slot_t, task_id_t) \
  typedef struct packed {                                                                          \
    chip_id_t     chip;                                                                            \
    remote_slot_t proxy_slot;                                                                      \
    task_id_t     task_id;                                                                         \
    logic         reject;                                                                          \
  } remote_done_t;

// The proxy slots of the exported tasks (bingo_hw_manager_remote_export), per slot:
//   waiting      its exported head waits for its remote done
//   timeout      ... for the proxy timeout: the done is taken as lost
//   wait_cycles  how long it has waited
//   rejected     it stopped: its export was rejected or timed out (sticky)
// and for the chiplet: timeout_any, a proxy gave up waiting (sticky);
// mismatch, a remote done that does not belong to an exported head (sticky)
`define BINGO_HW_MANAGER_TYPEDEF_PROXY_T(proxy_t, NumCores, NumClusters) \
  typedef struct packed {                                                \
    logic [(NumCores)-1:0][(NumClusters)-1:0]       waiting;             \
    logic [(NumCores)-1:0][(NumClusters)-1:0]       timeout;             \
    logic [(NumCores)-1:0][(NumClusters)-1:0][31:0] wait_cycles;         \
    logic [(NumCores)-1:0][(NumClusters)-1:0]       rejected;            \
    logic                                           timeout_any;         \
    logic                                           mismatch;            \
  } proxy_t;

// The import taken this cycle (bingo_hw_manager_remote_import):
//   fire, reject             pushed into one slot, or rejected back to its origin
//   push                     the slot it is pushed into
//   desc, tag                the task (of its home slot) and its side tag (its origin)
//   home_core, home_cluster  its home slot: the lowest slot of its core type
//   core, cluster            the slot it runs on: the home slot or its live stand-in
`define BINGO_HW_MANAGER_TYPEDEF_IMPORT_T(import_t, task_desc_t, remote_tag_t, NumCores, NumClusters, CoreIdWidth, ClusterIdWidth) \
  typedef struct packed {                                                                                                          \
    logic                                     fire;                                                                                \
    logic                                     reject;                                                                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0] push;                                                                                \
    task_desc_t                               desc;                                                                                \
    remote_tag_t                              tag;                                                                                 \
    logic [(CoreIdWidth)-1:0]                 home_core;                                                                           \
    logic [(ClusterIdWidth)-1:0]              home_cluster;                                                                        \
    logic [(CoreIdWidth)-1:0]                 core;                                                                                \
    logic [(ClusterIdWidth)-1:0]              cluster;                                                                             \
  } import_t;

// What the PM (bingo_hw_manager_pm) reads of every slot:
//   domain       its power domain, decoded once by the top (PmMaxDomains: none)
//   idle         it waits for a task, has exited or is fenced, after the delay
//                and holds of bingo_hw_manager_power_view
//   access_only  it is busy only with accesses from outside (DFS access level)
//   boost        its domain runs at the boost level (recovery or capacity boost,
//                bingo_hw_manager_level_policy)
//   derate       it is at risk: its domain runs no faster than the derate level
`define BINGO_HW_MANAGER_TYPEDEF_PM_SLOT_T(pm_slot_t, NumCores, NumClusters) \
  typedef struct packed {                                                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0][5:0] domain;                   \
    logic [(NumCores)-1:0][(NumClusters)-1:0]      idle;                     \
    logic [(NumCores)-1:0][(NumClusters)-1:0]      access_only;              \
    logic [(NumCores)-1:0][(NumClusters)-1:0]      boost;                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0]      derate;                   \
  } pm_slot_t;

// A waiting queue head asking bingo_hw_manager_core_remap for its slot:
//   valid               there is a head
//   core, cluster       its logical slot
//   remappable          it runs on a core (not a dummy set, not CERF-skipped)
//   no_replay           task_type 11: never exported to another chiplet
`define BINGO_HW_MANAGER_TYPEDEF_REMAP_REQ_T(remap_req_t, CoreIdWidth, ClusterIdWidth) \
  typedef struct packed {                                                              \
    logic                        valid;                                                \
    logic [(CoreIdWidth)-1:0]    core;                                                 \
    logic [(ClusterIdWidth)-1:0] cluster;                                              \
    logic                        remappable;                                           \
    logic                        no_replay;                                            \
  } remap_req_t;

// The answer of bingo_hw_manager_core_remap:
//   valid               the head may go now
//   core, cluster       to this physical slot
//   remote              level 3: the slot is the logical one, as the proxy of a
//                       remote chiplet (the router exports the task)
`define BINGO_HW_MANAGER_TYPEDEF_REMAP_SEL_T(remap_sel_t, CoreIdWidth, ClusterIdWidth) \
  typedef struct packed {                                                              \
    logic                        valid;                                                \
    logic [(CoreIdWidth)-1:0]    core;                                                 \
    logic [(ClusterIdWidth)-1:0] cluster;                                              \
    logic                        remote;                                               \
  } remap_sel_t;

// What the watchdog (bingo_hw_manager_watchdog) times, per slot:
//   dispatch   the core took its next task (busy, the timer restarts)
//   done       its done reached the done queue (idle)
//   heartbeat  a heartbeat write (the timer restarts)
//   waiting    the core polls its ready queue (feeds only status.available)
//   tick       its timer advances this cycle (bingo_hw_manager_wd_tick)
`define BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(wd_event_t, NumCores, NumClusters) \
  typedef struct packed {                                                      \
    logic [(NumCores)-1:0][(NumClusters)-1:0] dispatch;                        \
    logic [(NumCores)-1:0][(NumClusters)-1:0] done;                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0] heartbeat;                       \
    logic [(NumCores)-1:0][(NumClusters)-1:0] waiting;                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0] tick;                            \
  } wd_event_t;

// The task each slot runs, as the watchdog adaptation (bingo_hw_manager_wd_adapt)
// reads it:
//   wd_class  its class, latched at dispatch (0: never learned)
//   moved     it runs away from its own logical slot (replayed, remapped or
//             imported), latched at dispatch
//   fast      the slot's power domain runs faster than the normal level this cycle
`define BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(wd_task_t, NumCores, NumClusters, WdClassWidth) \
  typedef struct packed {                                                              \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(WdClassWidth)-1:0] wd_class;            \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     moved;               \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     fast;                \
  } wd_task_t;

// The bounds the watchdog adaptation learned (bingo_hw_manager_wd_adapt), per
// slot: suspect (h), confirm (c) and late threshold, each with its valid bit
`define BINGO_HW_MANAGER_TYPEDEF_WD_LEARNED_T(wd_learned_t, NumCores, NumClusters) \
  typedef struct packed {                                                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0][31:0] h;                             \
    logic [(NumCores)-1:0][(NumClusters)-1:0][31:0] c;                             \
    logic [(NumCores)-1:0][(NumClusters)-1:0][31:0] late;                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0]       h_valid;                       \
    logic [(NumCores)-1:0][(NumClusters)-1:0]       c_valid;                       \
    logic [(NumCores)-1:0][(NumClusters)-1:0]       late_valid;                    \
  } wd_learned_t;

// The compile-time estimate of the task each slot runs (bingo_hw_manager_wd_est), in
// timer ticks:
//   valid  the table has an estimate for the slot's (core type, class)
//   e_tot  the task's time from dispatch to done
//   e_int  its longest interval without progress, e_tot >> S
`define BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(wd_est_t, NumCores, NumClusters) \
  typedef struct packed {                                                  \
    logic [(NumCores)-1:0][(NumClusters)-1:0]       valid;                 \
    logic [(NumCores)-1:0][(NumClusters)-1:0][19:0] e_tot;                 \
    logic [(NumCores)-1:0][(NumClusters)-1:0][19:0] e_int;                 \
  } wd_est_t;

// Watchdog thresholds (bingo_hw_manager_wd_bounds), in timer ticks. The
// watchdog compares with the three *_eff values only; the rest says where they
// come from (for the log, the event log, bingo_hw_manager_wd_adapt and TBs).
//   suspect_eff             the timer value that makes a busy slot dead_suspect
//   confirm_eff             the timer value that fences it (with fencing on)
//   late_eff                a heartbeat or done at this timer value or later is
//                           late (0: off)
//   confirm_src             where confirm_eff comes from: WdConfirmParam,
//                           WdConfirmRisk, WdConfirmType or WdConfirmLearned
//                           (bingo_hw_manager_pkg)
//   h_static                static suspect threshold: the core type's H (type_h_i)
//                           if nonzero and no longer than the parameter, else the
//                           parameter; caps the learned suspect threshold
//   c_static                static confirm threshold: the core type's C (type_c_i)
//                           if fencing is on and it is longer than h_static but no
//                           longer than the parameter, else the parameter (0:
//                           fencing off); caps the learned confirm threshold
//   late, late_adaptive     late-beat threshold: learned if late_adaptive, else
//                           the host's global one (0: the global one; off if that
//                           is 0 too)
//   risk_valid              confirming is on and risk_confirm_i lies strictly between
//                           h_static and c_static (applies while the slot is at
//                           risk, unless a learned confirm is shorter)
//   wd_class                class of the task the slot runs (for the log only)
`define BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(wd_bound_t, NumCores, NumClusters, CounterWidth, WdClassWidth) \
  typedef struct packed {                                                                               \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CounterWidth)-1:0]  suspect_eff;                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CounterWidth)-1:0]  confirm_eff;                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CounterWidth)-1:0]  late_eff;                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0][1:0]                 confirm_src;                         \
    logic [(NumCores)-1:0][(NumClusters)-1:0][31:0]                h_static;                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0][31:0]                c_static;                            \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CounterWidth)-1:0]  late;                                \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                      late_adaptive;                       \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                      risk_valid;                          \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(WdClassWidth)-1:0]  wd_class;                            \
  } wd_bound_t;

// What the watchdog reports, per slot:
//   busy           the core runs a task
//   available      it polls its ready queue, is not busy and not suspected
//   dead_suspect   no heartbeat for the suspect threshold (stays set once fenced)
//   fenced         confirmed dead, sticky
//   late           one-cycle pulse per late beat (a heartbeat or done after the late threshold)
//   progress       a done, or a heartbeat that is no dispatch, of a busy slot (learned from)
//   interval       its timer
`define BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(wd_status_t, NumCores, NumClusters, CounterWidth) \
  typedef struct packed {                                                                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     busy;                      \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     available;                 \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     dead_suspect;              \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     fenced;                    \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     late;                      \
    logic [(NumCores)-1:0][(NumClusters)-1:0]                     progress;                  \
    logic [(NumCores)-1:0][(NumClusters)-1:0][(CounterWidth)-1:0] interval;                  \
  } wd_status_t;

// All port types of the control plane (bingo_hw_manager_ctrl), named as its
// type parameters, for a module or testbench that instantiates it
`define BINGO_HW_MANAGER_TYPEDEF_CTRL_ALL(NumCores, NumClusters, CoreIdWidth, ClusterIdWidth, CoreTypeIdWidth, LoadWidth) \
  `BINGO_HW_MANAGER_TYPEDEF_SLOT_STATE_T(slot_state_t, NumCores, NumClusters)                                             \
  `BINGO_HW_MANAGER_TYPEDEF_CTRL_QUEUE_T(ctrl_queue_t, NumCores, NumClusters, LoadWidth)                                  \
  `BINGO_HW_MANAGER_TYPEDEF_CTRL_HOST_T(ctrl_host_t, NumCores, NumClusters)                                               \
  `BINGO_HW_MANAGER_TYPEDEF_CTRL_VIEW_T(ctrl_view_t, NumCores, NumClusters)                                               \
  `BINGO_HW_MANAGER_TYPEDEF_TYPE_CFG_T(type_cfg_t, 2**(CoreTypeIdWidth))                                                  \
  `BINGO_HW_MANAGER_TYPEDEF_SMT_T(smt_t, NumCores, NumClusters, CoreIdWidth, ClusterIdWidth)                              \
  `BINGO_HW_MANAGER_TYPEDEF_PARK_T(park_t, NumCores, NumClusters)                                                         \
  `BINGO_HW_MANAGER_TYPEDEF_CERF_FB_T(cerf_fb_t, CoreTypeIdWidth)

`endif
