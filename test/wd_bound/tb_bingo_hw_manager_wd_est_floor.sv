`include "bingo_hw_manager/typedef.svh"
`timescale 1ns/1ps
// EST_FLOOR of the watchdog adaptation (bingo_hw_manager_wd_adapt, est_floor_i,
// BINGO_WD_BUDGET [7]): the compile-time estimate (bingo_hw_manager_wd_est) is a lower
// bound of the learned bound, not only its warm-up value.
//
// Slots: core 0 type 1, core 1 type 2, core 2 type 0 and unmonitored (CoreMask 0).
// dut takes est_floor_i from the test; off leaves the port open (its default 0).
//   1. EST_FLOOR clear, random events, controls and estimate writes: dut == off every
//      cycle on every slot.
//   2. EST_FLOOR set, directed: the warm-up value as before; a smaller learned M is
//      raised to E_int, a larger one stays; a learned entry rejected by LOAD_GUARD
//      takes the estimate (not the static bounds); a class without estimate keeps its
//      learned bound; MOVED_SH and Late use the floored base.
//   3. EST_FLOOR set, random events, controls and estimate writes: dut == the
//      reference model below every cycle on every slot (and dut == off wherever no
//      estimate is valid).
module tb_bingo_hw_manager_wd_est_floor;
    localparam int unsigned Cores = 3;
    localparam int unsigned Width = 24;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 0;

    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(event_t, 3, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(status_t, 3, 1, 24)
    `BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(task_t, 3, 1, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_LEARNED_T(learned_t, 3, 1)
    `BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(est_t, 3, 1)

    logic        we;
    logic [31:0] data;
    bingo_hw_manager_pkg::wd_adapt_csr_t ctrl;
    bingo_hw_manager_pkg::wd_late_csr_t  late_ctrl;
    logic        floor;
    event_t      ev;
    status_t     st;
    task_t       tk;
    est_t        est;
    learned_t    dut_l, off_l;
    logic [2:0][0:0][31:0] h_eff, c_eff;
    int errors = 0;
    int unsigned slot_type [Cores] = '{1, 2, 0};

    bingo_hw_manager_wd_est #(
        .NumCores(3), .NumClusters(1), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}), .wd_est_t(est_t)
    ) i_est (
        .clk_i(clk), .rst_ni(rst), .we_i(we), .data_i(data), .class_i(tk.wd_class), .est_o(est)
    );
    bingo_hw_manager_wd_adapt #(
        .NumCores(3), .NumClusters(1), .CounterWidth(Width), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}),
        .wd_event_t(event_t), .wd_status_t(status_t), .wd_task_t(task_t),
        .wd_learned_t(learned_t), .wd_est_t(est_t)
    ) dut (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i(late_ctrl), .event_i(ev),
        .status_i(st), .task_i(tk), .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i(est),
        .est_floor_i(floor), .learned_o(dut_l)
    );
    bingo_hw_manager_wd_adapt #(
        .NumCores(3), .NumClusters(1), .CounterWidth(Width), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}),
        .wd_event_t(event_t), .wd_status_t(status_t), .wd_task_t(task_t),
        .wd_learned_t(learned_t), .wd_est_t(est_t)
    ) off (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i(late_ctrl), .event_i(ev),
        .status_i(st), .task_i(tk), .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i(est),
        .learned_o(off_l)
    );

    function automatic logic [9:0] entry(int unsigned code, int unsigned s);
        return 10'((s << 8) | code);
    endfunction

    // The derivation of the module header (4.), written out: thresholds of slot S
    // from dut's table and load state, the controls and the estimate.
    task automatic model(input int s, output logic [31:0] h_o, c_o, late_o,
                         output logic hv, cv, lv);
        logic [63:0] m, e, base, h, c, lb, suspect;
        logic [3:0] warm;
        logic mask, learned, valid_entry, use_est, apply;
        int unsigned t, k, peak;
        h_o = '0; c_o = '0; late_o = '0; hv = 0; cv = 0; lv = 0;
        t = slot_type[s];
        k = tk.wd_class[s];
        mask = (s != 2);
        m = dut.table_q[t][k].maximum;
        warm = ctrl.warmup == 0 ? 4'd1 : ctrl.warmup;
        peak = dut.load_now > dut.load_max_q[s] ? dut.load_now : dut.load_max_q[s];
        learned = mask && k != 0 && m >= 1 && dut.table_q[t][k].samples >= warm;
        valid_entry = learned && (!ctrl.load_guard || peak <= dut.table_q[t][k].load);
        e = est.e_int[s];
        if (e >> Width) e = (64'd1 << Width) - 1;
        use_est = est.valid[s] && (!learned || floor);
        apply = valid_entry || use_est;
        base = !use_est ? m : (valid_entry && m > e) ? m : e;
        base = base << (tk.moved[s] ? late_ctrl.moved_sh : 2'd0);
        if (ctrl.en && apply) begin
            h = base << ctrl.sh_h;
            if (h < ctrl.floor) h = ctrl.floor;
            if (h > h_eff[s]) h = h_eff[s];
            c = base << ctrl.sh_c;
            if (c < 2 * h) c = 2 * h;
            if (c > c_eff[s]) c = c_eff[s];
            h_o = h; c_o = c; hv = h >= 1; cv = h >= 1 && c > h;
        end
        if (late_ctrl.en && apply) begin
            lb = (base + (base >> 2) * late_ctrl.frac) << late_ctrl.sh_l;
            if (lb < late_ctrl.lfloor) lb = late_ctrl.lfloor;
            suspect = hv ? h_o : h_eff[s];
            if (lb < suspect) begin
                late_o = lb; lv = 1;
            end
        end
    endtask

    task automatic step();
        @(posedge clk); #1;
    endtask
    task automatic idle_inputs();
        we = 0; data = '0;
        ev = '0;
        st = '0;
    endtask
    task automatic write_est(int unsigned typ, int unsigned cls, logic [9:0] value);
        we = 1; data = (typ << 16) | (cls << 12) | value;
        step();
        we = 0; data = '0;
    endtask
    task automatic check(string what, logic cond);
        if (!cond) begin
            errors++;
            $error("%s", what);
        end
    endtask
    // One execution of class CLS on SLOT with longest interval IVL (OTHER: a slot that
    // is busy meanwhile, for the learned load)
    task automatic execute(int slot, int unsigned cls, int unsigned ivl, int other = -1);
        tk.wd_class[slot] = 3'(cls);
        ev.dispatch[slot] = 1;
        if (other >= 0) st.busy[other] = 1;
        step();
        ev.dispatch[slot] = 0; st.busy[slot] = 1;
        step();
        ev.done[slot] = 1; st.interval[slot] = 24'(ivl);
        step();
        ev.done[slot] = 0; st.busy[slot] = 0; st.interval[slot] = '0;
        if (other >= 0) st.busy[other] = 0;
    endtask
    task automatic reset_all();
        rst = 0; idle_inputs(); tk = '0; ctrl = '0; late_ctrl = '0; floor = 0;
        step(); step();
        rst = 1;
        step();
    endtask

    // 1 / 3: every cycle on every slot
    bit compare_off = 0, compare_model = 0;
    int compared = 0;
    always @(negedge clk) begin
        if (rst && (compare_off || compare_model)) begin
            for (int s = 0; s < Cores; s++) begin
                logic [31:0] h, c, late;
                logic hv, cv, lv;
                compared++;
                if ((compare_off || !est.valid[s]) &&
                    {dut_l.h[s], dut_l.c[s], dut_l.late[s], dut_l.h_valid[s], dut_l.c_valid[s], dut_l.late_valid[s]} !==
                    {off_l.h[s], off_l.c[s], off_l.late[s], off_l.h_valid[s], off_l.c_valid[s], off_l.late_valid[s]}) begin
                    errors++;
                    $error("slot %0d differs from the module without EST_FLOOR at %0t", s, $time);
                end
                if (compare_model) begin
                    model(s, h, c, late, hv, cv, lv);
                    if ({dut_l.h[s], dut_l.c[s], dut_l.late[s], dut_l.h_valid[s], dut_l.c_valid[s],
                         dut_l.late_valid[s]} !== {h, c, late, hv, cv, lv}) begin
                        errors++;
                        $error("slot %0d: H %0d C %0d Late %0d (%b%b%b), model %0d %0d %0d (%b%b%b) at %0t", s,
                               dut_l.h[s], dut_l.c[s], dut_l.late[s], dut_l.h_valid[s], dut_l.c_valid[s],
                               dut_l.late_valid[s], h, c, late, hv, cv, lv, $time);
                    end
                end
            end
        end
    end

    task automatic random_cycles(int n);
        for (int i = 0; i < n; i++) begin
            for (int s = 0; s < Cores; s++) begin
                ev.dispatch[s] = ($urandom_range(0, 7) == 0);
                ev.done[s] = ($urandom_range(0, 7) == 0);
                st.busy[s] = $urandom_range(0, 1);
                st.fenced[s] = ($urandom_range(0, 31) == 0);
                st.progress[s] = $urandom_range(0, 1);
                st.interval[s] = 24'($urandom_range(0, 5000));
                tk.wd_class[s] = 3'($urandom_range(0, 7));
                tk.moved[s] = $urandom_range(0, 1);
                tk.fast[s] = ($urandom_range(0, 7) == 0);
            end
            if ($urandom_range(0, 63) == 0) begin
                ctrl = {20'($urandom_range(0, 600)), 4'($urandom_range(0, 3)), 3'($urandom_range(0, 3)),
                        3'($urandom_range(0, 2)), 1'($urandom_range(0, 1)), 1'($urandom_range(0, 1))};
                late_ctrl = {20'($urandom_range(0, 600)), 1'b0, 2'($urandom_range(0, 3)),
                             2'($urandom_range(0, 3)), 1'($urandom_range(0, 1)), 2'b00,
                             3'($urandom_range(0, 2)), 1'($urandom_range(0, 1))};
            end
            // an estimate write now and then: types 0 .. 3, classes 0 .. 7, codes up to 4096 ticks
            if ($urandom_range(0, 15) == 0) begin
                we = 1;
                data = (32'($urandom_range(0, 3)) << 16) | (32'($urandom_range(0, 7)) << 12) |
                       entry($urandom_range(0, 7) == 0 ? 0 : $urandom_range(1, 8'h80), $urandom_range(0, 3));
            end else begin
                we = 0; data = '0;
            end
            step();
        end
        idle_inputs();
    endtask

    initial begin
        h_eff = {32'd100000, 32'd100000, 32'd100000};
        c_eff = {32'd200000, 32'd200000, 32'd200000};

        // 1. EST_FLOOR clear: as the module without it
        reset_all();
        compare_off = 1;
        random_cycles(6000);
        compare_off = 0;

        // 2. EST_FLOOR set, directed. K2-like: EN, SH_H 1, SH_C 2, WARMUP 1, FLOOR 10
        reset_all();
        floor = 1;
        ctrl = {20'd10, 4'd1, 3'd2, 3'd1, 1'b0, 1'b1};
        tk.wd_class[0] = 3'd1;
        write_est(1, 1, entry(8'h44, 1));                 // E_tot 320, S 1: E_int 160
        check("warm-up: H 320 C 640", dut_l.h_valid[0] && dut_l.h[0] == 320 && dut_l.c[0] == 640);
        // learned M 30 < E_int 160: the estimate stays (without EST_FLOOR H 60 C 120)
        execute(0, 1, 30);
        tk.wd_class[0] = 3'd1;
        #1 check($sformatf("smaller M raised to E_int: H %0d C %0d", dut_l.h[0], dut_l.c[0]),
                 dut_l.h[0] == 320 && dut_l.c[0] == 640);
        check("off: the learned bound", off_l.h[0] == 60 && off_l.c[0] == 120);
        // MOVED_SH on the floored base: 160 << 1
        late_ctrl = 32'(1) << 7;
        tk.moved[0] = 1;
        #1 check("MOVED_SH on the floor", dut_l.h[0] == 640 && dut_l.c[0] == 1280);
        tk.moved[0] = 0;
        // Late from the floored base: EN, FRAC 2 -> 1.5 x 160 = 240
        late_ctrl = 32'(1) | (32'(2) << 9);
        #1 check($sformatf("Late from the floor: %0d", dut_l.late[0]), dut_l.late_valid[0] && dut_l.late[0] == 240);
        late_ctrl = '0;
        // a learned entry rejected by LOAD_GUARD: the estimate (off: the static bounds)
        ctrl.load_guard = 1;
        st.busy[1] = 1;
        ev.dispatch[0] = 1;                               // peak load 2 > learned load 1
        step();
        ev.dispatch[0] = 0; st.busy[0] = 1;
        #1 check("LOAD_GUARD rejection: the estimate", dut_l.h_valid[0] && dut_l.h[0] == 320);
        check("off: LOAD_GUARD rejection keeps the static bounds", !off_l.h_valid[0]);
        ev.done[0] = 1; st.interval[0] = 24'd40;
        step();
        idle_inputs();
        ctrl.load_guard = 0;
        // learned M 500 > E_int 160: the learned bound
        execute(0, 1, 500);
        tk.wd_class[0] = 3'd1;
        #1 check($sformatf("larger M stays: H %0d C %0d", dut_l.h[0], dut_l.c[0]),
                 dut_l.h[0] == 1000 && dut_l.c[0] == 2000 && off_l.h[0] == 1000);
        // a larger learned M (500 at load 1) rejected by LOAD_GUARD: the estimate, not M
        write_est(1, 5, entry(8'h44, 1));
        execute(0, 5, 500);
        ctrl.load_guard = 1;
        st.busy[1] = 1;
        tk.wd_class[0] = 3'd5;
        ev.dispatch[0] = 1;                               // peak load 2 > learned load 1
        step();
        ev.dispatch[0] = 0; st.busy[0] = 1;
        #1 check($sformatf("rejected larger M: the estimate, H %0d", dut_l.h[0]),
                 dut_l.h_valid[0] && dut_l.h[0] == 320 && dut_l.c[0] == 640);
        ev.done[0] = 1; st.interval[0] = 24'd40;
        step();
        idle_inputs();
        ctrl.load_guard = 0;
        // a class without estimate keeps its learned bound
        execute(0, 2, 30);
        tk.wd_class[0] = 3'd2;
        #1 check("no estimate: the learned bound", !est.valid[0] && dut_l.h[0] == 60 && dut_l.c[0] == 120);
        // no estimate and not learned: nothing
        tk.wd_class[0] = 3'd3;
        #1 check("no estimate, not learned: no bound", !dut_l.h_valid[0] && !dut_l.c_valid[0]);
        // the unmonitored slot never gets one
        write_est(0, 3, entry(8'h44, 0));
        tk.wd_class[2] = 3'd3;
        #1 check("unmonitored slot", !dut_l.h_valid[2]);
        // EST_FLOOR cleared again: the learned bound of class 1 (M 500 > 160 anyway) and
        // of a class learned below its estimate
        write_est(1, 4, entry(8'h44, 1));
        execute(0, 4, 30);
        tk.wd_class[0] = 3'd4;
        #1 check("set: class 4 at the estimate", dut_l.h[0] == 320);
        floor = 0;
        #1 check("cleared: class 4 at the learned bound", dut_l.h[0] == 60);

        // 3. EST_FLOOR set, random: the model, and the module without it where no estimate
        reset_all();
        floor = 1;
        compare_model = 1;
        random_cycles(20000);
        compare_model = 0;

        $display("tb_bingo_hw_manager_wd_est_floor: %0d comparisons, %0d errors", compared, errors);
        if (errors == 0) $display("tb_bingo_hw_manager_wd_est_floor passed");
        $finish;
    end
endmodule
