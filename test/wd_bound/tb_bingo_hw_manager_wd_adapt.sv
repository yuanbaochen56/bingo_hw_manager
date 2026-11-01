`include "bingo_hw_manager/typedef.svh"
`timescale 1ns/1ps
module tb_bingo_hw_manager_wd_adapt;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 0;
    logic [31:0] ctrl;
    logic [4:0][0:0] progress, dispatch, done, fenced, busy;
    logic [4:0][0:0][15:0] interval;
    logic [4:0][0:0][2:0] classes;
    logic [4:0][0:0][31:0] h_eff, c_eff, h_ad, c_ad;
    logic [4:0][0:0] hv, cv;

    // Port structs of bingo_hw_manager_wd_adapt (bingo_hw_manager/typedef.svh)
    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(adapt_event_t, 5, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(adapt_status_t, 5, 1, 16)
    `BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(adapt_task_t, 5, 1, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_LEARNED_T(adapt_learned_t, 5, 1) `BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(adapt_est_t, 5, 1)
    adapt_learned_t adapt_learned;
    assign h_ad = adapt_learned.h;
    assign c_ad = adapt_learned.c;
    assign hv = adapt_learned.h_valid;
    assign cv = adapt_learned.c_valid;
    bingo_hw_manager_wd_adapt #(
        .NumCores(5), .NumClusters(1), .CounterWidth(16),
        .CoreMask(5'b01111), .CoreTypeId({4'd1, 4'd4, 4'd2, 4'd1, 4'd1}),
        .wd_event_t(adapt_event_t), .wd_status_t(adapt_status_t),
        .wd_task_t(adapt_task_t), .wd_learned_t(adapt_learned_t), .wd_est_t(adapt_est_t)
    ) dut (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i('0),
        .event_i('{dispatch: dispatch, done: done, default: '0}),
        .status_i('{progress: progress, interval: interval, busy: busy,
                   fenced: fenced, default: '0}),
        .task_i('{wd_class: classes, moved: '0, fast: '0}),
        .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i('0), .learned_o(adapt_learned)
    );

    function automatic logic [31:0] config_word(
        input bit en = 1, guard = 1, input int sh_h = 1, sh_c = 2,
        warmup = 3, floor_ticks = 5);
        return (floor_ticks << 12) | (warmup << 8) | (sh_c << 5) |
               (sh_h << 2) | (int'(guard) << 1) | int'(en);
    endfunction

    task automatic step();
        @(posedge clk); #1;
    endtask

    task automatic reset();
        @(negedge clk);
        rst = 0; progress = '0; dispatch = '0; done = '0;
        fenced = '0; busy = '0; interval = '0; classes = '0;
        ctrl = config_word();
        for (int c = 0; c < 5; c++) begin
            h_eff[c][0] = 100; c_eff[c][0] = 200;
        end
        step();
        @(negedge clk); rst = 1;
        step();
    endtask

    task automatic sample(input int core, x, cls, load = 1);
        @(negedge clk);
        progress = '0; dispatch = '0; done = '0; busy = '0;
        busy[core][0] = 1;
        for (int c = 0; c < load-1; c++) busy[c+1][0] = 1;
        classes[core][0] = 3'(cls);
        dispatch[core][0] = 1;
        step();
        @(negedge clk); dispatch = '0;
        interval[core][0] = 16'(x);
        progress[core][0] = 1;
        done[core][0] = 1;
        step();
        @(negedge clk); progress = '0; done = '0;
    endtask

    task automatic check_bound(input int core, h, c, input bit hvalid = 1, cvalid = 1);
        #1;
        if (hv[core][0] !== hvalid || cv[core][0] !== cvalid ||
            (hvalid && h_ad[core][0] != h) || (hvalid && c_ad[core][0] != c))
            $fatal(1, "[ADAPT_TB] core=%0d H=%0d C=%0d valid=%0b/%0b expected=%0d/%0d %0b/%0b",
                   core, h_ad[core][0], c_ad[core][0], hv[core][0], cv[core][0],
                   h, c, hvalid, cvalid);
    endtask

    initial begin
        reset();
        ctrl = config_word(1, 0, 1, 2, 1);
        @(negedge clk);
        classes[0][0] = 1; dispatch[0][0] = 1; busy[0][0] = 1;
        step();
        @(negedge clk);
        dispatch = '0; progress[0][0] = 1; interval[0][0] = 3;
        step();
        if (dut.table_q[1][1].samples != 0 || dut.imax_q[0][0] != 3 || hv[0][0])
            $fatal(1, "[ADAPT_TB] heartbeat learned an incomplete execution");
        @(negedge clk); interval[0][0] = 60;
        step();
        if (dut.table_q[1][1].samples != 0 || dut.imax_q[0][0] != 60)
            $fatal(1, "[ADAPT_TB] body heartbeat learned or lost segment maximum");
        @(negedge clk); interval[0][0] = 2; done[0][0] = 1;
        step();
        if (dut.table_q[1][1].samples != 1 || dut.table_q[1][1].maximum != 60)
            $fatal(1, "[ADAPT_TB] completion did not learn the body segment");
        check_bound(0, 100, 200);
        reset();
        sample(0, 5, 1);
        check_bound(0, 0, 0, 0, 0);
        sample(0, 3, 1);
        check_bound(0, 0, 0, 0, 0);
        sample(0, 8, 1);
        check_bound(0, 16, 32);
        if (dut.table_q[1][1].maximum != 8 || dut.table_q[1][1].samples != 3 ||
            dut.table_q[1][1].load != 1)
            $fatal(1, "[ADAPT_TB] M/N/L or exact warmup transition");
        repeat (20) sample(0, 1, 1);
        if (dut.table_q[1][1].samples != 15 || dut.table_q[1][1].maximum != 8)
            $fatal(1, "[ADAPT_TB] saturation or monotonic max");
        sample(0, 99, 0);
        if (dut.table_q[1][0] != '0)
            $fatal(1, "[ADAPT_TB] class zero learned");
        check_bound(0, 0, 0, 0, 0);
        sample(4, 88, 1);
        if (dut.table_q[1][1].maximum != 8)
            $fatal(1, "[ADAPT_TB] masked host learned");
        check_bound(4, 0, 0, 0, 0);
        sample(3, 77, 1);
        check_bound(3, 0, 0, 0, 0);
        sample(2, 19, 1);
        if (dut.table_q[2][1].maximum != 19 || dut.table_q[1][1].maximum != 8)
            $fatal(1, "[ADAPT_TB] types share history");
        ctrl = config_word(1, 0, 1, 2, 1);
        check_bound(2, 38, 76);
        fenced[0][0] = 1;
        sample(0, 199, 1);
        if (dut.table_q[1][1].maximum != 8)
            $fatal(1, "[ADAPT_TB] fenced interval learned");
        fenced = '0;
        ctrl = config_word(0, 0, 1, 2, 1);
        sample(0, 21, 2);
        check_bound(0, 0, 0, 0, 0);
        ctrl = config_word(1, 0, 1, 2, 1);
        check_bound(0, 42, 84);
        ctrl = config_word(1, 0, 1, 2, 0, 90);
        check_bound(0, 90, 180);
        h_eff[0][0] = 50; c_eff[0][0] = 60;
        check_bound(0, 50, 60);
        c_eff[0][0] = 49;
        check_bound(0, 50, 49, 1, 0);
        c_eff[0][0] = 0;
        check_bound(0, 50, 0, 1, 0);
        h_eff[0][0] = 100; c_eff[0][0] = 200;
        ctrl = config_word(1, 0, 7, 7, 1, 0);
        sample(0, 65535, 3);
        check_bound(0, 100, 200);

        reset();
        ctrl = config_word(1, 1, 1, 2, 1);
        sample(0, 6, 1);
        check_bound(0, 12, 24);
        @(negedge clk); dispatch[0][0] = 1;
        step();
        @(negedge clk); dispatch = '0;
        @(negedge clk); busy[1][0] = 1;
        step();
        check_bound(0, 0, 0, 0, 0);
        @(negedge clk); busy[1][0] = 0;
        step();
        check_bound(0, 0, 0, 0, 0); // peak is sticky within an execution
        @(negedge clk); progress[0][0] = 1; interval[0][0] = 5;
        step();
        if (dut.load_max_q[0][0] != 2 || dut.table_q[1][1].samples != 1)
            $fatal(1, "[ADAPT_TB] heartbeat reset execution load or updated N");
        @(negedge clk); progress = '0;
        ctrl[1] = 0;
        check_bound(0, 12, 24);
        ctrl[1] = 1;
        @(negedge clk); done[0][0] = 1; interval[0][0] = 1;
        step();
        if (dut.table_q[1][1].load != 2)
            $fatal(1, "[ADAPT_TB] load peak not learned");
        check_bound(0, 12, 24);

        reset();
        ctrl = config_word(1, 0, 1, 2, 2);
        @(negedge clk);
        busy[0][0] = 1; busy[1][0] = 1;
        progress[0][0] = 1; progress[1][0] = 1;
        done[0][0] = 1; done[1][0] = 1;
        classes[0][0] = 4; classes[1][0] = 4;
        interval[0][0] = 7; interval[1][0] = 11;
        step();
        if (dut.table_q[1][4].samples != 2 || dut.table_q[1][4].maximum != 11 ||
            dut.table_q[1][4].load != 2)
            $fatal(1, "[ADAPT_TB] simultaneous same-entry samples lost");
        check_bound(0, 22, 44);
        check_bound(1, 22, 44);
        @(negedge clk); progress = '0;
        reset();
        ctrl = config_word(1, 0, 0, 0, 1, 0);
        sample(0, 0, 1);
        check_bound(0, 0, 0, 0, 0);
        ctrl = config_word(1, 0, 0, 0, 1, 5);
        check_bound(0, 0, 0, 0, 0); // a positive floor must not validate M=0
        sample(0, 1, 1);
        check_bound(0, 5, 10);
        h_eff[0][0] = 0;
        check_bound(0, 0, 0, 0, 0); // even a learned M cannot validate H_ad=0
        $display("Watchdog adaptive bound tests passed");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "[ADAPT_TB] timeout");
    end
endmodule
