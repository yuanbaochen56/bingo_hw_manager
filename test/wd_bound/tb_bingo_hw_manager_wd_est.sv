`include "bingo_hw_manager/typedef.svh"
`timescale 1ns/1ps
// Compile-time task-time estimates (bingo_hw_manager_wd_est) and their use by the
// watchdog adaptation (bingo_hw_manager_wd_adapt) during warm-up.
//
// Slots: core 0 type 1, core 1 type 2, core 2 type 0 and unmonitored (CoreMask 0).
// Two adaptations see the same events: dut takes the estimates of i_est, ref takes
// none (est_i = 0, the module before the estimates).
//   1. Random events and controls, table never written: dut == ref every cycle.
//   2. Entry encoding: 0, the smallest and the largest code, S = 0 .. 3.
//   3. Warm-up uses the estimate, a learned bound replaces it; MOVED_SH applies to
//      it, LOAD_GUARD does not (and a learned entry rejected by LOAD_GUARD does not
//      bring the estimate back); Late uses it too.
//   4. A write is read from the next cycle (write and dispatch in one cycle); data
//      without a write pulse changes nothing; type and class are not swapped; a type
//      out of range, class 0 and an unmonitored slot are ignored.
//   5. Random events and controls with entries written: dut == ref on every slot
//      whose class has no valid entry.
module tb_bingo_hw_manager_wd_est;
    localparam int unsigned Cores = 3;
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
    logic [31:0] ctrl, late_ctrl;
    event_t      ev;
    status_t     st;
    task_t       tk;
    est_t        est;
    learned_t    dut_l, ref_l;
    logic [2:0][0:0][31:0] h_eff, c_eff;
    int errors = 0;

    bingo_hw_manager_wd_est #(
        .NumCores(3), .NumClusters(1), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}), .wd_est_t(est_t)
    ) i_est (
        .clk_i(clk), .rst_ni(rst), .we_i(we), .data_i(data), .class_i(tk.wd_class), .est_o(est)
    );
    bingo_hw_manager_wd_adapt #(
        .NumCores(3), .NumClusters(1), .CounterWidth(24), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}),
        .wd_event_t(event_t), .wd_status_t(status_t), .wd_task_t(task_t),
        .wd_learned_t(learned_t), .wd_est_t(est_t)
    ) dut (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i(late_ctrl), .event_i(ev),
        .status_i(st), .task_i(tk), .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i(est),
        .learned_o(dut_l)
    );
    bingo_hw_manager_wd_adapt #(
        .NumCores(3), .NumClusters(1), .CounterWidth(24), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}),
        .wd_event_t(event_t), .wd_status_t(status_t), .wd_task_t(task_t),
        .wd_learned_t(learned_t), .wd_est_t(est_t)
    ) ref_adapt (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i(late_ctrl), .event_i(ev),
        .status_i(st), .task_i(tk), .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i('0),
        .learned_o(ref_l)
    );

    // A narrow timer (12 bits): an estimate beyond it saturates instead of wrapping
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(narrow_status_t, 3, 1, 12)
    narrow_status_t nst;
    learned_t       narrow_l;
    assign nst = '{busy: st.busy, available: '0, dead_suspect: '0, fenced: st.fenced, late: '0,
                   progress: st.progress, interval: '0};
    bingo_hw_manager_wd_adapt #(
        .NumCores(3), .NumClusters(1), .CounterWidth(12), .CoreMask(3'b011),
        .CoreTypeId({4'd0, 4'd2, 4'd1}),
        .wd_event_t(event_t), .wd_status_t(narrow_status_t), .wd_task_t(task_t),
        .wd_learned_t(learned_t), .wd_est_t(est_t)
    ) narrow (
        .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i(late_ctrl), .event_i(ev),
        .status_i(nst), .task_i(tk), .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i(est),
        .learned_o(narrow_l)
    );

    // e4m4 entry of the compiler (bingo_cost.encode / entry), checked against its decode
    function automatic logic [9:0] entry(int unsigned code, int unsigned s);
        return 10'((s << 8) | code);
    endfunction
    function automatic int unsigned decode(int unsigned code);
        return code == 0 ? 0 : (16 + (code & 15)) << (code >> 4);
    endfunction

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
    // One execution of class CLS on SLOT with longest interval IVL: dispatch, a
    // busy cycle, done
    task automatic execute(int slot, int unsigned cls, int unsigned ivl, logic moved = 0);
        tk.wd_class[slot] = 3'(cls); tk.moved[slot] = moved;
        ev.dispatch[slot] = 1;
        step();
        ev.dispatch[slot] = 0; st.busy[slot] = 1;
        step();
        ev.done[slot] = 1; st.interval[slot] = 24'(ivl);
        step();
        ev.done[slot] = 0; st.busy[slot] = 0; st.interval[slot] = '0;
    endtask
    task automatic reset_all();
        rst = 0; idle_inputs(); tk = '0; ctrl = '0; late_ctrl = '0;
        step(); step();
        rst = 1;
        step();
    endtask

    // 1 / 5: every cycle, dut and ref agree on every slot whose (type, class) has no
    // valid estimate (with ONLY_INVALID clear: on every slot)
    bit compare_on = 0, only_invalid = 0;
    int compared = 0;
    always @(negedge clk) begin
        if (rst && compare_on) begin
            for (int s = 0; s < Cores; s++) begin
                if (!only_invalid || !est.valid[s]) begin
                    compared++;
                    if ({dut_l.h[s], dut_l.c[s], dut_l.late[s], dut_l.h_valid[s], dut_l.c_valid[s],
                         dut_l.late_valid[s]} !==
                        {ref_l.h[s], ref_l.c[s], ref_l.late[s], ref_l.h_valid[s], ref_l.c_valid[s],
                         ref_l.late_valid[s]}) begin
                        errors++;
                        $error("slot %0d differs from the module without estimates at %0t", s, $time);
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
            step();
        end
        idle_inputs();
    endtask

    initial begin
        h_eff = {32'd100000, 32'd100000, 32'd100000};
        c_eff = {32'd200000, 32'd200000, 32'd200000};
        reset_all();

        // 1. Table never written: the same thresholds as without estimates
        compare_on = 1; only_invalid = 0;
        random_cycles(4000);
        compare_on = 0;
        check("no entry is valid after random events", est.valid == '0);

        // 2. Encoding: E_tot = (16 + m) << e, E_int = E_tot >> S
        reset_all();
        tk.wd_class[0] = 3'd1;
        for (int unsigned code = 0; code < 256; code += (code < 34 ? 1 : 37)) begin
            for (int unsigned s = 0; s < 4; s++) begin
                write_est(1, 1, entry(code, s));
                check($sformatf("valid of code %0d", code), est.valid[0] == (code != 0));
                check($sformatf("E_tot of code %0d: %0d", code, est.e_tot[0]), est.e_tot[0] == decode(code));
                check($sformatf("E_int of code %0d S %0d: %0d", code, s, est.e_int[0]),
                      est.e_int[0] == (decode(code) >> s));
            end
        end
        write_est(1, 1, entry(8'hFF, 0));
        check("largest code", est.e_tot[0] == 1015808);
        write_est(1, 1, entry(8'h01, 0));
        check("smallest code", est.e_tot[0] == 17);

        // 3. Warm-up and learning. K2-like: EN, SH_H 1, SH_C 2, WARMUP 1, FLOOR 10
        reset_all();
        ctrl = {20'd10, 4'd1, 3'd2, 3'd1, 1'b0, 1'b1};
        tk.wd_class[0] = 3'd1;
        check("no estimate, no learned bound", !dut_l.h_valid[0] && !dut_l.c_valid[0]);
        write_est(1, 1, entry(8'h44, 1));                 // E_tot (16 + 4) << 4 = 320, S 1: E_int 160
        check("estimate used before learning: H", dut_l.h_valid[0] && dut_l.h[0] == 320);
        check("estimate used before learning: C", dut_l.c_valid[0] && dut_l.c[0] == 640);
        // MOVED_SH applies to the estimate
        late_ctrl = 32'(1) << 7;                          // MOVED_SH 1
        tk.moved[0] = 1;
        #1 check("MOVED_SH on the estimate", dut_l.h[0] == 640 && dut_l.c[0] == 1280);
        tk.moved[0] = 0; late_ctrl = '0;
        // Late from the estimate: EN, SH_L 0, FRAC 2 -> 1.5 x 160 = 240, LFLOOR 0
        late_ctrl = 32'(1) | (32'(2) << 9);
        #1 check("Late from the estimate", dut_l.late_valid[0] && dut_l.late[0] == 240);
        late_ctrl = '0;
        // LOAD_GUARD does not apply to an estimate: with load on another slot
        ctrl[1] = 1;
        st.busy[1] = 1;
        #1 check("LOAD_GUARD does not apply to the estimate", dut_l.h_valid[0] && dut_l.h[0] == 320);
        st.busy[1] = 0;
        ctrl[1] = 0;
        // Learn class 1 on slot 0: M = 30 -> H = max(60, 10), C = 120 (estimate no longer used)
        execute(0, 1, 30);
        tk.wd_class[0] = 3'd1;
        #1 check($sformatf("learned bound replaces the estimate: H %0d C %0d", dut_l.h[0], dut_l.c[0]),
                 dut_l.h_valid[0] && dut_l.h[0] == 60 && dut_l.c[0] == 120);
        // A learned entry rejected by LOAD_GUARD: the static bounds, not the estimate
        ctrl[1] = 1;
        st.busy[1] = 1;
        tk.wd_class[0] = 3'd1;
        ev.dispatch[0] = 1;                               // peak load 2 > learned load 1
        step();
        ev.dispatch[0] = 0; st.busy[0] = 1;
        #1 check("LOAD_GUARD rejection keeps the static bounds", !dut_l.h_valid[0] && !dut_l.c_valid[0]);
        ev.done[0] = 1;
        step();
        idle_inputs();
        ctrl[1] = 0;
        // WARMUP 3: an entry learned once is still warm-up, the estimate stays
        reset_all();
        ctrl = {20'd10, 4'd3, 3'd2, 3'd1, 1'b0, 1'b1};
        write_est(1, 2, entry(8'h30, 0));                 // 16 << 3 = 128
        execute(0, 2, 50);
        tk.wd_class[0] = 3'd2;
        #1 check("estimate during WARMUP", dut_l.h[0] == 256);
        execute(0, 2, 50);
        execute(0, 2, 50);
        tk.wd_class[0] = 3'd2;
        #1 check("learned after WARMUP", dut_l.h[0] == 100);

        // An estimate beyond a 12-bit timer: 8192 saturates to 4095 (H 8190, C 16380)
        reset_all();
        ctrl = {20'd10, 4'd1, 3'd2, 3'd1, 1'b0, 1'b1};
        tk.wd_class[0] = 3'd3;
        write_est(1, 3, entry(8'hA0, 0));                 // 16 << 10 = 16384, E_int 16384
        #1 check($sformatf("saturated estimate: H %0d C %0d", narrow_l.h[0], narrow_l.c[0]),
                 narrow_l.h_valid[0] && narrow_l.h[0] == 8190 && narrow_l.c[0] == 16380);

        // 4. Write timing and indices
        reset_all();
        ctrl = {20'd10, 4'd1, 3'd2, 3'd1, 1'b0, 1'b1};
        // write and dispatch in the same cycle: read from the next cycle
        tk.wd_class[1] = 3'd3;
        we = 1; data = (32'd2 << 16) | (32'd3 << 12) | entry(8'h20, 0);   // type 2 class 3: 64
        ev.dispatch[1] = 1;
        #1 check("not read in the write cycle", !est.valid[1] && !dut_l.h_valid[1]);
        step();
        we = 0; data = '0; ev.dispatch[1] = 0;
        check("read from the next cycle", est.valid[1] && est.e_tot[1] == 64 && dut_l.h[1] == 128);
        // data without a write pulse: no change
        data = (32'd2 << 16) | (32'd3 << 12) | entry(8'h21, 0);
        step(); step();
        data = '0;
        check("data without a write pulse is ignored", est.e_tot[1] == 64);
        // the pulse writes once: a later value of data without we does not stick
        we = 1; data = (32'd2 << 16) | (32'd4 << 12) | entry(8'h22, 0);
        step();
        we = 0; data = (32'd2 << 16) | (32'd4 << 12) | entry(8'h23, 0);
        step(); step();
        data = '0;
        tk.wd_class[1] = 3'd4;
        #1 check("one pulse, one write", est.e_tot[1] == decode(8'h22));
        // type and class are not swapped: type 1 class 2 written, type 2 class 1 empty
        write_est(1, 2, entry(8'h25, 0));
        tk.wd_class[0] = 3'd2; tk.wd_class[1] = 3'd1;
        #1 check("type 1 class 2 is at type 1 class 2", est.valid[0] && est.e_tot[0] == decode(8'h25));
        check("type 2 class 1 stays empty", !est.valid[1]);
        // the type of the slot, not of another slot
        tk.wd_class[0] = 3'd5; tk.wd_class[1] = 3'd5;
        write_est(2, 5, entry(8'h27, 0));
        #1 check("type 2 entry is not read by the type 1 slot", !est.valid[0] && est.valid[1]);
        // out-of-range type, class 0 and the unmonitored slot
        write_est(5, 6, entry(8'h30, 0));
        write_est(4, 6, entry(8'h30, 0));
        tk.wd_class[0] = 3'd6; tk.wd_class[1] = 3'd6; tk.wd_class[2] = 3'd6;
        #1 check("type 4 and 5 are out of range", !est.valid[0] && !est.valid[1] && !est.valid[2]);
        write_est(1, 0, entry(8'h30, 0));
        tk.wd_class[0] = 3'd0;
        #1 check("class 0 has no estimate", !est.valid[0] && !dut_l.h_valid[0]);
        write_est(0, 6, entry(8'h30, 0));
        #1 check("the unmonitored slot has no estimate", !est.valid[2] && !dut_l.h_valid[2]);

        // 5. Random events with entries: dut == ref wherever no estimate is valid
        reset_all();
        write_est(1, 1, entry(8'h52, 0));
        write_est(2, 6, entry(8'h33, 2));
        compare_on = 1; only_invalid = 1;
        random_cycles(4000);
        compare_on = 0;

        $display("tb_bingo_hw_manager_wd_est: %0d comparisons, %0d errors", compared, errors);
        if (errors == 0) $display("tb_bingo_hw_manager_wd_est passed");
        $finish;
    end
endmodule
