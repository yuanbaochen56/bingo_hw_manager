// Actual watchdog, fed by the actual top's full-width CSR validation.
// The harness manager stays idle; the two unit slots are independently driven.
localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int CW = $clog2((WATCHDOG_CONFIRM_TIMEOUT > 20 ?
                          WATCHDOG_CONFIRM_TIMEOUT : 20) + 1) + 1;
logic unit_rst = 0;
logic [1:0][0:0] ud = '0, done = '0, hb = '0, ticks = '1;
logic [1:0][0:0] ubusy, suspect, ufence;
wire [CW-1:0] effective_r = gen_dut[0].i_dut.wd_risk_confirm;

`include "bingo_hw_manager/typedef.svh"
`BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(unit_wd_event_t, 2, 1)
`BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(unit_wd_bound_t, 2, 1, CW, 3)
`BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(unit_wd_status_t, 2, 1, CW)
unit_wd_status_t unit_status;
// As bingo_hw_manager_wd_bounds for slot 0 at risk (slot 1 not): the effective R
// if nonzero, else the parameters
logic [CW-1:0] unit_r_confirm;
logic [1:0]    unit_r_src;
assign unit_r_confirm = (effective_r != '0) ? effective_r : CW'(WATCHDOG_CONFIRM_TIMEOUT);
assign unit_r_src     = (effective_r != '0) ? bingo_hw_manager_pkg::WdConfirmRisk :
                                              bingo_hw_manager_pkg::WdConfirmParam;
assign ubusy = unit_status.busy;
assign suspect = unit_status.dead_suspect;
assign ufence = unit_status.fenced;
bingo_hw_manager_watchdog #(
    .NumCores(2), .NumClusters(1), .CounterWidth(CW),
    .HeartbeatTimeoutCycles(20), .ConfirmTimeoutCycles(WATCHDOG_CONFIRM_TIMEOUT),
    .wd_event_t(unit_wd_event_t), .wd_bound_t(unit_wd_bound_t), .wd_status_t(unit_wd_status_t)
) unit_wd (
    .clk_i(clk_i), .rst_ni(unit_rst),
    .event_i('{dispatch: ud, done: done, heartbeat: hb, waiting: '0, tick: ticks}),
    .bound_i('{suspect_eff: {2{CW'(20)}},
               confirm_eff: {CW'(WATCHDOG_CONFIRM_TIMEOUT), unit_r_confirm},
               confirm_src: {bingo_hw_manager_pkg::WdConfirmParam, unit_r_src},
               risk_confirm: effective_r, default: '0}),
    .status_o(unit_status)
);

task automatic step();
    @(posedge clk_i);
    #1;
endtask

task automatic start_unit(input logic [31:0] raw_r);
    @(negedge clk_i);
    unit_rst = 0; ud = '0; done = '0; hb = '0; ticks = '1;
    risk_confirm[0] = raw_r;
    step();
    @(negedge clk_i);
    unit_rst = 1; ud = '1;
    step();
    @(negedge clk_i);
    ud = '0;
endtask

task automatic check_thresholds(input logic [31:0] raw_r, input int period = 1);
    automatic int expect_r, threshold;
    start_unit(raw_r);
    expect_r = (WATCHDOG_CONFIRM_TIMEOUT != 0 && raw_r > 20 &&
                raw_r < WATCHDOG_CONFIRM_TIMEOUT) ? int'(raw_r) : 0;
    if (effective_r !== CW'(expect_r))
        $fatal(1, "[RISK_CONFIRM] CSR %0d narrowed/validated as %0d, expected %0d",
               raw_r, effective_r, expect_r);
    for (int cycle = 1; cycle <= 2*80+5; cycle++) begin
        ticks = (cycle % period == 1 % period) ? '1 : '0;
        step();
        for (int core = 0; core < 2; core++) begin
            threshold = (core == 0 && expect_r != 0) ? expect_r : WATCHDOG_CONFIRM_TIMEOUT;
            if (ufence[core][0] !== (threshold != 0 && cycle >= (threshold-1)*period+2))
                $fatal(1, "[RISK_CONFIRM] core %0d R=%0d period=%0d cycle=%0d fence=%0b",
                       core, raw_r, period, cycle, ufence[core][0]);
            if (suspect[core][0] !== (cycle >= 19*period+1))
                $fatal(1, "[RISK_CONFIRM] suspect changed with risk on core %0d", core);
        end
        @(negedge clk_i);
    end
endtask

initial begin : check_unit
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    check_thresholds(35);
    check_thresholds(80);
    check_thresholds(0);
    check_thresholds(20);
    check_thresholds(19);
    check_thresholds(81);
    check_thresholds(35 + (1 << CW));
    check_thresholds(35, 2);
    if (WATCHDOG_CONFIRM_TIMEOUT != 0) begin
        for (int completion = 0; completion < 2; completion++) begin
            start_unit(35);
            repeat (35) begin
                step();
                @(negedge clk_i);
            end
            if (unit_wd.timer_q[0][0] != 35 || ufence[0][0])
                $fatal(1, "[RISK_CONFIRM] missed the boundary fixture");
            if (completion) done[0][0] = 1'b1;
            else hb[0][0] = 1'b1;
            step();
            if (ufence[0][0] || suspect[0][0] || unit_wd.timer_q[0][0] != 0)
                $fatal(1, "[RISK_CONFIRM] done/heartbeat lost priority at R");
        end
    end
    $display("Watchdog risk confirm tests passed");
    $finish;
end
