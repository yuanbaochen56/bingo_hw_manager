localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

function automatic bingo_hw_manager_task_desc_full_t rc_task(input int id);
    return pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, 0, 0,
        1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
endfunction

initial begin : replay_with_risk
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t got;
    wait (rst_ni);
    risk_late[0] = 100;
    risk_policy[0] = 2; // two late beats, no park/derate
    risk_confirm[0] = 350;
    repeat (20) @(posedge clk_i);
    for (int id = 1; id <= 2; id++) begin
        task_queue_master[0].write(task_queue_base[0], '0, rc_task(id), '1, resp);
        csr_read(0, 0, 0, CSR_READY, got);
        if (got[TaskIdWidth-1:0] != id)
            $fatal(1, "[RISK_CONFIRM] wrong initial task %0d", got);
        repeat (150) @(posedge clk_i);
        csr_write(0, 0, 0, CSR_HEARTBEAT, device_axi_lite_data_t'(1));
        csr_done(0, 0, 0, id);
        repeat (5) @(posedge clk_i);
    end
    if (!risk[0][0] || |park_fail[0] || gen_dut[0].i_dut.park.hold[0][0])
        $fatal(1, "[RISK_CONFIRM] did not register action-zero risk");
    task_queue_master[0].write(task_queue_base[0], '0, rc_task(3), '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    wait (gen_dut[0].i_dut.i_watchdog.timer_q[0][0] == 350);
    @(posedge clk_i); #1;
    if (!gen_dut[0].i_dut.core_fenced[0][0] ||
        gen_dut[0].i_dut.core_fenced[1][0])
        $fatal(1, "[RISK_CONFIRM] did not fence just the risk slot at R");
    csr_read(0, 0, 1, CSR_READY, got);
    if (got[TaskIdWidth-1:0] != 3)
        $fatal(1, "[RISK_CONFIRM] substitute did not receive task 3");
    csr_done(0, 0, 1, 3);
    wait_retired(0, 0, 0, 500);
    repeat (20) @(posedge clk_i);
    if (gen_dut[0].i_dut.replay_stuck_o)
        $fatal(1, "[RISK_CONFIRM] recovery stuck");
    $display("Risk confirm replay tests passed");
    $finish;
end
