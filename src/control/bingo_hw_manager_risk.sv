// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Fault precursors of the control plane (bingo_hw_manager_ctrl): every late
// beat of a slot (late_i, from the watchdog: a heartbeat or done of a busy core
// whose timer had reached the late threshold) adds one to a 4-bit saturating
// count. Every cfg_i.risk_epoch cycles all counts are halved (0 = never), so
// only a high rate of late beats adds up. A count at or above
// cfg_i.risk_thresh (0 = off) makes the slot at risk; that is sticky until the
// host clears it (risk_clear_i) or the slot is fenced. What an at-risk slot
// does is decided elsewhere: the park request in bingo_hw_manager_ctrl, the
// derate level in bingo_hw_manager_level_policy.
module bingo_hw_manager_risk
    import bingo_hw_manager_pkg::*;
#(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Watchdog: confirmed dead slots (sticky), and late beats
    input  logic [NumCores-1:0][NumClusters-1:0]      fenced_i,
    input  logic [NumCores-1:0][NumClusters-1:0]      late_i,
    // Host: clear per slot, count threshold (0 = off) and halving period (0 = never)
    input  logic [NumCores-1:0][NumClusters-1:0]      risk_clear_i,
    input  ctrl_cfg_t                                 cfg_i,

    // At-risk slots
    output logic [NumCores-1:0][NumClusters-1:0]      risk_o,
    // Late-beat count of every slot, and the cycle the counts are halved
    output logic [NumCores-1:0][NumClusters-1:0][3:0] risk_cnt_o,
    output logic                                      risk_epoch_end_o
);

    logic [NumCores-1:0][NumClusters-1:0][3:0] risk_cnt_d, risk_cnt_q;
    logic [NumCores-1:0][NumClusters-1:0]      risk_d, risk_q;
    logic [31:0]                               risk_epoch_cnt_q;
    logic                                      risk_epoch_end;

    assign risk_epoch_end = (cfg_i.risk_epoch != '0) && (risk_epoch_cnt_q >= cfg_i.risk_epoch - 1);

    always_comb begin
        for (int unsigned c = 0; c < NumCores; c++) begin
            for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                automatic logic [3:0] cnt;

                // Halve first, then add this cycle's late beat
                cnt = risk_cnt_q[c][cl];
                if (risk_epoch_end) cnt = cnt >> 1;
                if (late_i[c][cl] && (cnt != 4'hf)) cnt = cnt + 1;

                risk_cnt_d[c][cl] = cnt;
                risk_d[c][cl]     = risk_q[c][cl] ||
                                    ((cfg_i.risk_thresh != '0) && (cnt >= cfg_i.risk_thresh));

                // A clear or a fence wins
                if (fenced_i[c][cl] || risk_clear_i[c][cl]) begin
                    risk_cnt_d[c][cl] = '0;
                    risk_d[c][cl]     = 1'b0;
                end
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            risk_epoch_cnt_q <= '0;
            risk_cnt_q       <= '0;
            risk_q           <= '0;
        end else begin
            // Without epochs (0) the count stays at 0: written (and clocked)
            // only while epochs run, or to clear it once
            if ((cfg_i.risk_epoch != '0) || (risk_epoch_cnt_q != '0))
                risk_epoch_cnt_q <= ((cfg_i.risk_epoch == '0) || risk_epoch_end) ? '0 : risk_epoch_cnt_q + 1;
            risk_cnt_q <= risk_cnt_d;
            risk_q     <= risk_d;
        end
    end
    assign risk_o           = risk_q;
    assign risk_cnt_o       = risk_cnt_q;
    assign risk_epoch_end_o = risk_epoch_end;

endmodule
