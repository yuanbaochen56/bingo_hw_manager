localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
logic [1:0][0:0] test_risk;
int risk_value, expected_c, expected_reason, adapt_off;

task automatic wait_drained(input int core);
    fork : drain_or_timeout
        begin
            wait (gen_dut[0].i_dut.checkout_queue_empty[core][0] &&
                  !gen_dut[0].i_dut.wd_status.busy[core][0]);
        end
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "[ADAPT_REPLAY] checkout did not drain");
        end
    join_any
    disable drain_or_timeout;
endtask

initial begin
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t got;
    automatic bingo_hw_manager_task_desc_full_t descriptor;
    wait (rst_ni);
    risk_value = 0; adapt_off = 0;
    void'($value$plusargs("ADAPT_R=%d", risk_value));
    void'($value$plusargs("ADAPT_OFF=%d", adapt_off));
    wd_type_h[0][1] = 50; wd_type_c[0][1] = 150;
    wd_adapt[0] = (40 << 12) | (1 << 8) | (2 << 5) | (1 << 2) | !adapt_off;
    risk_confirm[0] = risk_value;
    test_risk = '1;
    force gen_dut[0].i_dut.ctrl_view.risk = test_risk;
    repeat (20) @(posedge clk_i);
    descriptor = pack_normal_task(2'b00, 0, 0, 0, 0,
                                  1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    descriptor.reserved_bits[2:0] = 3;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    #1;
    if (gen_dut[0].i_dut.wd_class_q[0][0] != 3 ||
        got != device_axi_lite_data_t'(0))
        $fatal(1, "[ADAPT_REPLAY] class lost or device ready word changed");
    repeat (8) @(posedge clk_i);
    csr_done(0, 0, 0, 0);
    wait_drained(0);
    if (gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples != 1 ||
        gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].maximum > 20)
        $fatal(1, "[ADAPT_REPLAY] training fixture not short enough");
    descriptor.task_id = 3;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    #1;
    if (got != 3 || gen_dut[0].i_dut.wd_class_q[0][0] != 3)
        $fatal(1, "[ADAPT_REPLAY] victim class or ready word");
    expected_c = adapt_off ? 150 : 80;
    expected_reason = adapt_off ? 2 : 3;
    if (risk_value > 50 && risk_value < 150 && risk_value <= expected_c) begin
        expected_c = risk_value;
        expected_reason = 1;
    end
    wait (gen_dut[0].i_dut.i_watchdog.timer_q[0][0] == expected_c);
    @(posedge clk_i); #1;
    if (!gen_dut[0].i_dut.core_fenced[0][0] ||
        gen_dut[0].i_dut.gen_evlog.i_events.reason_q[0][0] != expected_reason)
        $fatal(1, "[ADAPT_REPLAY] wrong final threshold or EVLOG reason");
    @(negedge clk_i); #1;
    if (!gen_dut[0].i_dut.gen_evlog.events[4] ||
        gen_dut[0].i_dut.gen_evlog.args[4] != expected_reason)
        $fatal(1, "[ADAPT_REPLAY] fence event did not carry the selected reason");
    csr_read(0, 0, 1, CSR_READY, got);
    #1;
    if (got != 3 || gen_dut[0].i_dut.wd_class_q[1][0] != 3)
        $fatal(1, "[ADAPT_REPLAY] replay lost class or changed device ready word");
    if (gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples != 1 ||
        gen_dut[0].i_dut.i_wd_adapt.imax_q[1][0] != 0)
        $fatal(1, "[ADAPT_REPLAY] fenced execution learned or replay inherited imax");
    csr_write(0, 0, 1, CSR_HEARTBEAT, device_axi_lite_data_t'(1));
    if (gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples != 1)
        $fatal(1, "[ADAPT_REPLAY] replay heartbeat learned before completion");
    csr_done(0, 0, 1, 3);
    wait_drained(1);
    if (gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples != 2)
        $fatal(1, "[ADAPT_REPLAY] substitute completion did not count exactly once");
    descriptor.task_id = 4;
    descriptor.reserved_bits[2:0] = 7;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 1, CSR_READY, got);
    #1;
    if (got != 4 || gen_dut[0].i_dut.wd_class_q[1][0] != 7)
        $fatal(1, "[ADAPT_REPLAY] remap lost class");
    csr_done(0, 0, 1, 4);
    wait_drained(1);
    repeat (20) @(posedge clk_i);
    if (gen_dut[0].i_dut.replay_stuck_o)
        $fatal(1, "[ADAPT_REPLAY] recovery stuck");
    release gen_dut[0].i_dut.ctrl_view.risk;
    $display("Adaptive replay tests passed R=%0d off=%0d threshold=%0d reason=%0d",
             risk_value, adapt_off, expected_c, expected_reason);
    $finish;
end
