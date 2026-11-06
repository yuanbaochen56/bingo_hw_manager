// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Power and load view of the slots for the control plane (bingo_hw_manager_ctrl).
// The idle view of a slot for the PM, in this order: raw idle (polling for a
// task, exited, or fenced) -> idle entry delay -> external access wake and
// recovery hold, either of which keeps the slot awake -> pm_idle_o.
// Fault-aware: a fenced slot is dead, so it counts as idle and no longer keeps
// its power domain at the normal level, and it no longer counts as load
// (load_clear_o). A slot that is only dead_suspect may still be working and
// keeps both.
// Idle entry delay (cfg_i.idle_delay, host-configured): a slot only counts as
// idle for the PM once it has been idle for that many cycles, so a domain only
// drops to the idle level after all its slots were idle that long. Short gaps
// between tasks then keep the normal level and avoid the wake-up cost; 0 =
// at once (the PM's own behaviour). The idle count only runs as far as the
// delay: then, or at once with a delay of 0 or the idle PM off, it jumps to
// all ones and stays there for the rest of the idle period, so it does not
// switch on every idle cycle. With the delay and the PM enable unchanged
// during an idle period the PM sees the same idle view as with a full count.
// If they change while a slot is idle and its count is already all ones, the
// slot stays idle: raising the delay (or turning the PM on) then applies from
// the slot's next idle period, never waking an idle slot.
// External access wake (cfg_i.access_hold, host-configured): a cluster whose
// memory is accessed from outside (cluster_access_i, e.g. the host reading its
// L1) runs on its own clock, so while it is accessed, and for that many cycles
// after the last access, none of its slots counts as idle, not even a fenced
// one. The access path is not held at the idle level; 0 = off. This only ever
// makes a slot idle later: the idle entry delay keeps counting the core's own
// polling, so once the hold ends a long idle core lets its domain drop at once.
// Recovery hold (cfg_i.recovery_hold, host-configured, 0 = off): a fence writes
// the slot mapping table first. On the following edge the live substitute of
// the fenced slot (unless that logical slot has already retired) does not
// count as idle for that many cycles, the recovery window. Entries rewritten
// because their substitute was fenced again load their new substitute the same
// way.
module bingo_hw_manager_power_view
    import bingo_hw_manager_pkg::*;
