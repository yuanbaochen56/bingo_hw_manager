`include "bingo_hw_manager/typedef.svh"
`timescale 1ns/1ps
module tb_bingo_hw_manager_wd_adapt_boundary;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 0;
    logic [0:0][0:0] dispatch, done, hb, ticks, busy, fenced, suspect, progress;
    logic [0:0][0:0][7:0] interval;
    logic [0:0][0:0][31:0] h_ad, c_ad;
    logic [0:0][0:0] hv, cv;
    logic [0:0][0:0][7:0] h_thr, c_thr;
    logic [31:0] ctrl;
    assign h_thr = hv ? 8'(h_ad) : 8'd40;
    assign c_thr = cv ? 8'(c_ad) : 8'd100;
    // Port structs of bingo_hw_manager_watchdog
    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(wd_event_t, 1, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(wd_bound_t, 1, 1, 8, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(wd_status_t, 1, 1, 8)
    wd_status_t wd_status;
    assign busy     = wd_status.busy;
    assign fenced   = wd_status.fenced;
    assign suspect  = wd_status.dead_suspect;
    assign progress = wd_status.progress;
    assign interval = wd_status.interval;
    bingo_hw_manager_watchdog #(
        .NumCores(1), .NumClusters(1), .CounterWidth(8),
        .HeartbeatTimeoutCycles(40), .ConfirmTimeoutCycles(100), .CoreTypeId(4'd1),
        .wd_event_t(wd_event_t), .wd_bound_t(wd_bound_t), .wd_status_t(wd_status_t)
    ) wd (
        .clk_i(clk), .rst_ni(rst),
        .event_i('{dispatch: dispatch, done: done, heartbeat: hb, waiting: '0, tick: ticks}),
        // As bingo_hw_manager_wd_bounds: the learned bounds if valid, else the parameters
        .bound_i('{suspect: h_thr, confirm: c_thr,
                   suspect_eff: (h_thr != '0 || hv) ? h_thr : 8'd40,
                   confirm_eff: (c_thr != '0) ? c_thr : 8'd100,
                   confirm_src: cv ? bingo_hw_manager_pkg::WdConfirmLearned :
                                (c_thr != '0) ? bingo_hw_manager_pkg::WdConfirmType :
                                bingo_hw_manager_pkg::WdConfirmParam,
                   wd_class: 3'd1, default: '0}),
        .status_o(wd_status)
    );
    // Port structs of bingo_hw_manager_wd_adapt (bingo_hw_manager/typedef.svh)
    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(adapt_event_t, 1, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(adapt_status_t, 1, 1, 8)
    `BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(adapt_task_t, 1, 1, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_LEARNED_T(adapt_learned_t, 1, 1) `BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(adapt_est_t, 1, 1)
    adapt_learned_t adapt_learned;
    assign h_ad = adapt_learned.h;
    assign c_ad = adapt_learned.c;
    assign hv = adapt_learned.h_valid;
    assign cv = adapt_learned.c_valid;
    bingo_hw_manager_wd_adapt #(
        .NumCores(1), .NumClusters(1), .CounterWidth(8), .CoreTypeId(4'd1),
        .wd_event_t(adapt_event_t), .wd_status_t(adapt_status_t),
        .wd_task_t(adapt_task_t), .wd_learned_t(adapt_learned_t), .wd_est_t(adapt_est_t)
    ) adapt (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i('0),
        .event_i('{dispatch: dispatch, done: done, default: '0}),
        .status_i('{progress: progress, interval: interval, busy: busy,
                   fenced: fenced, default: '0}),
        .task_i('{wd_class: 3'd1, moved: '0, fast: '0}),
        .h_eff_i(32'd40), .c_eff_i(32'd100), .est_i('0), .learned_o(adapt_learned)
    );
    task automatic step();
        @(posedge clk); #1;
    endtask
    task automatic setup();
        @(negedge clk);
        rst = 0; dispatch = 0; done = 0; hb = 0; ticks = 1;
        ctrl = (5 << 12) | (1 << 8) | (2 << 5) | (1 << 2) | 1;
        step();
        @(negedge clk); rst = 1; dispatch = 1;
        step();
        @(negedge clk); dispatch = 0;
        repeat (4) begin step(); @(negedge clk); end
        hb = 1;
        #1;
        if (!progress || interval != 4)
            $fatal(1, "[ADAPT_BOUNDARY] wrong timer snapshot");
        step();
        if (hv || adapt.table_q[1][1].samples != 0 || wd.timer_q[0][0] != 0)
            $fatal(1, "[ADAPT_BOUNDARY] heartbeat learned incomplete execution");
        @(negedge clk); hb = 0; done = 1;
        step();
        if (!hv || h_ad != 8 || c_ad != 16 || adapt.table_q[1][1].samples != 1)
            $fatal(1, "[ADAPT_BOUNDARY] done learning did not take effect within one edge");
        @(negedge clk); done = 0; dispatch = 1;
        step();
        @(negedge clk); dispatch = 0;
    endtask
    initial begin
        for (int completion = 0; completion < 2; completion++) begin
            setup();
            repeat (16) begin step(); @(negedge clk); end
            if (wd.timer_q[0][0] != 16 || fenced)
                $fatal(1, "[ADAPT_BOUNDARY] missed C_ad boundary");
            if (completion) done = 1;
            else hb = 1;
            step();
            if (fenced || suspect || wd.timer_q[0][0] != 0)
                $fatal(1, "[ADAPT_BOUNDARY] done/heartbeat lost fence priority");
        end
        setup();
        for (int cycle = 1; cycle <= 34; cycle++) begin
            ticks = cycle % 2 == 1;
            step();
            if (suspect !== (cycle >= 15) || fenced !== (cycle >= 32))
                $fatal(1, "[ADAPT_BOUNDARY] two-cycle ticks cycle=%0d", cycle);
            @(negedge clk);
        end
        hb = 1; done = 1;
        #1;
        if (progress)
            $fatal(1, "[ADAPT_BOUNDARY] fenced progress escaped");
        step();
        if (adapt.table_q[1][1].samples != 1 || adapt.table_q[1][1].maximum != 4)
            $fatal(1, "[ADAPT_BOUNDARY] fenced termination interval learned");
        setup();
        dispatch = 1; hb = 1;
        #1;
        if (progress)
            $fatal(1, "[ADAPT_BOUNDARY] heartbeat at dispatch was learned");
        step();
        if (adapt.table_q[1][1].samples != 1 || wd.timer_q[0][0] != 0)
            $fatal(1, "[ADAPT_BOUNDARY] dispatch priority changed");
        @(negedge clk);
        rst = 0; dispatch = 0; done = 0; hb = 0; ticks = 1;
        ctrl = (1 << 8) | 1; // floor=0, shifts=0
        step();
        @(negedge clk); rst = 1; dispatch = 1;
        step();
        @(negedge clk); dispatch = 0; done = 1;
        step();
        if (adapt.table_q[1][1].maximum != 0 || adapt.table_q[1][1].samples != 1 ||
            hv || cv || suspect || fenced || h_thr != 40 || c_thr != 100)
            $fatal(1, "[ADAPT_BOUNDARY] M=0/floor=0 did not retain static thresholds");
        @(negedge clk); done = 0; dispatch = 1;
        step();
        @(negedge clk); dispatch = 0;
        repeat (10) begin step(); @(negedge clk); end
        if (hv || cv || suspect || fenced)
            $fatal(1, "[ADAPT_BOUNDARY] zero interval triggered suspicion");
        ctrl[31:12] = 5;
        #1;
        if (hv || cv || h_thr != 40 || c_thr != 100)
            $fatal(1, "[ADAPT_BOUNDARY] floor incorrectly validated M=0");
        done = 1;
        step();
        if (!hv || !cv || h_ad != 10 || c_ad != 20)
            $fatal(1, "[ADAPT_BOUNDARY] positive sample did not enable adaptation");
        $display("Adaptive watchdog boundary tests passed");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "[ADAPT_BOUNDARY] timeout");
    end
endmodule
