`include "bingo_hw_manager/typedef.svh"
`timescale 1ns/1ps
module tb_bingo_hw_manager_wd_adapt_execution;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 0;
    logic [1:0][0:0] dispatch, done, hb, busy, fenced, suspect, progress;
    logic [1:0][0:0][15:0] interval, h_thr, c_thr;
    logic [1:0][0:0][31:0] h_ad, c_ad;
    logic [1:0][0:0] hv, cv;
    logic [31:0] ctrl;
    logic [1:0][0:0][15:0] h_eff, c_eff;
    logic [1:0][0:0][1:0]  c_src;
    for (genvar c = 0; c < 2; c++) begin
        assign h_thr[c][0] = hv[c][0] ? 16'(h_ad[c][0]) : 16'd40000;
        assign c_thr[c][0] = cv[c][0] ? 16'(c_ad[c][0]) : 16'd60000;
        // As bingo_hw_manager_wd_bounds: the learned bounds if valid, else the parameters
        assign h_eff[c][0] = (h_thr[c][0] != '0 || hv[c][0]) ? h_thr[c][0] : 16'd40000;
        assign c_eff[c][0] = (c_thr[c][0] != '0) ? c_thr[c][0] : 16'd60000;
        assign c_src[c][0] = cv[c][0] ? bingo_hw_manager_pkg::WdConfirmLearned :
                             (c_thr[c][0] != '0) ? bingo_hw_manager_pkg::WdConfirmType :
                             bingo_hw_manager_pkg::WdConfirmParam;
    end
    // Port structs of bingo_hw_manager_watchdog
    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(wd_event_t, 2, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(wd_bound_t, 2, 1, 16, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(wd_status_t, 2, 1, 16)
    wd_status_t wd_status;
    assign busy     = wd_status.busy;
    assign fenced   = wd_status.fenced;
    assign suspect  = wd_status.dead_suspect;
    assign progress = wd_status.progress;
    assign interval = wd_status.interval;
    bingo_hw_manager_watchdog #(
        .NumCores(2), .NumClusters(1), .CounterWidth(16), .CoreTypeId({4'd1, 4'd1}),
        .HeartbeatTimeoutCycles(40000), .ConfirmTimeoutCycles(60000),
        .wd_event_t(wd_event_t), .wd_bound_t(wd_bound_t), .wd_status_t(wd_status_t)
    ) wd (
        .clk_i(clk), .rst_ni(rst),
        .event_i('{dispatch: dispatch, done: done, heartbeat: hb, waiting: '0, tick: 2'b11}),
        .bound_i('{suspect: h_thr, confirm: c_thr, suspect_eff: h_eff, confirm_eff: c_eff,
                   confirm_src: c_src, wd_class: {3'd1, 3'd1}, default: '0}),
        .status_o(wd_status)
    );
    // Port structs of bingo_hw_manager_wd_adapt (bingo_hw_manager/typedef.svh)
    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(adapt_event_t, 2, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(adapt_status_t, 2, 1, 16)
    `BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(adapt_task_t, 2, 1, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_LEARNED_T(adapt_learned_t, 2, 1) `BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(adapt_est_t, 2, 1)
    adapt_learned_t adapt_learned;
    assign h_ad = adapt_learned.h;
    assign c_ad = adapt_learned.c;
    assign hv = adapt_learned.h_valid;
    assign cv = adapt_learned.c_valid;
    bingo_hw_manager_wd_adapt #(
        .NumCores(2), .NumClusters(1), .CounterWidth(16), .CoreTypeId({4'd1, 4'd1}),
        .wd_event_t(adapt_event_t), .wd_status_t(adapt_status_t),
        .wd_task_t(adapt_task_t), .wd_learned_t(adapt_learned_t), .wd_est_t(adapt_est_t)
    ) adapt (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i('0),
        .event_i('{dispatch: dispatch, done: done, default: '0}),
        .status_i('{progress: progress, interval: interval, busy: busy,
                   fenced: fenced, default: '0}),
        .task_i('{wd_class: {3'd1, 3'd1}, moved: '0, fast: '0}),
        .h_eff_i({32'd40000, 32'd40000}), .c_eff_i({32'd60000, 32'd60000}), .est_i('0), .learned_o(adapt_learned)
    );
    task automatic step();
        @(posedge clk); #1;
        if (suspect || fenced)
            $fatal(1, "[ADAPT_EXECUTION] healthy execution suspected or fenced");
    endtask
    task automatic ticks(input int count);
        repeat (count) begin step(); @(negedge clk); end
    endtask
    initial begin
        ctrl = 32'h7D0147;
        dispatch = '0; done = '0; hb = '0;
        step();
        @(negedge clk); rst = 1; dispatch = '1;
        step();
        @(negedge clk); dispatch = '0;
        ticks(33);
        hb = '1;
        step();
        if (hv || cv || adapt.table_q[1][1].samples != 0 ||
            adapt.imax_q[0][0] != 33 || adapt.imax_q[1][0] != 33)
            $fatal(1, "[ADAPT_EXECUTION] prologue changed its own thresholds");
        @(negedge clk); hb = '0;
        ticks(8160);
        hb[0][0] = 1;
        step();
        if (hv || adapt.table_q[1][1].samples != 0 || adapt.imax_q[0][0] != 8160)
            $fatal(1, "[ADAPT_EXECUTION] body heartbeat learned before done");
        @(negedge clk); hb = '0; done[0][0] = 1;
        step();
        if (adapt.table_q[1][1].samples != 1 || adapt.table_q[1][1].maximum != 8160 ||
            adapt.table_q[1][1].load != 2 || !hv[1][0] ||
            h_ad[1][0] != 16320 || c_ad[1][0] != 32640)
            $fatal(1, "[ADAPT_EXECUTION] concurrent class did not use completed peer");
        @(negedge clk); done = '0; dispatch[0][0] = 1;
        step();
        if (adapt.imax_q[0][0] != 0 || h_thr[0][0] != 16320 || c_thr[0][0] != 32640)
            $fatal(1, "[ADAPT_EXECUTION] next execution did not reset imax/use body bound");
        @(negedge clk); dispatch = '0; done = '1;
        step();
        if (adapt.table_q[1][1].samples != 3 || adapt.table_q[1][1].maximum != 8163)
            $fatal(1, "[ADAPT_EXECUTION] simultaneous completions lost or N counted segments");
        $display("Adaptive complete-execution tests passed");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "[ADAPT_EXECUTION] timeout");
    end
endmodule
