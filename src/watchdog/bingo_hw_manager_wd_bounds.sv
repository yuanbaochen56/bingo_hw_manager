// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Per-slot watchdog threshold selector : the one place that decides which threshold a slot uses now. 
module bingo_hw_manager_wd_bounds #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CounterWidth = 24,
    parameter int unsigned HeartbeatTimeoutCycles = 100000,
    parameter int unsigned ConfirmTimeoutCycles = 0,
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter int unsigned WdClassWidth = 3,
    parameter logic [NumCores-1:0][NumClusters-1:0][CoreTypeIdWidth-1:0] CoreTypeId = '0,
    parameter type         data_t = logic [31:0],   // host CSR word of the late threshold
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         wd_learned_t = logic,
    parameter type         wd_bound_t = logic
) (
    input  logic [2**CoreTypeIdWidth-1:0][31:0]                    type_h_i,
    input  logic [2**CoreTypeIdWidth-1:0][31:0]                    type_c_i,
    input  data_t                                                  late_i,          // host late threshold
    input  logic [31:0]                                            risk_confirm_i,  // host risk confirm threshold
    input  logic [NumCores-1:0][NumClusters-1:0]                   risk_i,          // risk bitmap from ctrl_view
    input  wd_learned_t                                            learned_i,
    input  logic [NumCores-1:0][NumClusters-1:0][WdClassWidth-1:0] class_i,         // passed on for the log
    output wd_bound_t                                              bound_o
);
    logic [CounterWidth-1:0] late_global;
    logic [NumCores-1:0][NumClusters-1:0][31:0]               h_static, c_static;
    logic [NumCores-1:0][NumClusters-1:0][CounterWidth-1:0]   late;
    logic [NumCores-1:0][NumClusters-1:0][CounterWidth-1:0]   suspect_eff, confirm_eff, late_eff;
    logic [NumCores-1:0][NumClusters-1:0][1:0]                confirm_src;
    logic [NumCores-1:0][NumClusters-1:0]                     type_c_valid, late_adaptive, risk_valid;

    // Saturate the global late threshold to the counter width
    assign late_global = (late_i > data_t'({CounterWidth{1'b1}})) ?
                         {CounterWidth{1'b1}} : late_i[CounterWidth-1:0];

    // 1. Static bounds: thresholds from host, and must smaller than the parameter itself
    always_comb begin
        for (int c = 0; c < NumCores; c++) begin
            for (int cl = 0; cl < NumClusters; cl++) begin
                automatic int type_id = int'(CoreTypeId[c][cl]);

                h_static[c][cl] = HeartbeatTimeoutCycles;
                if (type_h_i[type_id] != 0 && type_h_i[type_id] <= HeartbeatTimeoutCycles)
                    h_static[c][cl] = type_h_i[type_id];

                type_c_valid[c][cl] = (ConfirmTimeoutCycles != 0 &&
                                       type_c_i[type_id] != 0 &&
                                       type_c_i[type_id] > h_static[c][cl] &&
                                       type_c_i[type_id] <= ConfirmTimeoutCycles);
                c_static[c][cl] = type_c_valid[c][cl] ? type_c_i[type_id] : ConfirmTimeoutCycles;
            end
        end
    end

    // 2. Suspect threshold: learned h if valid, else h_static
    always_comb begin
        for (int c = 0; c < NumCores; c++) begin
            for (int cl = 0; cl < NumClusters; cl++) begin
                suspect_eff[c][cl] = CounterWidth'(
                    learned_i.h_valid[c][cl] ? learned_i.h[c][cl] : h_static[c][cl]);
            end
        end
    end

    // 3. Confirm threshold: pick the shortest among learned c, risk R, and c_static,
    // and the confirm_src is the source of the shortest threshold
    always_comb begin
        for (int c = 0; c < NumCores; c++) begin
            for (int cl = 0; cl < NumClusters; cl++) begin
                automatic logic [31:0] shortest;

                shortest = c_static[c][cl];
                confirm_src[c][cl] = type_c_valid[c][cl] ? bingo_hw_manager_pkg::WdConfirmType :
                                                           bingo_hw_manager_pkg::WdConfirmParam;

                // R replaces c_static while the slot is at risk
                risk_valid[c][cl] = (ConfirmTimeoutCycles != 0 &&
                                     risk_confirm_i > h_static[c][cl] &&
                                     risk_confirm_i < c_static[c][cl]);
                if (risk_i[c][cl] && risk_valid[c][cl]) begin
                    shortest = risk_confirm_i;
                    confirm_src[c][cl] = bingo_hw_manager_pkg::WdConfirmRisk;
                end

                // A learned c applies only if it is shorter still
                if (learned_i.c_valid[c][cl] && learned_i.c[c][cl] < shortest) begin
                    shortest = learned_i.c[c][cl];
                    confirm_src[c][cl] = bingo_hw_manager_pkg::WdConfirmLearned;
                end

                confirm_eff[c][cl] = CounterWidth'(shortest);
            end
        end
    end

    // 4. Late-beat threshold: learned late (if <= late_global) or late_global
    always_comb begin
        for (int c = 0; c < NumCores; c++) begin
            for (int cl = 0; cl < NumClusters; cl++) begin
                late_adaptive[c][cl] = learned_i.late_valid[c][cl] &&
                    (late_global == '0 || learned_i.late[c][cl] <= 32'(late_global));
                late[c][cl] = late_adaptive[c][cl] ?
                    CounterWidth'(learned_i.late[c][cl]) : late_global;
                late_eff[c][cl] = (late[c][cl] != '0) ? late[c][cl] : late_global;
            end
        end
    end

    assign bound_o = '{suspect_eff:   suspect_eff,
                       confirm_eff:   confirm_eff,
                       late_eff:      late_eff,
                       confirm_src:   confirm_src,
                       h_static:      h_static,
                       c_static:      c_static,
                       late:          late,
                       late_adaptive: late_adaptive,
                       risk_valid:    risk_valid,
                       wd_class:      class_i};
endmodule
