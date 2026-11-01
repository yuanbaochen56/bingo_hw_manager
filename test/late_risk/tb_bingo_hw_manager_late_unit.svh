`include "bingo_hw_manager/typedef.svh"
logic clk = 0;
always #5 clk = ~clk;
logic rst = 0;
logic [31:0] ctrl, late_ctrl;
logic [2:0][0:0] progress, dispatch, done, fenced, busy;
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
    .task_i('{wd_class: classes, moved: '0, fast: '0}),
    .h_eff_i(h_eff), .c_eff_i(c_eff), .est_i('0), .learned_o(adapt_learned)
);

task automatic step();
    @(posedge clk); #1;
endtask

task automatic reset();
    @(negedge clk);
    rst = 0; progress = '0; dispatch = '0; done = '0; fenced = '0;
    busy = '0; classes = '0; interval = '0;
    ctrl = (100 << 12) | (1 << 8) | (2 << 5) | (1 << 2) | 1;
    late_ctrl = 0;
    h_eff = {3{32'd1000}}; c_eff = {3{32'd2000}};
    step();
    @(negedge clk); rst = 1;
    step();
endtask

task automatic start(input int cls = 1, load = 1);
    @(negedge clk); busy = '0; progress = '0; done = '0; dispatch = '0;
    busy[0][0] = 1; busy[1][0] = load == 2;
    classes[0][0] = 3'(cls); dispatch[0][0] = 1;
    step();
    @(negedge clk); dispatch = '0;
endtask

task automatic complete(input logic [31:0] value);
    @(negedge clk);
    interval[0][0] = value; progress[0][0] = 1; done[0][0] = 1;
    step();
    @(negedge clk); progress = '0; done = '0; busy = '0;
    #1;
endtask

task automatic sample(input logic [31:0] value, input int cls = 1, load = 1);
    start(cls, load);
    complete(value);
endtask

task automatic expect_late(input bit valid, input int threshold = 0);
    #1;
    if (lv[0][0] !== valid || (valid && late_ad[0][0] != threshold))
        $fatal(1, "[P9_UNIT] late valid=%0b threshold=%0d, expected %0b/%0d",
               lv[0][0], late_ad[0][0], valid, threshold);
endtask

task automatic expect_entry(input int maximum, samples, load);
    if (dut.table_q[1][1].maximum != maximum || dut.table_q[1][1].samples != samples ||
        dut.table_q[1][1].load != load)
        $fatal(1, "[P9_UNIT] M/N/L changed unexpectedly");
endtask

initial begin
    #100000;
    $fatal(1, "[P9_UNIT] timeout");
end
