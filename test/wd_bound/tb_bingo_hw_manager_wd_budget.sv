`include "bingo_hw_manager/typedef.svh"
`timescale 1ns/1ps
// Total-time budget of the watchdog (bingo_hw_manager_wd_budget) with the watchdog it
// fences through (bingo_hw_manager_watchdog, fence_req_i).
//
// Slots: 0 and 1 monitored, 2 not (CoreMask 3'b011); an 8-bit timer, parameter
// thresholds H 200 / C 250 ticks, out of reach of the budgets below. A second
// watchdog without the budget (ref) sees the same events.
//   1. EN = 0, random events and estimates: dut == ref every cycle, no late beat.
//   2. Heartbeats do not restart the elapsed time: fence at the budget; with EN = 0
//      neither a fence nor a late beat.
//   3. Idle cycles do not count, the done holds the count, ticks only count.
//   4. Saturation at 255 (budget beyond the counter: no fence).
//   5. MOVED_SH widens the budget of a moved task; BFLOOR; no estimate, no budget;
//      the unmonitored slot never.
//   6. ACTION 0: one late beat at the budget, none more at the done; ACTION 1: fence.
//   7. Late threshold at the done (FRAC_B).
//   8. A heartbeat in the cycle of the budget fence does not delay it; a done wins.
module tb_bingo_hw_manager_wd_budget;
    localparam int unsigned Cores = 3;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 0;

    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(event_t, 3, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(bound_t, 3, 1, 8, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(status_t, 3, 1, 8)
    `BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(task_t, 3, 1, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(est_t, 3, 1)

    logic [31:0] ctrl, late_ctrl;
    event_t      ev;
    task_t       tk;
    est_t        est;
    status_t     st, ref_st;
    // The thresholds bingo_hw_manager_wd_bounds gives without any CSR: the parameters
    bound_t      bound_params;
    assign bound_params = '{suspect_eff: {3{8'd200}}, confirm_eff: {3{8'd250}}, default: '0};
    logic [2:0][0:0] fence_req, late;
    int errors = 0;

    bingo_hw_manager_watchdog #(
        .NumCores(3), .NumClusters(1), .CounterWidth(8),
        .HeartbeatTimeoutCycles(200), .ConfirmTimeoutCycles(250), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}),
        .wd_event_t(event_t), .wd_bound_t(bound_t), .wd_status_t(status_t)
    ) dut_wd (
        .clk_i(clk), .rst_ni(rst), .event_i(ev), .bound_i(bound_params), .fence_req_i(fence_req), .status_o(st)
    );
    bingo_hw_manager_watchdog #(
        .NumCores(3), .NumClusters(1), .CounterWidth(8),
        .HeartbeatTimeoutCycles(200), .ConfirmTimeoutCycles(250), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}),
        .wd_event_t(event_t), .wd_bound_t(bound_t), .wd_status_t(status_t)
    ) ref_wd (
        .clk_i(clk), .rst_ni(rst), .event_i(ev), .bound_i(bound_params), .fence_req_i('0), .status_o(ref_st)
    );
    bingo_hw_manager_wd_budget #(
        .NumCores(3), .NumClusters(1), .CounterWidth(8), .CoreMask(3'b011),
        .wd_event_t(event_t), .wd_status_t(status_t), .wd_task_t(task_t), .wd_est_t(est_t)
    ) dut (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i(late_ctrl), .event_i(ev),
        .status_i(st), .task_i(tk), .est_i(est), .fence_o(fence_req), .late_o(late)
    );

    // BINGO_WD_BUDGET
    function automatic logic [31:0] budget(bit en, bit action, int unsigned sh, int unsigned frac,
                                           int unsigned floor);
        return (32'(floor) << 12) | (32'(frac) << 5) | (32'(sh) << 2) | (32'(action) << 1) | 32'(en);
    endfunction

    task automatic step();
        @(posedge clk); #1;
    endtask
    task automatic check(string what, logic cond);
        if (!cond) begin
            errors++;
            $error("%s at %0t", what, $time);
        end
    endtask
    function automatic int unsigned elapsed(int s);
        return s == 0 ? dut.gen_core[0].gen_cluster[0].gen_budget.elapsed_q :
                        dut.gen_core[1].gen_cluster[0].gen_budget.elapsed_q;
    endfunction
    task automatic reset_all();
        rst = 0; ev = '0; tk = '0; est = '0; ctrl = '0; late_ctrl = '0;
        step(); step();
        rst = 1;
        step();
    endtask
    task automatic set_est(int s, int unsigned e_tot);
        est.valid[s] = e_tot != 0; est.e_tot[s] = 20'(e_tot); est.e_int[s] = 20'(e_tot);
    endtask
    task automatic dispatch(int s);
        ev.dispatch[s] = 1; ev.tick[s] = 1;
        step();
        ev.dispatch[s] = 0;
    endtask
    task automatic done(int s);
        ev.done[s] = 1;
        step();
        ev.done[s] = 0;
    endtask

    // Late beats counted per slot
    int lates [Cores];
    always @(negedge clk) if (rst) for (int s = 0; s < Cores; s++) if (late[s]) lates[s]++;

    // 1. EN = 0: dut == ref every cycle, no late beat
    bit compare_on = 0;
    int compared = 0;
    always @(negedge clk) begin
        if (rst && compare_on) begin
            compared++;
            if (st !== ref_st) begin
                errors++;
                $error("status differs from the watchdog without the budget at %0t", $time);
            end
            if (late !== '0 || fence_req !== '0) begin
                errors++;
                $error("budget output with EN = 0 at %0t", $time);
            end
        end
    end

    initial begin
        reset_all();
        // 1. random events, estimates and every control word but EN; estimates and budgets
        //    mostly short against the executions, so that EN = 1 would fence or flag often
        compare_on = 1;
        for (int i = 0; i < 6000; i++) begin
            for (int s = 0; s < Cores; s++) begin
                ev.dispatch[s] = ($urandom_range(0, 47) == 0);
                ev.done[s] = ($urandom_range(0, 47) == 0);
                ev.heartbeat[s] = ($urandom_range(0, 7) == 0);
                ev.tick[s] = $urandom_range(0, 1);
                tk.moved[s] = $urandom_range(0, 1);
                est.valid[s] = $urandom_range(0, 3) != 0;
                est.e_tot[s] = 20'($urandom_range(0, 9) == 0 ? $urandom_range(0, 300) : $urandom_range(0, 12));
            end
            if ($urandom_range(0, 99) == 0)
                ctrl = budget(0, $urandom_range(0, 1),
                              $urandom_range(0, 4) == 0 ? $urandom_range(0, 7) : $urandom_range(0, 1),
                              $urandom_range(0, 3), $urandom_range(0, 4) == 0 ? $urandom_range(0, 100) : 0);
            late_ctrl = 32'($urandom_range(0, 3)) << 7;
            step();
        end
        compare_on = 0;
        ev = '0; tk = '0; est = '0; late_ctrl = '0;

        // 2. heartbeats every 5 ticks do not restart the elapsed time: fence at 20
        reset_all();
        ctrl = budget(1, 1, 0, 0, 0);
        set_est(0, 20);
        ev.tick = '1;
        dispatch(0);
        for (int i = 1; i <= 25 && !st.fenced[0]; i++) begin
            ev.heartbeat[0] = (i % 5 == 0);
            step();
            ev.heartbeat[0] = 0;
            if (st.fenced[0]) check($sformatf("fence after %0d ticks, not 20", i), i == 21);
        end
        check("heartbeating task fenced by the budget", st.fenced[0] && !ref_st.fenced[0]);
        // the same with EN = 0, ACTION 1 and 0: neither a fence nor a late beat
        for (int action = 1; action >= 0; action--) begin
            reset_all();
            ctrl = budget(0, action, 0, 0, 0);
            set_est(0, 20);
            ev.tick = '1;
            dispatch(0);
            for (int i = 1; i <= 40; i++) begin
                ev.heartbeat[0] = (i % 5 == 0);
                step();
                ev.heartbeat[0] = 0;
                check($sformatf("EN = 0, ACTION %0d: budget output after %0d ticks", action, i),
                      fence_req[0] == 0 && late[0] == 0 && !st.fenced[0]);
            end
        end

        // 3. idle ticks do not count; the done holds; only ticks count
        reset_all();
        ctrl = budget(1, 1, 0, 0, 0);
        set_est(1, 100);
        ev.tick = '1;
        repeat (10) step();
        check("idle slot does not count", elapsed(1) == 0);
        dispatch(1);
        repeat (6) step();
        done(1);
        // the cycles after the dispatch up to the done (the done's own cycle does not count)
        check($sformatf("counted 6 busy ticks (got %0d)", elapsed(1)), elapsed(1) == 6);
        repeat (5) step();
        check("the done holds the count", elapsed(1) == 6);
        dispatch(1);
        ev.tick[1] = 0;
        repeat (5) step();
        check("no tick, no count", elapsed(1) == 0);
        for (int i = 0; i < 6; i++) begin
            ev.tick[1] = (i % 2 == 0);
            step();
        end
        check($sformatf("every tick counts once (got %0d)", elapsed(1)), elapsed(1) == 3);
        ev.tick[1] = 1;
        done(1);

        // 4. saturation: a budget beyond the 8-bit counter never fences
        reset_all();
        ctrl = budget(1, 1, 0, 0, 0);
        set_est(0, 300);
        ev.tick = '1;
        dispatch(0);
        for (int i = 0; i < 245; i++) begin
            ev.heartbeat[0] = (i % 50 == 0);
            step();
        end
        ev.heartbeat[0] = 0;
        repeat (60) begin
            ev.heartbeat[0] = 1;
            step();
        end
        ev.heartbeat[0] = 0;
        check($sformatf("saturates at 255 (got %0d)", elapsed(0)), elapsed(0) == 255);
        check("no fence beyond the counter", !st.fenced[0]);
        done(0);

        // 5. MOVED_SH, BFLOOR, no estimate, unmonitored slot
        reset_all();
        ctrl = budget(1, 1, 0, 0, 0);
        late_ctrl = 32'(1) << 7;                          // MOVED_SH 1
        set_est(0, 20);
        tk.moved[0] = 1;
        ev.tick = '1;
        dispatch(0);
        for (int i = 1; i <= 45 && !st.fenced[0]; i++) begin
            ev.heartbeat[0] = 1;
            step();
            if (st.fenced[0]) check($sformatf("moved task fenced after %0d ticks, not 40", i), i == 41);
        end
        ev.heartbeat[0] = 0;
        check("moved task fenced", st.fenced[0]);
        reset_all();
        ctrl = budget(1, 1, 0, 0, 50);                    // BFLOOR 50
        set_est(1, 5);
        ev.tick = '1;
        dispatch(1);
        for (int i = 1; i <= 55 && !st.fenced[1]; i++) begin
            ev.heartbeat[1] = 1;
            step();
            if (st.fenced[1]) check($sformatf("floor: fenced after %0d ticks, not 50", i), i == 51);
        end
        ev.heartbeat[1] = 0;
        check("fenced at the floor", st.fenced[1]);
        reset_all();
        ctrl = budget(1, 1, 0, 0, 0);
        est = '0;                                         // no estimate: no budget
        est.e_tot[0] = 20'd10;
        est.valid[2] = 1; est.e_tot[2] = 20'd10;          // the unmonitored slot
        ev.tick = '1;
        dispatch(0); dispatch(2);
        repeat (40) begin
            ev.heartbeat[0] = 1; ev.heartbeat[2] = 1;
            step();
        end
        ev.heartbeat = '0;
        check("no estimate: no fence", !st.fenced[0]);
        check("unmonitored slot: no budget", !st.fenced[2] && fence_req[2] == 0 && lates[2] == 0);

        // 6. ACTION 0: one late beat at the budget, none at the done, no fence
        reset_all();
        lates = '{default: 0};
        ctrl = budget(1, 0, 0, 0, 0);
        set_est(0, 20);
        ev.tick = '1;
        dispatch(0);
        repeat (40) begin
            ev.heartbeat[0] = 1;
            step();
        end
        ev.heartbeat[0] = 0;
        check($sformatf("one late beat at the budget (got %0d)", lates[0]), lates[0] == 1);
        check("ACTION 0 does not fence", !st.fenced[0]);
        done(0);
        check("no second late beat at the done", lates[0] == 1);
        // a new execution may report again
        dispatch(0);
        repeat (25) begin
            ev.heartbeat[0] = 1;
            step();
        end
        ev.heartbeat[0] = 0;
        check("the next execution reports again", lates[0] == 2);
        done(0);

        // 7. late threshold at the done: FRAC_B 2 (1.5 x 20 = 30), budget 80 (SH_B 2)
        reset_all();
        lates = '{default: 0};
        ctrl = budget(1, 1, 2, 2, 0);
        set_est(1, 20);
        ev.tick = '1;
        dispatch(1);
        repeat (24) step();
        done(1);
        check("done before 1.5 x E_tot: no late beat", lates[1] == 0);
        dispatch(1);
        repeat (34) step();
        done(1);
        check($sformatf("done after 1.5 x E_tot: one late beat (got %0d)", lates[1]), lates[1] == 1);
        check("no fence below the budget", !st.fenced[1]);

        // 8. a heartbeat in the cycle the budget is reached does not delay the fence
        reset_all();
        ctrl = budget(1, 1, 0, 0, 0);
        set_est(0, 10);
        ev.tick = '1;
        dispatch(0);
        for (int n = 0; n < 100 && !fence_req[0]; n++) step();
        check("budget reached", fence_req[0]);
        ev.heartbeat[0] = 1;
        step();
        ev.heartbeat[0] = 0;
        check("fenced in the heartbeat cycle", st.fenced[0]);
        // a done in that cycle wins
        reset_all();
        ctrl = budget(1, 1, 0, 0, 0);
        set_est(0, 10);
        ev.tick = '1;
        dispatch(0);
        for (int n = 0; n < 100 && !fence_req[0]; n++) step();
        check("budget reached", fence_req[0]);
        done(0);
        check("the done wins over the budget fence", !st.fenced[0] && !st.busy[0]);

        $display("tb_bingo_hw_manager_wd_budget: %0d comparisons, %0d errors", compared, errors);
        if (errors == 0) $display("tb_bingo_hw_manager_wd_budget passed");
        $finish;
    end
endmodule