#(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         slot_state_t = logic,
    parameter type         ctrl_queue_t = logic,
    parameter type         smt_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Slot state: fenced (dead), retired (no task left)
    input  slot_state_t                          slot_i,
    // Queues: waiting (polling the ready queue: idle)
    input  ctrl_queue_t                          queue_i,
    // Slot mapping table, indexed by logical slot, and the entries written
    // this cycle
    input  smt_t                                 smt_i,
    input  logic [NumCores-1:0][NumClusters-1:0] smt_recompute_i,
    // Host: idle entry delay, access hold and recovery hold (0: off); and an
    // external access to a cluster's memory this cycle
    input  ctrl_cfg_t                            cfg_i,
    input  logic [NumClusters-1:0]               cluster_access_i,
    // Power manager: idle PM on (else nothing reads the idle view)
    input  logic                                 pm_enable_i,

    // Power manager: slots that do not keep their domain at the normal level
    output logic [NumCores-1:0][NumClusters-1:0] pm_idle_o,
    // Post-edge recovery activity for the event logger (not a PM input).
    output logic [NumCores-1:0][NumClusters-1:0] rec_hold_o,
    // Slots otherwise PM-idle, awake only because their cluster is accessed.
    output logic [NumCores-1:0][NumClusters-1:0] access_only_o,
    // Load monitor: slots whose pending count is cleared
    output logic [NumCores-1:0][NumClusters-1:0] load_clear_o
);

    // ------------------------------------------------------------------
    // Recovery hold
    // ------------------------------------------------------------------
    // A fence writes the SMT first. On the following edge, load its current
    // live substitute, unless the logical slot has already retired. Include
    // affected dead entries when their previous substitute is fenced again.
    logic [NumCores-1:0][NumClusters-1:0] rec_pending_q, rec_pending_d, rec_load;
    logic [NumCores-1:0][NumClusters-1:0][31:0] rec_hold_q, rec_hold_d;
    always_comb begin
        rec_load = '0;
        for (int c = 0; c < NumCores; c++) begin
            for (int cl = 0; cl < NumClusters; cl++) begin
                if (rec_pending_q[c][cl] && !slot_i.retired[c][cl] && smt_i.found[c][cl] &&
                    !slot_i.fenced[smt_i.core[c][cl]][smt_i.cluster[c][cl]])
                    rec_load[smt_i.core[c][cl]][smt_i.cluster[c][cl]] = 1'b1;
            end
        end
        for (int c = 0; c < NumCores; c++) begin
            for (int cl = 0; cl < NumClusters; cl++) begin
                rec_hold_d[c][cl] = rec_hold_q[c][cl];
                if (slot_i.fenced[c][cl]) rec_hold_d[c][cl] = '0;
                else if (rec_load[c][cl] && cfg_i.recovery_hold != 0)
                    rec_hold_d[c][cl] = cfg_i.recovery_hold;
                else if (rec_hold_q[c][cl] != 0)
                    rec_hold_d[c][cl] = rec_hold_q[c][cl] - 32'd1;
                // The logger samples this on the very edge the count changes,
                // so pending-event ages refer to load/zero, not one edge later.
                rec_hold_o[c][cl] = rec_hold_d[c][cl] != 0;
            end
        end
    end
    // Fences are rare: the pending bits are written (and clocked) only when
    // they change
    assign rec_pending_d = smt_recompute_i & slot_i.fenced & ~slot_i.retired;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rec_pending_q <= '0;
            rec_hold_q <= '0;
        end else begin
            if (rec_pending_d != rec_pending_q) rec_pending_q <= rec_pending_d;
            rec_hold_q <= rec_hold_d;
        end
    end

    // ------------------------------------------------------------------
    // Fault-aware power and load view
    // ------------------------------------------------------------------
    // Clusters accessed from outside within the last cfg_i.access_hold cycles
    logic [NumClusters-1:0]       cluster_awake;
    logic [NumClusters-1:0][31:0] access_cnt_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            access_cnt_q <= '0;
        end else begin
            for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                if (cluster_access_i[cl])        access_cnt_q[cl] <= cfg_i.access_hold;
                else if (access_cnt_q[cl] != '0) access_cnt_q[cl] <= access_cnt_q[cl] - 32'd1;
            end
        end
    end
    for (genvar cl = 0; cl < NumClusters; cl++) begin : gen_cluster_awake
        assign cluster_awake[cl] = (cfg_i.access_hold != '0) && (cluster_access_i[cl] || (access_cnt_q[cl] != '0));
    end
    logic [NumCores-1:0][NumClusters-1:0]       slot_idle;
    logic [NumCores-1:0][NumClusters-1:0][31:0] idle_cnt_q;
    logic                                       idle_count_en;
    assign slot_idle = queue_i.waiting | slot_i.fenced;
    // Something to count: a delay, and a PM that reads the result
    assign idle_count_en = pm_enable_i && (cfg_i.idle_delay != '0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            idle_cnt_q <= '0;
        end else begin
            for (int unsigned c = 0; c < NumCores; c++) begin
                for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                    if (!slot_idle[c][cl]) begin
                        if (idle_cnt_q[c][cl] != '0) idle_cnt_q[c][cl] <= '0;
                    end else if (idle_cnt_q[c][cl] != '1) begin
                        // Idle long enough (or nothing to count): all ones, then still
                        if (!idle_count_en || (idle_cnt_q[c][cl] >= cfg_i.idle_delay))
                            idle_cnt_q[c][cl] <= '1;
                        else
                            idle_cnt_q[c][cl] <= idle_cnt_q[c][cl] + 32'd1;
                    end
                end
            end
        end
    end
    always_comb begin
        for (int unsigned c = 0; c < NumCores; c++) begin
            for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                pm_idle_o[c][cl] = slot_idle[c][cl] && (idle_cnt_q[c][cl] >= cfg_i.idle_delay) && !cluster_awake[cl];
                access_only_o[c][cl] = slot_idle[c][cl] && (idle_cnt_q[c][cl] >= cfg_i.idle_delay) &&
                                       cluster_awake[cl] && rec_hold_q[c][cl] == 0;
                pm_idle_o[c][cl] &= rec_hold_q[c][cl] == 0;
            end
        end
    end
    assign load_clear_o = slot_i.fenced;

endmodule
