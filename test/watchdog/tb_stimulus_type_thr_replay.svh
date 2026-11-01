localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

initial begin
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t got;
    wait (rst_ni);
    wd_type_h[0][1] = 50;
    wd_type_c[0][1] = 100;
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(3), 0, 0, 0,
                         1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    if (got[TaskIdWidth-1:0] != 3) $fatal(1, "[TYPE_REPLAY] wrong initial task");
    wait (gen_dut[0].i_dut.i_watchdog.timer_q[0][0] == 100);
    @(posedge clk_i); #1;
    if (!gen_dut[0].i_dut.core_fenced[0][0] ||
         gen_dut[0].i_dut.core_fenced[1][0])
        $fatal(1, "[TYPE_REPLAY] did not fence just the shortened victim");
    csr_read(0, 0, 1, CSR_READY, got);
    if (got[TaskIdWidth-1:0] != 3) $fatal(1, "[TYPE_REPLAY] substitute missed replay");
    csr_done(0, 0, 1, 3);
    wait_retired(0, 0, 0, 500);
    repeat (20) @(posedge clk_i);
    if (gen_dut[0].i_dut.replay_stuck_o) $fatal(1, "[TYPE_REPLAY] recovery stuck");
    $display("Type threshold replay tests passed");
    $finish;
end
