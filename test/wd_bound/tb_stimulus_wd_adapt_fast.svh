// =============================================================================
// Executions at a level faster than normal (BINGO_WD_LATE[6])
// =============================================================================
// Idle PM on, normal level 6, all slots in power domain 1. The control plane
// marks a slot whose domain runs at a known level below the normal one
// (wd_fast_o of bingo_hw_manager_ctrl). Core 0 learns class 3, then runs
// class 3 again with a few cycles at level 3 (forced at the control plane's
// input): with BINGO_WD_LATE = 0x40 that execution is not learned; with 0
// (TB_WD_ADAPT_FAST_OFF or +FAST_OFF=1) it is. A third execution at the normal
// level is learned either way. Then the flag for each kind of level: idle 25
// and normal 6 are not fast, 3 is, an unknown level 0 is not.

localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
`ifndef TB_WD_ADAPT_FAST_OFF
  `define TB_WD_ADAPT_FAST_OFF 0
`endif
int fast_off, learned;
logic [31:0][7:0] forced_levels;

task automatic force_level(input int unsigned level);
    forced_levels = '0;
    forced_levels[1] = 8'(level);
    force gen_dut[0].i_dut.i_ctrl.pm_i.domain_level = forced_levels;
    #1;
endtask

task automatic expect_fast(input bit fast, input string what);
    if (gen_dut[0].i_dut.ctrl_view.wd_fast[0][0] !== fast || gen_dut[0].i_dut.ctrl_view.wd_fast[1][0] !== fast)
        $fatal(1, "[ADAPT_FAST] %s: fast %b, expected %b", what,
               gen_dut[0].i_dut.ctrl_view.wd_fast[1:0], fast);
endtask

task automatic expect_samples(input int n, input string what);
    if (gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples != n)
        $fatal(1, "[ADAPT_FAST] %s: class 3 has %0d samples, expected %0d", what,
               gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples, n);
endtask

task automatic run_task(input int task_id, input bit boosted);
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t got;
    automatic bingo_hw_manager_task_desc_full_t descriptor;
    descriptor = pack_normal_task(2'b00, task_id, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    descriptor.reserved_bits[2:0] = 3;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    if (got != task_id) $fatal(1, "[ADAPT_FAST] core 0 got task %0d, expected %0d", got, task_id);
    repeat (4) @(posedge clk_i);
    if (boosted) begin
        force_level(3);
        expect_fast(1'b1, "level 3 while busy");
        repeat (3) @(posedge clk_i);
        release gen_dut[0].i_dut.i_ctrl.pm_i.domain_level;
    end
    force_level(PM_NORMAL_LEVEL);
    expect_fast(1'b0, "normal level while busy");
    repeat (4) @(posedge clk_i);
    csr_done(0, 0, 0, task_id);
    repeat (5) @(posedge clk_i);
    release gen_dut[0].i_dut.i_ctrl.pm_i.domain_level;
    if (gen_dut[0].i_dut.wd_status.busy[0][0]) $fatal(1, "[ADAPT_FAST] core 0 still busy");
endtask

initial begin
    wait (rst_ni);
    fast_off = `TB_WD_ADAPT_FAST_OFF;
    void'($value$plusargs("FAST_OFF=%d", fast_off));
    force gen_dut[0].i_dut.bingo_hw_manager_wd_late_i = fast_off ? 32'h0 : 32'h40;
    // EN, SH_H 1, SH_C 2, WARMUP 1, FLOOR 1
    wd_adapt[0] = (1 << 12) | (1 << 8) | (2 << 5) | (1 << 2) | 1;
    repeat (20) @(posedge clk_i);
    run_task(0, 1'b0);
    expect_samples(1, "normal execution");
    learned = 1;
    run_task(1, 1'b1);
    learned += fast_off;
    expect_samples(learned, "execution with cycles at level 3");
    run_task(2, 1'b0);
    learned += 1;
    expect_samples(learned, "normal execution after it");
    // The flag for each kind of level (after the executions: forcing the
    // level of an idle domain disturbs the idle power manager)
    force_level(PM_IDLE_LEVEL);
    expect_fast(1'b0, "idle level");
    force_level(PM_NORMAL_LEVEL);
    expect_fast(1'b0, "normal level");
    force_level(3);
    expect_fast(1'b1, "level 3");
    force_level(0);
    expect_fast(1'b0, "unknown level 0");
    release gen_dut[0].i_dut.i_ctrl.pm_i.domain_level;
    release gen_dut[0].i_dut.bingo_hw_manager_wd_late_i;
    $display("Fast execution tests passed off=%0d samples=%0d", fast_off, learned);
    $finish;
end
