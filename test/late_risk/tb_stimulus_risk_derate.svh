// =============================================================================
// Fault precursors: derate when the at-risk core cannot be parked
// =============================================================================
// One cluster, both cores in power domain 1 (idle 25, normal 6, boost 3),
// core 0 the only core of its type. Late threshold 100 cycles, one late beat
// makes a slot at risk, actions park and derate, derate level 10.
//   1. Core 1 works with heartbeats throughout, so the domain is not idle.
//   2. Task 1 on core 0: silent for 150 cycles, then done (late): core 0 is at
//      risk, the park fails at once (no live core of its type), and the domain
//      goes to the derate level 10 while core 1 is still busy.
//   3. Task 2 still runs on core 0 (not parked).
//   4. The host clears the risk: the domain goes back to the normal level 6.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int unsigned RD_DERATE_LEVEL         = 10;

function automatic int unsigned rd_level();
    return gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1];
endfunction

initial begin : risk_derate_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    automatic bingo_hw_manager_task_desc_full_t t1 = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    automatic bingo_hw_manager_task_desc_full_t t2 = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    automatic bingo_hw_manager_task_desc_full_t t9 = pack_normal_task(2'b00, 9, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

    wait (rst_ni);
    risk_late[0]   = 32'd100;
    risk_policy[0] = (32'(RD_DERATE_LEVEL) << 8) | 32'h31;   // threshold 1, park + derate
    repeat (20) @(posedge clk_i);

    task_queue_master[0].write(task_queue_base[0], '0, t9, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, t1, '1, resp);
    csr_read(0, 0, 1, CSR_READY, id);          // core 1: task 9, busy with beats
    csr_read(0, 0, 0, CSR_READY, id);          // core 0: task 1
    fork
        busy_with_heartbeat(0, 0, 1, 3000, 50);
        begin
            repeat (100) @(posedge clk_i);
            if (rd_level() != PM_NORMAL_LEVEL) $fatal(1, "[DERATE] level %0d before the late beat, expected %0d", rd_level(), PM_NORMAL_LEVEL);
            repeat (50) @(posedge clk_i);
            csr_done(0, 0, 0, 1);                // late: at risk
            repeat (50) @(posedge clk_i);
            if (risk[0][0] !== 1'b1) $fatal(1, "[DERATE] core 0 not at risk after a late beat");
            if (park_fail[0][0] !== 1'b1) $fatal(1, "[DERATE] park did not fail without a substitute");
            if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $fatal(1, "[DERATE] parked without a substitute");
            if (rd_level() != RD_DERATE_LEVEL) $fatal(1, "[DERATE] level %0d while core 0 is at risk, expected %0d", rd_level(), RD_DERATE_LEVEL);
            // Task 2 still runs on core 0
            task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
            csr_read(0, 0, 0, CSR_READY, id);
            if (id[TaskIdWidth-1:0] != 2) $fatal(1, "[DERATE] core 0 read task %0d, expected 2", id[TaskIdWidth-1:0]);
            csr_write(0, 0, 0, CSR_HEARTBEAT, device_axi_lite_data_t'(1));
            csr_done(0, 0, 0, 2);
            repeat (50) @(posedge clk_i);
            if (rd_level() != RD_DERATE_LEVEL) $fatal(1, "[DERATE] level %0d, the derate did not hold", rd_level());
            // Host clears the risk
            @(negedge clk_i);
            risk_clear[0] = 32'd1;
            repeat (2) @(posedge clk_i);
            @(negedge clk_i);
            risk_clear[0] = 32'd0;
            repeat (50) @(posedge clk_i);
            if (risk[0][0] !== 1'b0) $fatal(1, "[DERATE] risk not cleared");
            if (rd_level() != PM_NORMAL_LEVEL) $fatal(1, "[DERATE] level %0d after the clear, expected %0d", rd_level(), PM_NORMAL_LEVEL);
        end
    join
    csr_done(0, 0, 1, 9);
    repeat (20) @(posedge clk_i);
    $display("Risk derate test passed");
    $finish;
end
