`include "bingo_hw_manager/typedef.svh"
// Unit harness of bingo_hw_manager_wd_adapt with the moved / fast inputs:
// three slots of one cluster, slots 0 and 1 of type 1, slot 2 of type 4 (not
// in the table). Inputs change at the negative edge.
logic clk = 0;
always #5 clk = ~clk;
logic rst = 0;
logic [31:0] ctrl, late_ctrl;
logic [2:0][0:0] progress, dispatch, done, fenced, busy, moved, fast;
logic [2:0][0:0][31:0] interval, h_eff, c_eff, h_ad, c_ad, late_ad;
logic [2:0][0:0][2:0] classes;
logic [2:0][0:0] hv, cv, lv;

// Port structs of bingo_hw_manager_wd_adapt (bingo_hw_manager/typedef.svh)
`BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(adapt_event_t, 3, 1)
`BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(adapt_status_t, 3, 1, 32)
`BINGO_HW_MANAGER_TYPEDEF_WD_TASK_T(adapt_task_t, 3, 1, 3)
`BINGO_HW_MANAGER_TYPEDEF_WD_LEARNED_T(adapt_learned_t, 3, 1) `BINGO_HW_MANAGER_TYPEDEF_WD_EST_T(adapt_est_t, 3, 1)
adapt_learned_t adapt_learned;
assign h_ad = adapt_learned.h;
assign c_ad = adapt_learned.c;
assign hv = adapt_learned.h_valid;
assign cv = adapt_learned.c_valid;
assign late_ad = adapt_learned.late;
assign lv = adapt_learned.late_valid;
bingo_hw_manager_wd_adapt #(
    .NumCores(3), .NumClusters(1), .CounterWidth(32),
    .CoreTypeId({4'd4, 4'd1, 4'd1}),
    .wd_event_t(adapt_event_t), .wd_status_t(adapt_status_t),
    .wd_task_t(adapt_task_t), .wd_learned_t(adapt_learned_t), .wd_est_t(adapt_est_t)
) dut (
    .clk_i(clk), .rst_ni(rst), .ctrl_i(ctrl), .late_ctrl_i(late_ctrl),
    .event_i('{dispatch: dispatch, done: done, default: '0}),
    .status_i('{progress: progress, interval: interval, busy: busy,
               fenced: fenced, default: '0}),
    .task_i('{wd_class: classes, moved: moved, fast: fast}),
    .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i('0), .learned_o(adapt_learned)
);

task automatic step();
    @(posedge clk); #1;
endtask

// EN, SH_H 1, SH_C 2, WARMUP 1, FLOOR 1: the learned term sets the thresholds
task automatic reset();
    @(negedge clk);
    rst = 0; progress = '0; dispatch = '0; done = '0; fenced = '0;
    busy = '0; classes = '0; interval = '0; moved = '0; fast = '0;
    ctrl = (1 << 12) | (1 << 8) | (2 << 5) | (1 << 2) | 1;
    late_ctrl = 0;
    h_eff = {3{32'd1000}}; c_eff = {3{32'd2000}};
    step();
    @(negedge clk); rst = 1;
    step();
endtask

// Dispatch a task of class cls to the slots of mask; fast_at_dispatch also
// sets their fast input in that cycle only
task automatic start(input logic [2:0] mask, input int cls = 1, input bit fast_at_dispatch = 0);
    @(negedge clk);
    for (int s = 0; s < 3; s++) begin
        if (mask[s]) begin
            busy[s][0] = 1; classes[s][0] = 3'(cls); dispatch[s][0] = 1;
            if (fast_at_dispatch) fast[s][0] = 1;
        end
    end
    step();
    @(negedge clk);
    dispatch = '0;
    for (int s = 0; s < 3; s++) if (mask[s] && fast_at_dispatch) fast[s][0] = 0;
endtask

// One busy cycle of the slot at a level faster than normal
task automatic fast_cycle(input int s);
    @(negedge clk); fast[s][0] = 1;
    step();
    @(negedge clk); fast[s][0] = 0;
endtask

// Complete slots 0 and 1 of mask in one cycle with their largest intervals;
// fast_at_done sets their fast input in that cycle only
task automatic complete(input logic [2:0] mask, input logic [31:0] value0,
                        input logic [31:0] value1 = 0, input bit fast_at_done = 0);
    @(negedge clk);
    for (int s = 0; s < 2; s++) begin
        if (mask[s]) begin
            interval[s][0] = s == 0 ? value0 : value1;
            progress[s][0] = 1; done[s][0] = 1;
            if (fast_at_done) fast[s][0] = 1;
        end
    end
    step();
    @(negedge clk);
    for (int s = 0; s < 2; s++) begin
        if (mask[s]) begin
            progress[s][0] = 0; done[s][0] = 0; busy[s][0] = 0; fast[s][0] = 0;
        end
    end
    #1;
endtask

task automatic sample(input logic [31:0] value, input int cls = 1);
    start(3'b001, cls);
    complete(3'b001, value);
endtask

task automatic expect_entry(input int cls, maximum, samples, load);
    if (dut.table_q[1][cls].maximum != maximum || dut.table_q[1][cls].samples != samples ||
        dut.table_q[1][cls].load != load)
        $fatal(1, "[RULES_UNIT] entry 1.%0d M/N/L %0d/%0d/%0d, expected %0d/%0d/%0d", cls,
               dut.table_q[1][cls].maximum, dut.table_q[1][cls].samples, dut.table_q[1][cls].load,
               maximum, samples, load);
endtask

task automatic expect_bounds(input int s, input int h, input int c);
    #1;
    if (!hv[s][0] || !cv[s][0] || h_ad[s][0] != h || c_ad[s][0] != c)
        $fatal(1, "[RULES_UNIT] slot %0d H_ad/C_ad %0d/%0d valid %0b/%0b, expected %0d/%0d",
               s, h_ad[s][0], c_ad[s][0], hv[s][0], cv[s][0], h, c);
endtask

task automatic expect_late(input int s, input bit valid, input int threshold = 0);
    #1;
    if (lv[s][0] !== valid || (valid && late_ad[s][0] != threshold))
        $fatal(1, "[RULES_UNIT] slot %0d late valid=%0b threshold=%0d, expected %0b/%0d",
               s, lv[s][0], late_ad[s][0], valid, threshold);
endtask

initial begin
    #100000;
    $fatal(1, "[RULES_UNIT] timeout");
end
