// Exercise the real top's full-width validation and the real watchdog together.
localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int CW = $clog2((WATCHDOG_CONFIRM_TIMEOUT > 20 ?
                          WATCHDOG_CONFIRM_TIMEOUT : 20) + 1) + 1;
logic unit_rst = 0;
logic [1:0][0:0] ud = '0, done = '0, hb = '0, ticks = '1;
logic [1:0][0:0] ubusy, suspect, ufence;

`include "bingo_hw_manager/typedef.svh"
`BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(unit_wd_event_t, 2, 1)
`BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(unit_wd_bound_t, 2, 1, CW, 3)
`BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(unit_wd_status_t, 2, 1, CW)
unit_wd_status_t unit_status;
// As bingo_hw_manager_wd_bounds for two slots at risk, with the top's validated
// per-type H / C and R: R where valid and nonzero, else the type's C, else the
// parameters
logic [1:0][0:0]         unit_risk_valid;
logic [1:0][0:0][CW-1:0] unit_suspect, unit_confirm, unit_suspect_eff, unit_confirm_eff;
logic [1:0][0:0][1:0]    unit_confirm_src;
assign unit_risk_valid = gen_dut[0].i_dut.wd_bound.risk_valid;
assign unit_suspect    = gen_dut[0].i_dut.wd_bound.suspect;
assign unit_confirm    = gen_dut[0].i_dut.wd_bound.confirm;
for (genvar s = 0; s < 2; s++) begin : gen_unit_bound
    logic risk_now;
    assign risk_now = unit_risk_valid[s][0] && (CW'(risk_confirm[0]) != '0);
    assign unit_suspect_eff[s][0] = (unit_suspect[s][0] != '0) ? unit_suspect[s][0] : CW'(20);
    assign unit_confirm_eff[s][0] = risk_now ? CW'(risk_confirm[0]) :
                                    (unit_confirm[s][0] != '0) ? unit_confirm[s][0] :
                                    CW'(WATCHDOG_CONFIRM_TIMEOUT);
    assign unit_confirm_src[s][0] = risk_now ? bingo_hw_manager_pkg::WdConfirmRisk :
                                    (unit_confirm[s][0] != '0) ? bingo_hw_manager_pkg::WdConfirmType :
                                    bingo_hw_manager_pkg::WdConfirmParam;
end
assign ubusy = unit_status.busy;
assign suspect = unit_status.dead_suspect;
assign ufence = unit_status.fenced;
bingo_hw_manager_watchdog #(
    .NumCores(2), .NumClusters(1), .CounterWidth(CW),
    .HeartbeatTimeoutCycles(20), .ConfirmTimeoutCycles(WATCHDOG_CONFIRM_TIMEOUT),
    .CoreTypeId(8'h21),
    .wd_event_t(unit_wd_event_t), .wd_bound_t(unit_wd_bound_t), .wd_status_t(unit_wd_status_t)
) unit_wd (
    .clk_i(clk_i), .rst_ni(unit_rst),
    .event_i('{dispatch: ud, done: done, heartbeat: hb, waiting: '0, tick: ticks}),
    .bound_i('{risk_confirm: CW'(risk_confirm[0]),
               suspect: unit_suspect, confirm: unit_confirm,
               suspect_eff: unit_suspect_eff, confirm_eff: unit_confirm_eff,
               confirm_src: unit_confirm_src, default: '0}),
    .status_o(unit_status)
);

task automatic step();
    @(posedge clk_i); #1;
endtask

task automatic start_unit(input logic [31:0] h, c, r);
    @(negedge clk_i);
    unit_rst = 0; ud = '0; done = '0; hb = '0; ticks = '1;
    wd_type_h[0] = '0; wd_type_c[0] = '0;
    wd_type_h[0][0] = 1; wd_type_c[0][0] = 2; // unused type must not leak
    wd_type_h[0][1] = h; wd_type_c[0][1] = c;
    risk_confirm[0] = r;
    step();
    @(negedge clk_i);
    unit_rst = 1; ud = '1;
    step();
    @(negedge clk_i); ud = '0;
endtask

task automatic check_thresholds(input logic [31:0] h, c, r, input int period = 1);
    automatic int heff, ceff, threshold, hs;
    automatic bit rvalid;
    start_unit(h, c, r);
    heff = h != 0 && h <= 20 ? h : 20;
    ceff = WATCHDOG_CONFIRM_TIMEOUT != 0 && c != 0 &&
           c <= WATCHDOG_CONFIRM_TIMEOUT && c > heff ? c : WATCHDOG_CONFIRM_TIMEOUT;
    for (int cycle = 1; cycle <= 2*80+5; cycle++) begin
        ticks = (cycle % period == 1 % period) ? '1 : '0;
        step();
        for (int core = 0; core < 2; core++) begin
            hs = core == 0 ? heff : 20;
            threshold = core == 0 ? ceff : WATCHDOG_CONFIRM_TIMEOUT;
            rvalid = WATCHDOG_CONFIRM_TIMEOUT != 0 && r > hs && r < threshold;
            if (rvalid) threshold = r;
            if (ufence[core][0] !== (threshold != 0 && cycle >= (threshold-1)*period+2))
                $fatal(1, "[TYPE_THR] core=%0d h=%0d c=%0d r=%0d period=%0d cycle=%0d fence=%0b",
                       core, h, c, r, period, cycle, ufence[core][0]);
            if (suspect[core][0] !== (cycle >= (hs-1)*period+1))
                $fatal(1, "[TYPE_THR] core=%0d wrong suspect at cycle=%0d", core, cycle);
        end
        @(negedge clk_i);
    end
endtask

initial begin
    wait (rst_ni); repeat (20) @(posedge clk_i);
    check_thresholds(8, 30, 0);
    check_thresholds(0, 0, 0);
    check_thresholds(21, 30, 0);
    check_thresholds(8, 8, 0);
    check_thresholds(8, 7, 0);
    check_thresholds(8, 81, 0);
    check_thresholds(8 + (1 << CW), 30 + (1 << CW), 0);
    check_thresholds(8, 30, 15); // valid only for the shorter type
    check_thresholds(8, 30, 30); // R == C_t is invalid for this type
    check_thresholds(8, 30, 40); // invalid for A, valid for B
    check_thresholds(8, 30, 8);
    check_thresholds(8, 30, 7);
    check_thresholds(8, 30, 15 + (1 << CW));
    check_thresholds(8, 30, 0, 2);
    if (WATCHDOG_CONFIRM_TIMEOUT != 0) begin
        for (int completion = 0; completion < 2; completion++) begin
            start_unit(8, 30, 0);
            repeat (30) begin step(); @(negedge clk_i); end
            if (unit_wd.timer_q[0][0] != 30 || ufence[0][0])
                $fatal(1, "[TYPE_THR] missed C_t boundary fixture");
            if (completion) done[0][0] = 1'b1;
            else hb[0][0] = 1'b1;
            step();
            if (ufence[0][0] || suspect[0][0] || unit_wd.timer_q[0][0] != 0)
                $fatal(1, "[TYPE_THR] done/heartbeat lost priority at C_t");
        end
    end
    $display("Watchdog type threshold tests passed");
    $finish;
end
