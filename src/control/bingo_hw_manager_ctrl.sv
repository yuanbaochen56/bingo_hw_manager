// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Control plane of the HW manager: the per-slot state that the placement,
// replay and power policies share, and the decisions that move work between
// cores. The mechanisms (queues, replay engine, PM bus master, CERF register
// file, remote link) stay in their own modules and only read what this module
// decides. The rules are in its submodules:
//   bingo_hw_manager_slot_table     slot mapping table (the substitute of every
//                                   logical slot) and core parking
//   bingo_hw_manager_risk           fault precursors: late-beat counts and
//                                   at-risk slots
//   bingo_hw_manager_power_view     which slots the PM may count as idle, which
//                                   count as load, and the recovery hold
//   bingo_hw_manager_wd_tick        watchdog ticks in cycles of the normal clock
//   bingo_hw_manager_level_policy   boost and derate requests to the PM
//   bingo_hw_manager_cerf_fallback  CERF degradation of a core type that lost
//                                   a slot (stuck or rejected)
// This module joins them and keeps the simulation prints of the control plane
// ([BINGO_RECOVERY_HOLD], [BINGO_LATE], [BINGO_RISK], [BINGO_CERF_FB]).
module bingo_hw_manager_ctrl
    import bingo_hw_manager_pkg::*;
