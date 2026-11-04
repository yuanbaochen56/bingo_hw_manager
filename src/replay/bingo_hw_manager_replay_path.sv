// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Data path of task replay: what the replay controller
// (bingo_hw_manager_replay_ctrl) sees of each checkout head, and what one of
// its MOVE steps does to the queues of the slots.
//
// Each checkout head is presented by its logical slot and kind: it runs on no
// core (a dummy, or an exit that is absorbed when it moves), it must not be
// replayed (task_type 11), or it was exported by this slot (level 3).
// An exit task is absorbed into a dummy when it would leave its own logical
// slot: its slot has a substitute elsewhere, or no substitute but level 3
// may export its type (and it was not imported). Its own core then still
// sees its exit, and the substitute is not stopped by another core's exit.
//
// A MOVE step pops the head of the source slot and pushes it into the
// destination ; a bounced imported entry is only popped. The moved entry is the source head,
// an absorbed exit rewritten as a dummy.
module bingo_hw_manager_replay_path #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter logic [NumCores-1:0][NumClusters-1:0][CoreTypeIdWidth-1:0] CoreTypeId =
        {(NumCores * NumClusters){CoreTypeIdWidth'(1)}},
    parameter bit          RemoteEn = 1'b0,
    parameter type         task_desc_t = logic,   // bingo_hw_manager_task_desc_t of the top
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         checkout_t = logic,
    parameter type         smt_t = logic,
    parameter type         slot_state_t = logic,
    parameter type         replay_head_t = logic,
    parameter type         replay_step_t = logic,
    parameter type         replay_op_t = logic
) (
    // Checkout heads (the head, its side tag, imported)
    input  checkout_t                     checkout_i,
    // Substitute of each logical slot (bingo_hw_manager_slot_table), and the
    // core types level 3 may export
    input  smt_t                          smt_i,
    input  logic [2**CoreTypeIdWidth-1:0] remote_type_en_i,
    // The heads to the replay controller
    output replay_head_t                  head_o,
    // Core state, for the pending replay
    input  slot_state_t                   slot_i,
    // A MOVE step of the replay controller
    input  replay_step_t                  step_i,
    // ... the head it moves, and what it does to the queues
    output replay_op_t                    op_o,
    // A core is fenced, neither retired nor stuck; a MOVE may push into a cluster
    output logic                          pending_o,
    output logic [NumClusters-1:0]        move_cluster_o
);
    import bingo_hw_manager_pkg::*;

    logic [NumCores-1:0][NumClusters-1:0][CoreIdWidth-1:0]    head_logical_core;
    logic [NumCores-1:0][NumClusters-1:0][ClusterIdWidth-1:0] head_logical_cluster;
    logic [NumCores-1:0][NumClusters-1:0]                     head_no_exec, head_no_replay, head_exported;
    task_desc_t                                               data;
    logic                                                     exit_absorb;
    logic [NumCores-1:0][NumClusters-1:0]                     pop, push, push_ready;


     // Parts of head_exit_absorb, per checkout head
    logic [NumCores-1:0][NumClusters-1:0] head_exec_exit;      // an exit that would run on a core
    logic [NumCores-1:0][NumClusters-1:0] head_sub_elsewhere;  // L1/L2: substitute is another slot
    logic [NumCores-1:0][NumClusters-1:0] head_l3_export;      // no substitute, but L3 may export it
    logic [NumCores-1:0][NumClusters-1:0] head_exit_absorb;

    always_comb begin : compose_replay_inputs
        for (int unsigned c = 0; c < NumCores; c++) begin
            for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                automatic int logical_core    = int'(checkout_i.head[c][cl].assigned_core_id);
                automatic int logical_cluster = int'(checkout_i.head[c][cl].assigned_cluster_id);
                head_exported[c][cl]        = checkout_i.head_tag[c][cl].exported;
                head_logical_core[c][cl]    = checkout_i.head[c][cl].assigned_core_id;
                head_logical_cluster[c][cl] = checkout_i.head[c][cl].assigned_cluster_id;
                //
                head_exec_exit[c][cl]     = checkout_i.head[c][cl].is_exit &&
                                            checkout_i.head[c][cl].task_type != TaskDummy;
                head_sub_elsewhere[c][cl] = 1'b0;   // defaults: every path assigns (no latch)
                head_l3_export[c][cl]     = 1'b0;
                if (logical_core < NumCores && logical_cluster < NumClusters) begin
                    head_sub_elsewhere[c][cl] =
                        smt_i.found[logical_core][logical_cluster] &&
                        ((smt_i.core[logical_core][logical_cluster]    != logical_core) ||
                         (smt_i.cluster[logical_core][logical_cluster] != logical_cluster));
                    head_l3_export[c][cl] =
                        RemoteEn &&
                        !smt_i.found[logical_core][logical_cluster] &&
                        !checkout_i.head_imported[c][cl] &&
                        CoreTypeId[logical_core][logical_cluster] != '0 &&
                        remote_type_en_i[CoreTypeId[logical_core][logical_cluster]];
                end
                head_exit_absorb[c][cl] = head_exec_exit[c][cl] &&
                                          (head_sub_elsewhere[c][cl] || head_l3_export[c][cl]);

                head_no_exec[c][cl]   = (checkout_i.head[c][cl].task_type == TaskDummy) ||
                                        head_exit_absorb[c][cl];
                head_no_replay[c][cl] = (checkout_i.head[c][cl].task_type == TaskNoReplay);
            end
        end
    end

    //
    assign exit_absorb = head_exit_absorb[step_i.src_core][step_i.src_cluster];
    always_comb begin
        data = checkout_i.head[step_i.src_core][step_i.src_cluster];
        if (exit_absorb) data.task_type = TaskDummy;
    end

    always_comb begin : compose_replay_signals
        pop            = '0;
        push           = '0;
        push_ready     = '0;
        pending_o      = 1'b0;
        move_cluster_o = '0;
        if (step_i.fire) begin
            pop[step_i.src_core][step_i.src_cluster] = 1'b1;
            // Level 3: a bounced (rejected) imported entry is only dropped
            if (!step_i.bounce) begin
                push[step_i.dst_core][step_i.dst_cluster]       = 1'b1;
                push_ready[step_i.dst_core][step_i.dst_cluster] = step_i.push_ready;
            end
        end
        // Nothing is routed into the slot being moved (fenced, not retired), only
        // into its current destination, which may be in another cluster.
        if (|step_i.move) begin
            move_cluster_o[step_i.dst_cluster] = 1'b1;
        end
        for (int unsigned cl = 0; cl < NumClusters; cl++) begin
            for (int unsigned c = 0; c < NumCores; c++) begin
        //
                if (slot_i.fenced[c][cl] && !slot_i.retired[c][cl] && !slot_i.stuck[c][cl]) begin
                    pending_o = 1'b1;
                end
            end
        end
    end

    assign head_o = '{logical_core:    head_logical_core,
                      logical_cluster: head_logical_cluster,
                      no_exec:         head_no_exec,
                      no_replay:       head_no_replay,
                      exported:        head_exported};
    assign op_o   = '{data: data, exit_absorb: exit_absorb, pop: pop, push: push, push_ready: push_ready};
endmodule
