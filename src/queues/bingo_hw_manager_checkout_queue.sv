// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Checkout queue of one physical slot, and the rule by which its head retires.
//
// Every task placed on the slot waits here, in FIFO order, until it retires or
// a replay moves it away. The head is the oldest task still here. An entry
// keeps the logical core and cluster of its descriptor, so a slot may hold
// tasks of other logical slots (remapped, replayed or imported).
//
// Retirement of the head (see retire_kind):
//   - A task that runs on a core retires with its own done. An exported task
//     retires with the remote done of the same task.
//   - A task that runs on no core retires without a done.
//   - A stuck or rejected slot retires only the heads stuck_drain_o allows.
//   - A replay MOVE holds the head (replay_i.hold) and pops it itself
//     (replay_i.pop).
// A retiring head sends its dep_set, if enabled, to the local dependency matrix
// or to another chiplet. An imported head sends its done back to its origin
// instead.
module bingo_hw_manager_checkout_queue
    import bingo_hw_manager_pkg::*;
#(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    // This slot
    parameter int unsigned Core = 0,
    parameter int unsigned Cluster = 0,
    // Tasks the slot may hold (bingo_hw_manager_top CheckoutQueueDepth)
    parameter int unsigned Depth = 8,
    parameter int unsigned TaskIdWidth = 12,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    // Level 3 remote dispatch (side tags; one spare entry for replay rotations)
    parameter bit          RemoteEn = 1'b0,
    // See bingo_hw_manager_top ForeignStuckDrain
    parameter bit          ForeignStuckDrain = 1'b1,
    // Width of the remap outstanding counters (bingo_hw_manager_remap_count)
    parameter int unsigned OutstandingWidth = 1,
    parameter type         task_desc_t = logic,  // bingo_hw_manager_task_desc_t of the top
    parameter type         remote_tag_t = logic, // remote_tag_t of the top
    parameter type         chip_id_t = logic,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         checkout_route_t = logic,
    parameter type         checkout_replay_t = logic,
    parameter type         checkout_import_t = logic,
    parameter type         checkout_entry_t = logic,
    parameter type         checkout_occ_t = logic,
    parameter type         checkout_head_t = logic,
    parameter type         slot_state_t = logic,
    parameter type         done_t = logic,
    // Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned FifoDepth = Depth + (RemoteEn ? 1 : 0),
    parameter int unsigned UsageWidth = (FifoDepth > 1) ? $clog2(FifoDepth) : 1
) (
    input  logic                        clk_i,
    input  logic                        rst_ni,
    input  chip_id_t                    chip_id_i,
    // Pushes, at most one source per cycle: a replayed entry (bingo_hw_manager_replay_path), 
    // an imported task (level 3), or a routed task (bingo_hw_manager_router)
    input  checkout_replay_t            replay_i,
    input  checkout_import_t            import_i,
    input  checkout_route_t             route_i,
    // The entry pushed this cycle, and the head leaving (retired or moved)
    output checkout_entry_t             push_o,
    output logic                        pop_o,
    // Occupancy; the head the core runs (or ran) on
    output checkout_occ_t               occ_o,
    output checkout_head_t              head_o,
    // Core state: this core stuck (no live core may run its head) or rejected
    // (level 3), and the retired logical slots (foreign heads); the CERF
    input  slot_state_t                 slot_i,
    input  logic [31:0]                 cerf_state_i,
    // Foreign heads of a stuck slot (ForeignStuckDrain): the remap outstanding
    // counts of the logical slots, and how many of their tasks sit in this slot
    input  logic [OutstandingWidth-1:0] outstanding_i [NumCores][NumClusters],
    input  logic [OutstandingWidth-1:0] moved_in_i [NumCores][NumClusters],
    // A stuck or rejected slot may still retire its head (it runs on no core),
    // and the CERF skips it now
    output logic                        stuck_drain_o,
    output logic                        stuck_head_skip_o,
    // Done queues: the head of this slot's queue; its done leaves with the
    // retiring head
    input  done_t                       done_i,
    output logic                        done_pop_o,
    // Level 3: the done at the head of the done queue is not the exported head's
    output logic                        remote_mismatch_o,
    // Retirement: the head may leave, into the local dependency matrix, to
    // another chiplet or, imported, back to its origin; the readies of those paths
    output retire_req_t                 retire_o,
    input  retire_rsp_t                 retire_i
);
    // The entry pushed, occupancy, head and retirement (push_o, occ_o, head_o, retire_o)
    logic                  push, exit_absorb;
    task_desc_t            push_desc, head;
    remote_tag_t           push_tag, head_tag;
    logic                  full, full_raw, empty, head_imported, head_exec;
    logic [UsageWidth-1:0] usage;
    logic                  retire_valid, retire_fire, local_set_valid, chiplet_set_valid, remote_done_valid;
    assign push_o   = '{valid: push, desc: push_desc, tag: push_tag, exit_absorb: exit_absorb};
    assign occ_o    = '{full: full, full_raw: full_raw, empty: empty, usage: usage};
    assign head_o   = '{desc: head, tag: head_tag, imported: head_imported, exec: head_exec};
    assign retire_o = '{valid:       retire_valid,
                        local_set:   local_set_valid,
                        chiplet_set: chiplet_set_valid,
                        remote_done: remote_done_valid};
    // This slot's state and the head of its done queue
    logic                   stuck, rejected, done_empty;
    logic [TaskIdWidth-1:0] done_task_id;
    assign stuck        = slot_i.stuck[Core][Cluster];
    assign rejected     = slot_i.rejected[Core][Cluster];
    assign done_empty   = done_i.empty[Core][Cluster];
    assign done_task_id = done_i.head[Core][Cluster].task_id;

    //////////////////////////////////////////////////////////////////////
    // Queue storage
    //////////////////////////////////////////////////////////////////////
    fifo_v3 #(
        .FALL_THROUGH ( 1'b0          ),
        .DEPTH        ( FifoDepth     ),
        .dtype        ( task_desc_t   )
    ) i_checkout_queue (
        .clk_i       ( clk_i       ),
        .rst_ni      ( rst_ni      ),
        .testmode_i  ( 1'b0        ),
        .flush_i     ( 1'b0        ),
        .full_o      ( full_raw    ),
        .empty_o     ( empty       ),
        .usage_o     ( usage       ),
        .data_i      ( push_desc   ),
        .push_i      ( push        ),
        .data_o      ( head        ),
        .pop_i       ( pop_o       )
    );
    // Level 3: the spare entry is only for replay rotations
    if (RemoteEn) begin : gen_checkout_remote
        assign full = full_raw || (usage == UsageWidth'(Depth));
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0         ),
            .DEPTH        ( FifoDepth    ),
            .dtype        ( remote_tag_t )
        ) i_checkout_remote_tag (
            .clk_i       ( clk_i                            ),
            .rst_ni      ( rst_ni                           ),
            .testmode_i  ( 1'b0                             ),
            .flush_i     ( 1'b0                             ),
            .full_o      ( /* same as the checkout queue */ ),
            .empty_o     ( /* same as the checkout queue */ ),
            .usage_o     ( /* same as the checkout queue */ ),
            .data_i      ( push_tag                         ),
            .push_i      ( push                             ),
            .data_o      ( head_tag                         ),
            .pop_i       ( pop_o                            )
        );
    end else begin : gen_checkout_no_remote
        assign full     = full_raw;
        assign head_tag = '0;
    end
    assign head_imported = RemoteEn && head_tag.imported;

    //////////////////////////////////////////////////////////////////////
    // Push
    //////////////////////////////////////////////////////////////////////
    assign push = route_i.valid | replay_i.push | import_i.valid;
    assign exit_absorb = (route_i.valid && route_i.exit_absorb) ||
                         (replay_i.push && replay_i.exit_absorb);

    // CERF: if task is conditionally skipped, mark as dummy (TaskDummy)
    // so checkout logic fires dep_set without done_queue match
    always_comb begin
        if (replay_i.push) begin
            // Replayed entry: already checked (and CERF-marked) at its first dispatch
            push_desc = replay_i.desc;
        end else if (import_i.valid) begin
            // Imported entry: checked on its origin chiplet
            push_desc = import_i.desc;
        end else begin
            push_desc = route_i.desc;
            if (route_i.skip || route_i.exit_absorb) begin
                push_desc.task_type = TaskDummy;
            end
        end
    end
    // Level 3: the side tag of the entry
    if (RemoteEn) begin : gen_push_tag
        always_comb begin
            push_tag = '0;
            if (replay_i.push) begin
                push_tag = replay_i.tag;
                if (replay_i.rotate) push_tag.exported = 1'b1;
            end else if (import_i.valid) begin
                push_tag = import_i.tag;
            end else begin
                push_tag.exported = route_i.remote;
            end
        end
    end else begin : gen_no_push_tag
        assign push_tag = '0;
    end

    //////////////////////////////////////////////////////////////////////
    // Stuck drain
    //////////////////////////////////////////////////////////////////////
    // A stuck or rejected slot runs nothing more. Its head may still retire
    // the way a skipped task does (dep_set, no done) when it never runs on
    // a core anyway (dummy-set, or skipped at dispatch) or when the CERF
    // now skips it (degradation, see bingo_hw_manager_cerf_fallback). For the
    // slot's own logical core with no task in another slot: then every
    // older task of that core has left this FIFO. With ForeignStuckDrain,
    // also for a logical core X that died before this slot: X is retired
    // (its own queue holds none of its tasks) and every task of X in
    // another slot is in this one, so this FIFO keeps X's order (a type
    // with a substitute whose two cores both died). Anything else waits.
    logic stuck_head_own, stuck_head_foreign;
    assign stuck_head_own =
        (head.assigned_core_id == CoreIdWidth'(Core)) &&
        (head.assigned_cluster_id == ClusterIdWidth'(Cluster)) &&
        (outstanding_i[Core][Cluster] == '0);
    if (ForeignStuckDrain) begin : gen_foreign_drain
        logic [CoreIdWidth-1:0]    x_core;
        logic [ClusterIdWidth-1:0] x_cluster;
        assign x_core    = head.assigned_core_id;
        assign x_cluster = head.assigned_cluster_id;
        assign stuck_head_foreign =
            ((x_core != CoreIdWidth'(Core)) || (x_cluster != ClusterIdWidth'(Cluster))) &&
            (int'(x_core) < NumCores) && (int'(x_cluster) < NumClusters) &&
            slot_i.retired[x_core][x_cluster] &&
            (moved_in_i[x_core][x_cluster] == outstanding_i[x_core][x_cluster]);
    end else begin : gen_no_foreign_drain
        assign stuck_head_foreign = 1'b0;
    end
    assign stuck_drain_o = (stuck || rejected) && !empty && !head_imported &&
                           (stuck_head_own || stuck_head_foreign);
    assign stuck_head_skip_o = stuck_drain_o && head.cond_exec_en &&
        (head.cond_exec_invert ? cerf_state_i[head.cond_exec_group_id] :
                                 !cerf_state_i[head.cond_exec_group_id]);

    //////////////////////////////////////////////////////////////////////
    // Retire rule
    //////////////////////////////////////////////////////////////////////
    // An executing task (normal / gating) only leaves the checkout queue with its
    // own done, for the local and the chiplet dep_set path alike.
    assign head_exec = ((head.task_type == TaskNormal) || (head.task_type == TaskGating) ||
                        (head.task_type == TaskNoReplay)) && !stuck_head_skip_o;
    // Level 3: an exported head only retires on the remote done of the
    // same task (the dones of a proxy slot come back in export order)
    assign remote_mismatch_o = RemoteEn && head_tag.exported && !empty && head_exec &&
                               !done_empty && (done_task_id != head.task_id);

    // How the head may leave this cycle (a replay move is not a retirement).
    // Everything that retires a head reads this one rule.
    typedef enum logic [1:0] {
        RetireNone,     // stays
        RetireSkip,     // runs on no core (dummy set, or a head the CERF skips): leaves without a done
        RetireWithDone  // ran on a core: leaves together with its own done
    } retire_kind_e;
    retire_kind_e retire_kind;
    // The retire rule. A head that ran on a core waits for its done (for an
    // exported head: the remote done of the same task) and never leaves a
    // stuck or rejected slot. A head that runs on no core leaves at once; on
    // a stuck or rejected slot only when stuck_drain allows it.
    always_comb begin
        retire_kind = RetireNone;
        if (!empty && !replay_i.hold) begin
            if (head_exec) begin
                if (!(stuck || rejected) && !done_empty && !remote_mismatch_o) begin
                    retire_kind = RetireWithDone;
                end
            end else if (!(stuck || rejected) || stuck_drain_o) begin
                retire_kind = RetireSkip;
            end
        end
    end
    assign retire_valid = (retire_kind != RetireNone);

    //////////////////////////////////////////////////////////////////////
    // Retire paths
    //////////////////////////////////////////////////////////////////////
    // An imported head retires into the remote done stream, any other into its dep_set path
    logic       set_valid, set_ready;
    logic [1:0] set_oup_valid, set_oup_ready;
    logic       local_ready, local_drop;
    assign set_valid         = retire_valid && !head_imported;
    assign remote_done_valid = retire_valid && head_imported;

    // [0]: local dep set, [1]: chiplet dep set
    stream_demux #(
        .N_OUP ( 2 )
    ) i_stream_demux_checkout_queue_chiplet_dep_set (
        .inp_valid_i ( set_valid     ),
        .inp_ready_o ( set_ready     ),
        .oup_sel_i   ( head.dep_set_info.dep_set_chiplet_id != chip_id_i ),
        .oup_valid_o ( set_oup_valid ),
        .oup_ready_i ( set_oup_ready )
    );
    assign chiplet_set_valid = set_oup_valid[1];
    assign set_oup_ready     = {retire_i.chiplet_set, local_ready};

    // A head whose dep set is disabled skips the dependency matrix, but only
    // while this slot's done queue is not empty. A head that ran always has
    // its done there (see retire_kind), so it is always dropped. A head that
    // runs on no core (dummy, CERF-skipped, absorbed exit) is dropped only if
    // the done queue happens to hold a done; otherwise it goes through the
    // dependency-matrix arbiter like a set and retires on that handshake. The
    // condition is left over from an older retire rule; it stays because
    // dropping those heads too would change when they retire.
    assign local_drop = (head.dep_set_info.dep_set_en == 1'b0) && !done_empty;
    stream_filter i_stream_filter_checkout_queue_dep_set_enable (
        .valid_i ( set_oup_valid[0]  ),
        .ready_o ( local_ready       ),
        .drop_i  ( local_drop        ),
        .valid_o ( local_set_valid ),
        .ready_i ( retire_i.local_set )
    );

    assign retire_fire = (set_valid && set_ready) || (remote_done_valid && retire_i.remote_done);
    // The done of a head that ran leaves with it. Popping on the dep-matrix
    // arbiter's ready instead left the done behind when the head took another
    // path, so the next task retired on it prematurely.
    assign done_pop_o = retire_fire && (retire_kind == RetireWithDone);
    // Pop on the handshake only: the downstream arbiters may raise ready without
    // valid, which would retire an executing head before its done arrived.
    // While a replay MOVE drains this queue, only the replay controller pops it
    // (valid is held low then). A stuck slot keeps its remaining entries: a
    // dummy-set among them must not fire before its lost source task
    // (only heads that run on no core leave it, see stuck_drain).
    // An imported head retires into the remote done stream instead.
    assign pop_o = retire_fire || replay_i.pop;
endmodule