#(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    // Type of each (core, cluster) slot (see bingo_hw_manager_top)
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter logic [NumCores-1:0][NumClusters-1:0][CoreTypeIdWidth-1:0] CoreTypeId =
        {(NumCores * NumClusters){CoreTypeIdWidth'(1)}},
    // Substitute levels (see bingo_hw_manager_top SubstituteLevelMask)
    parameter logic [2:0] SubstituteLevelMask = 3'b001,
    parameter logic [2**CoreTypeIdWidth-1:0] SubstituteL2TypeEn = '1,
    // Substitute choice (see bingo_hw_manager_slot_table) and width of queue_i.load
    parameter int unsigned SubstitutePolicy = 0,
    parameter int unsigned LoadWidth = 4,
    // Parking works (the CSR ready queues); otherwise an at-risk slot is not parked
    parameter bit          ParkSupported = 1'b1,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         slot_state_t = logic,
    parameter type         ctrl_queue_t = logic,
    parameter type         ctrl_host_t = logic,
    parameter type         ctrl_view_t = logic,
    parameter type         type_cfg_t = logic,
    parameter type         smt_t = logic,
    parameter type         park_t = logic,
    parameter type         cerf_fb_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Slot state: fenced (watchdog), retired and stuck (replay), rejected (level 3)
    input  slot_state_t                          slot_i,
    // Late beats of every slot (watchdog)
    input  logic [NumCores-1:0][NumClusters-1:0] late_i,
    // The queues of every slot: waiting, checkout and ready empty, a push this
    // cycle (route, replay, or import), tasks in another slot's queue, load
    input  ctrl_queue_t                          queue_i,
    // Host: per slot (park request, risk clear, power domain), per core type
    // (CERF degradation, fence fallback), and the control plane settings
    input  ctrl_host_t                           host_i,
    input  type_cfg_t                            type_cfg_i,
    input  ctrl_cfg_t                            cfg_i,
    // Power state (bingo_hw_manager_pm), and an external access to a cluster's
    // memory this cycle
    input  pm_view_t                             pm_i,
    input  logic [NumClusters-1:0]               cluster_access_i,
    // The CERF update committed this cycle (host did not write the mask)
    input  logic                                 cerf_fb_done_i,

    // Per slot: idle, boost and derate for the PM, watchdog tick, risk, ...
    output ctrl_view_t                           view_o,
    // Slot mapping table, indexed by logical slot; written this cycle (its
    // readers hold)
    output smt_t                                 smt_o,
    output logic                                 smt_update_o,
    // Parking (bingo_hw_manager_slot_table). fail stays set until that slot's request drops.
    output park_t                                park_o,
    // One CERF degradation, held until cerf_fb_done_i, and the types whose
    // degradation has fired (sticky until that enable drops)
    output cerf_fb_t                             cerf_fb_o,
    output logic [2**CoreTypeIdWidth-1:0]        cerf_fb_evt_o
);

    // ------------------------------------------------------------------
    // Fault precursors: late-beat count per slot, halved every epoch
    // ------------------------------------------------------------------
    // risk_cnt_q, risk_q and risk_epoch_end keep the names that the HeMAiA quad
    // controller and the testbenches read here (i_ctrl.risk_cnt_q, ...): a
    // rename must be made in occamy_quad_ctrl.sv.tpl (QUAD_CTRL_BINGO_*) too.
    logic [NumCores-1:0][NumClusters-1:0][3:0] risk_cnt_q;
    logic [NumCores-1:0][NumClusters-1:0]      risk_q;
    logic                                      risk_epoch_end;
    logic [NumCores-1:0][NumClusters-1:0]      park_req;

    bingo_hw_manager_risk #(
        .NumCores(NumCores),
        .NumClusters(NumClusters)
    ) i_risk (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .fenced_i(slot_i.fenced),
        .late_i(late_i),
        .risk_clear_i(host_i.risk_clear),
        .cfg_i(cfg_i),
        .risk_o(risk_q),
        .risk_cnt_o(risk_cnt_q),
        .risk_epoch_end_o(risk_epoch_end)
    );

    // Host request, or an at-risk slot with the park action
    assign park_req = host_i.park_req |
                      (risk_q & {(NumCores * NumClusters){cfg_i.risk_action[0] && ParkSupported}});
    assign view_o.risk = risk_q;

    // ------------------------------------------------------------------
    // Slot mapping table and core parking
    // ------------------------------------------------------------------
    logic [NumCores-1:0][NumClusters-1:0] smt_recompute;

    bingo_hw_manager_slot_table #(
        .NumCores(NumCores),
        .NumClusters(NumClusters),
        .CoreIdWidth(CoreIdWidth),
        .ClusterIdWidth(ClusterIdWidth),
        .CoreTypeIdWidth(CoreTypeIdWidth),
        .CoreTypeId(CoreTypeId),
        .SubstituteLevelMask(SubstituteLevelMask),
        .SubstituteL2TypeEn(SubstituteL2TypeEn),
        .SubstitutePolicy(SubstitutePolicy),
        .LoadWidth(LoadWidth),
        .slot_state_t(slot_state_t),
        .ctrl_queue_t(ctrl_queue_t),
        .type_cfg_t(type_cfg_t),
        .smt_t(smt_t),
        .park_t(park_t)
    ) i_slot_table (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .slot_i(slot_i),
        .queue_i(queue_i),
        .type_cfg_i(type_cfg_i),
        .sub_cfg_i(cfg_i.sub),
        .park_req_i(park_req),
        .smt_o(smt_o),
        .smt_update_o(smt_update_o),
        .smt_recompute_o(smt_recompute),
        .park_o(park_o)
    );

    // ------------------------------------------------------------------
    // Power and load view, recovery hold
    // ------------------------------------------------------------------
    bingo_hw_manager_power_view #(
        .NumCores(NumCores),
        .NumClusters(NumClusters),
        .slot_state_t(slot_state_t),
        .ctrl_queue_t(ctrl_queue_t),
        .smt_t(smt_t)
    ) i_power_view (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .slot_i(slot_i),
        .queue_i(queue_i),
        .smt_i(smt_o),
        .smt_recompute_i(smt_recompute),
        .cfg_i(cfg_i),
        .cluster_access_i(cluster_access_i),
        .pm_enable_i(pm_i.enable),
        .pm_idle_o(view_o.idle),
        .rec_hold_o(view_o.rec_hold),
        .access_only_o(view_o.access_only),
        .load_clear_o(view_o.load_clear)
    );

    // ------------------------------------------------------------------
    // Frequency-aware watchdog ticks
    // ------------------------------------------------------------------
    bingo_hw_manager_wd_tick #(
        .NumCores(NumCores),
        .NumClusters(NumClusters)
    ) i_wd_tick (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .pm_i(pm_i),
        .slot_domain_i(host_i.domain),
        .wd_tick_o(view_o.wd_tick),
        .wd_fast_o(view_o.wd_fast)
    );

    // ------------------------------------------------------------------
    // Level requests to the PM: boost and derate
    // ------------------------------------------------------------------
    bingo_hw_manager_level_policy #(
        .NumCores(NumCores),
        .NumClusters(NumClusters),
        .CoreTypeIdWidth(CoreTypeIdWidth),
        .CoreTypeId(CoreTypeId),
        .ParkSupported(ParkSupported),
        .slot_state_t(slot_state_t),
        .ctrl_queue_t(ctrl_queue_t),
        .ctrl_host_t(ctrl_host_t),
        .smt_t(smt_t),
        .park_t(park_t)
    ) i_level_policy (
        .slot_i(slot_i),
        .queue_i(queue_i),
        .host_i(host_i),
        .smt_i(smt_o),
        .park_i(park_o),
        .risk_i(risk_q),
        .cfg_i(cfg_i),
        .pm_boost_o(view_o.boost),
        .pm_derate_o(view_o.derate)
    );

    // ------------------------------------------------------------------
    // CERF degradation
    // ------------------------------------------------------------------
    bingo_hw_manager_cerf_fallback #(
        .NumCores(NumCores),
        .NumClusters(NumClusters),
        .CoreTypeIdWidth(CoreTypeIdWidth),
        .CoreTypeId(CoreTypeId),
        .slot_state_t(slot_state_t),
        .type_cfg_t(type_cfg_t),
        .cerf_fb_t(cerf_fb_t)
    ) i_cerf_fallback (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .slot_i(slot_i),
        .type_cfg_i(type_cfg_i),
        .cerf_fb_done_i(cerf_fb_done_i),
        .cerf_fb_o(cerf_fb_o),
        .cerf_fb_evt_o(cerf_fb_evt_o)
    );

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_ni) begin
            for (int c = 0; c < NumCores; c++)
                for (int cl = 0; cl < NumClusters; cl++)
                    if ((i_power_view.rec_hold_q[c][cl] != 0) != (i_power_view.rec_hold_d[c][cl] != 0))
                        $display("[BINGO_RECOVERY_HOLD] %0t core=%0d cluster=%0d active=%0b",
                                 $time, c, cl, i_power_view.rec_hold_d[c][cl] != 0);
        end
    end
    logic [NumCores-1:0][NumClusters-1:0] risk_seen_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            risk_seen_q <= '0;
        end else begin
            risk_seen_q <= risk_q;
            for (int unsigned c = 0; c < NumCores; c++) begin
                for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                    if (late_i[c][cl])
                        $display("[BINGO_LATE] %0t core=%0d cluster=%0d", $time, c, cl);
                    if (risk_q[c][cl] && !risk_seen_q[c][cl])
                        $display("[BINGO_RISK] %0t core=%0d cluster=%0d at risk", $time, c, cl);
                end
            end
        end
    end
`endif

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_ni && cerf_fb_done_i && cerf_fb_o.req) begin
            $display("[BINGO_CERF_FB] %0t type %0d clear g%0d set g%0d",
                     $time, cerf_fb_o.core_type, cerf_fb_o.clear, cerf_fb_o.set);
        end
    end
`endif

endmodule
