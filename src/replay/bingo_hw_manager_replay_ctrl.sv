// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Replay controller: moves the outstanding tasks of a fenced (confirmed dead)
// core to live cores, so that they are executed again.
//
// A core's checkout FIFO holds every task dispatched to it and not yet retired,
// in dispatch order: the head is the task the core was running when it died,
// the rest were queued behind it. The dep checks of these tasks already passed,
// so they are pushed straight into the ready + checkout FIFOs of a substitute.
// Their dep_set still uses the logical core id of the descriptor, so the
// dependents see the same producer as before.
//
// One source core's outstanding tasks are migrated at a time:
//   IDLE   pick the lowest-index fenced core eligible for migration
//          (not retired, not stuck, not waiting for another core's migration)
//   DRAIN  flush its ready FIFO and process dones received before the fence,
//          so completed tasks are not replayed
//   MOVE   check whether to finish, yield to a failed substitute, or wait for
//          the slot mapping table; otherwise apply the selected move_action
//   FINISH mark the source core retired: migration is complete, execution may
//          still be pending on its substitutes
// move_action is combinational: it selects local migration, remote rotation,
// bounce, protection, stuck, or wait without adding an FSM state or cycle.
//
// Level 3 (SubstituteLevelMask[2], remote chiplet): an entry that no live core
// of the chiplet may run is not stuck if its logical core has a non-zero type
// that the transport can export (l3_i.type_en) and the entry was not itself
// imported from another chiplet. MOVE then
// rotates it: pops the source head and pushes it back to its tail (step_o.rotate, marked
// exported), and an executing entry is also copied to the export FIFO
// (step_o.exported). The source stays the proxy: a remote done is pushed into
// its done FIFO and retires the entry at its checkout head, with the normal
// dep_set, once the source is retired. MOVE ends when the head is
// an exported entry (every older entry was moved or rotated). A dummy-set
// entry is rotated without an export, so it still fires after D's earlier
// tasks. The source's done FIFO may already hold remote dones when an aborted
// migration resumes, so DRAIN does not wait for it once an entry was rotated.
// An entry imported from another chiplet that no live core here may run is
// bounced instead of stuck: MOVE pops it without a push (step_o.bounce) and
// bingo_hw_manager_remote_import rejects it to its origin (proxy stuck there).
//
// task_type 11 is executable but cannot be replayed after possibly starting.
// The runtime takes one ready task at a time and sends done before taking the
// next one. Thus only the first executable checkout entry encountered after a
// fence may have started; marked entries behind it can move locally for their
// first execution. Marked entries never rotate/export or bounce: recovery of an
// imported marked task is not defined yet. Blocking is sticky and implies stuck.
module bingo_hw_manager_replay_ctrl #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    // Type of each (core, cluster) slot (same as bingo_hw_manager_core_remap)
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter logic [NumCores-1:0][NumClusters-1:0][CoreTypeIdWidth-1:0] CoreTypeId =
        {(NumCores * NumClusters){CoreTypeIdWidth'(1)}},
    // Substitute levels (see bingo_hw_manager_top SubstituteLevelMask)
    parameter logic [2:0] SubstituteLevelMask = 3'b001,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type        replay_slot_t = logic,
    parameter type        replay_head_t = logic,
    parameter type        replay_l3_t = logic,
    parameter type        smt_t = logic,
    parameter type        replay_step_t = logic,
    parameter type        replay_status_t = logic
) (
    input  logic           clk_i,
    input  logic           rst_ni,
    // Per core: fenced, done empty, checkout empty/full, ready full,
    // and whether its checkout head was imported.
    input  replay_slot_t   slot_i,
    // Per checkout head: logical core/cluster, no_exec (dummy or absorbed exit),
    // no_replay (task_type 11), and exported (Level-3 proxy entry).
    input  replay_head_t   head_i,
    // Level-3 status for the replay controller:
    // - export_ready: the export queue has room for another task of this type
    // - type_en: this core type has an enabled remote export target
    // - bounce_ready: the reject register can accept a bounced entry
    // export_ready and type_en are indexed by CoreTypeId.
    input  replay_l3_t     l3_i,
    // Slot mapping table, indexed by logical core/cluster, and its write cycle.
    input  smt_t           smt_i,
    input  logic           smt_update_i,
    // One MOVE step: pop the source head and push it to the destination.
    // push_ready also queues it for execution; rotate returns it to the source
    // tail, exported copies it to the export FIFO, and bounce only pops it.
    output replay_step_t   step_o,
    // Per core: migration retired, ready flushed, checkout held, stuck,
    // blocked by replay protection, and first executable entry processed.
    output replay_status_t status_o
);
    logic [NumCores-1:0][NumClusters-1:0] ready_flush, moving, hold;
    logic move_fire, push_ready, rotate, exported, bounce;

    localparam bit RemoteEn = SubstituteLevelMask[2];

    typedef enum logic [1:0] {
        IDLE,
        DRAIN,
        MOVE,
        FINISH
    } replay_state_t;

    // Selected from the current head and readiness; not a registered state.
    typedef enum logic [2:0] {
        ACT_WAIT,
        ACT_LOCAL,
        ACT_ROTATE,
        ACT_BOUNCE,
        ACT_BLOCK,
        ACT_STUCK
    } replay_move_action_t;

    replay_move_action_t move_action;
    replay_state_t state_q, state_d;
    logic [CoreIdWidth-1:0]    src_core_q, src_core_d;
    logic [ClusterIdWidth-1:0] src_cluster_q, src_cluster_d;
    logic [NumCores-1:0][NumClusters-1:0] retired_q, retired_d;
    logic [NumCores-1:0][NumClusters-1:0] stuck_q, stuck_d;
    logic [NumCores-1:0][NumClusters-1:0] blocked_q, blocked_d;
    // Set after processing the first executable head; cleared only by reset.
    // Later heads have not started, so marked tasks may still move locally.
    logic [NumCores-1:0][NumClusters-1:0] exec_moved_q, exec_moved_d;
    // used_q[s]: slots that received entries of slot s during its (possibly
    // aborted) migration; cleared when s is retired
    logic [NumCores-1:0][NumClusters-1:0][NumCores-1:0][NumClusters-1:0] used_q, used_d;
    // Set after any rotation; cleared only by reset. On a resumed migration,
    // DRAIN must not wait for remote dones held behind the proxy entries.
    logic [NumCores-1:0][NumClusters-1:0] rotated_q, rotated_d;
    // If a previous substitute fails, migrate its older tasks before resuming
    // this source. If that substitute is stuck, this source is stuck too.
    logic [NumCores-1:0][NumClusters-1:0] wait_used;
    logic [NumCores-1:0][NumClusters-1:0] stuck_used;
    logic [NumCores-1:0][NumClusters-1:0] partly_moved;

    always_comb begin
        for (int unsigned c = 0; c < NumCores; c++) begin
            for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                wait_used[c][cl]    = |(used_q[c][cl] & slot_i.fenced & ~retired_q);
                stuck_used[c][cl]   = |(used_q[c][cl] & stuck_q);
                partly_moved[c][cl] = |used_q[c][cl];
            end
        end
    end

    // Lowest fenced slot that is neither retired nor stuck, nor waits for a
    // slot it partly moved into
    logic                      pending_found;
    logic [CoreIdWidth-1:0]    pending_core;
    logic [ClusterIdWidth-1:0] pending_cluster;

    always_comb begin
        pending_found   = 1'b0;
        pending_core    = '0;
        pending_cluster = '0;
        for (int cl = NumClusters - 1; cl >= 0; cl--) begin
            for (int c = NumCores - 1; c >= 0; c--) begin
                if (slot_i.fenced[c][cl] && !retired_q[c][cl] && !stuck_q[c][cl] &&
                    !wait_used[c][cl]) begin
                    pending_found   = 1'b1;
                    pending_core    = CoreIdWidth'(c);
                    pending_cluster = ClusterIdWidth'(cl);
                end
            end
        end
    end

    // Substitute for the head of the slot being moved, from its logical slot
    // (the entry may already sit in the queue of an earlier substitute)
    logic [CoreIdWidth-1:0]    head_logical_core;
    logic [ClusterIdWidth-1:0] head_logical_cluster;
    logic                      dst_found;
    logic [CoreIdWidth-1:0]    dst_core;
    logic [ClusterIdWidth-1:0] dst_cluster;

    assign head_logical_core    = head_i.logical_core[src_core_q][src_cluster_q];
    assign head_logical_cluster = head_i.logical_cluster[src_core_q][src_cluster_q];

    assign dst_found   = (int'(head_logical_core) < NumCores) && (int'(head_logical_cluster) < NumClusters) &&
                         smt_i.found[head_logical_core][head_logical_cluster];
    assign dst_core    = smt_i.core[head_logical_core][head_logical_cluster];
    assign dst_cluster = smt_i.cluster[head_logical_core][head_logical_cluster];

    logic head_no_exec;
    logic dst_space;
    logic head_exported;
    logic can_rotate;
    logic head_replay_blocked;

    assign head_no_exec  = head_i.no_exec[src_core_q][src_cluster_q];
    assign head_exported = RemoteEn && head_i.exported[src_core_q][src_cluster_q];
    // Remote eligibility, independent of whether the export queue has room.
    assign can_rotate    = RemoteEn && !slot_i.imported[src_core_q][src_cluster_q] &&
                           (CoreTypeId[head_logical_core][head_logical_cluster] != '0) &&
                           l3_i.type_en[CoreTypeId[head_logical_core][head_logical_cluster]];
    assign dst_space    = !slot_i.checkout_full[dst_core][dst_cluster] &&
                          (head_no_exec || !slot_i.ready_full[dst_core][dst_cluster]);

    // Block marked tasks that may have started, or would need unsupported
    // remote recovery. Dummy/absorbed-exit heads do not execute on a core.
    assign head_replay_blocked =
        !head_no_exec &&
        head_i.no_replay[src_core_q][src_cluster_q] &&
        (!exec_moved_q[src_core_q][src_cluster_q] || !dst_found);

    // Select the head's action in priority order. Backpressure keeps ACT_WAIT;
    // it must not fall through to ACT_STUCK. FSM guards below take precedence.
    always_comb begin : move_action_logic
        move_action = ACT_WAIT;

        if (head_replay_blocked) begin
            move_action = ACT_BLOCK;

        end else if (!dst_found && can_rotate) begin
            if (head_no_exec ||
                l3_i.export_ready[CoreTypeId[head_logical_core][head_logical_cluster]]) begin
                move_action = ACT_ROTATE;
            end

        end else if (!dst_found && RemoteEn && slot_i.imported[src_core_q][src_cluster_q]) begin
            if (l3_i.bounce_ready) begin
                move_action = ACT_BOUNCE;
            end

        end else if (!dst_found) begin
            move_action = ACT_STUCK;

        end else if (dst_space) begin
            move_action = ACT_LOCAL;
        end
    end

    always_comb begin
        state_d       = state_q;
        src_core_d    = src_core_q;
        src_cluster_d = src_cluster_q;
        retired_d     = retired_q;
        stuck_d       = stuck_q;
        blocked_d     = blocked_q;
        exec_moved_d  = exec_moved_q;
        used_d        = used_q;
        rotated_d     = rotated_q;
        rotate        = 1'b0;
        exported      = 1'b0;
        bounce        = 1'b0;

        // A partly moved slot waiting for a stuck slot can never resume
        for (int unsigned c = 0; c < NumCores; c++) begin
            for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                if (slot_i.fenced[c][cl] && !retired_q[c][cl] && stuck_used[c][cl]) begin
                    stuck_d[c][cl] = 1'b1;
                end
            end
        end

        ready_flush   = '0;
        moving        = '0;
        move_fire     = 1'b0;
        push_ready    = 1'b0;

        case (state_q)
            IDLE: begin
                if (pending_found) begin
                    src_core_d    = pending_core;
                    src_cluster_d = pending_cluster;
                    state_d       = DRAIN;
                end
            end
            DRAIN: begin
                ready_flush[src_core_q][src_cluster_q] = 1'b1;
                if (slot_i.done_empty[src_core_q][src_cluster_q] || rotated_q[src_core_q][src_cluster_q]) begin
                    state_d = MOVE;
                end
            end
            MOVE: begin
                moving[src_core_q][src_cluster_q] = 1'b1;
                if (slot_i.checkout_empty[src_core_q][src_cluster_q] || head_exported) begin
                    // No unprocessed heads remain; exported heads are proxies.
                    state_d = FINISH;
                end else if (wait_used[src_core_q][src_cluster_q]) begin
                    // Let IDLE select the failed substitute and migrate it first.
                    state_d = IDLE;
                end else if (smt_update_i) begin
                    // Stay here until the substitute mapping is stable.
                    state_d = MOVE;
                end else begin
                    // Apply the action selected for this head.
                    case (move_action)
                        ACT_LOCAL: begin
                            move_fire  = 1'b1;
                            push_ready = !head_no_exec;
                            used_d[src_core_q][src_cluster_q][dst_core][dst_cluster] = 1'b1;
                        end
                        ACT_ROTATE: begin
                            move_fire = 1'b1;
                            rotate    = 1'b1;
                            exported  = !head_no_exec;
                            rotated_d[src_core_q][src_cluster_q] = 1'b1;
                        end
                        ACT_BOUNCE: begin
                            move_fire = 1'b1;
                            bounce    = 1'b1;
                        end
                        ACT_BLOCK, ACT_STUCK: begin
                            stuck_d[src_core_q][src_cluster_q] = 1'b1;
                            if (move_action == ACT_BLOCK) begin
                                blocked_d[src_core_q][src_cluster_q] = 1'b1;
                            end
                            state_d = IDLE;
                        end
                        default: begin
                            // ACT_WAIT: keep the default inactive outputs.
                            state_d = MOVE;
                        end
                    endcase
                end
            end
            FINISH: begin
                retired_d[src_core_q][src_cluster_q] = 1'b1;
                used_d[src_core_q][src_cluster_q]    = '0;
                state_d = IDLE;
            end
            default: state_d = IDLE;
        endcase
        if (move_fire && !head_no_exec) begin
            exec_moved_d[src_core_q][src_cluster_q] = 1'b1;
        end
    end

    assign status_o = '{retired:     retired_q,
                        ready_flush: ready_flush,
                        hold:        hold,
                        stuck:       stuck_q,
                        blocked:     blocked_q,
                        exec_moved:  exec_moved_q};
    always_comb begin
        for (int unsigned c = 0; c < NumCores; c++) begin
            for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                hold[c][cl] = moving[c][cl] ||
                              (slot_i.fenced[c][cl] && !retired_q[c][cl] && partly_moved[c][cl]);
            end
        end
    end
    assign step_o = '{move:        moving,
                      fire:        move_fire,
                      push_ready:  push_ready,
                      bounce:      bounce,
                      rotate:      rotate,
                      exported:    exported,
                      src_core:    src_core_q,
                      src_cluster: src_cluster_q,
                      dst_core:    rotate ? src_core_q : dst_core,
                      dst_cluster: rotate ? src_cluster_q : dst_cluster};

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q       <= IDLE;
            src_core_q    <= '0;
            src_cluster_q <= '0;
            retired_q     <= '0;
            stuck_q       <= '0;
            blocked_q     <= '0;
            exec_moved_q  <= '0;
            used_q        <= '0;
            rotated_q     <= '0;
        end else begin
            state_q       <= state_d;
            src_core_q    <= src_core_d;
            src_cluster_q <= src_cluster_d;
            retired_q     <= retired_d;
            stuck_q       <= stuck_d;
            blocked_q     <= blocked_d;
            exec_moved_q  <= exec_moved_d;
            used_q        <= used_d;
            rotated_q     <= rotated_d;
        end
    end

endmodule
