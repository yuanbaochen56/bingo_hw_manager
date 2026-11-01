// =============================================================================
// Fault precursors: the count decays
// =============================================================================
// Two cores of one type. Late threshold 100 cycles, two late beats make a slot
// at risk, action park, counts halved every 1000 cycles.
//   1. Four late beats on core 0, 2500 cycles apart (two epochs or more): the
//      count never exceeds 1, core 0 never becomes at risk.
//   2. Up to three late beats back to back (well within two epochs, so at
//      most one halving in between): core 0 becomes at risk and is parked.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

task automatic rdk_late_task(input int unsigned id);
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t got;
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    if (got[TaskIdWidth-1:0] != id) $fatal(1, "[DECAY] core 0 read task %0d, expected %0d", got[TaskIdWidth-1:0], id);
    repeat (150) @(posedge clk_i);
    csr_done(0, 0, 0, id);                     // late
endtask

initial begin : risk_decay_test
    wait (rst_ni);
    risk_late[0]   = 32'd100;
    risk_policy[0] = 32'h12;          // threshold 2, park
    risk_epoch[0]  = 32'd1000;
    repeat (20) @(posedge clk_i);

    // 1. Sparse
    for (int unsigned i = 1; i <= 4; i++) begin
        rdk_late_task(i);
        repeat (5) @(posedge clk_i);
        if (gen_dut[0].i_dut.i_ctrl.risk_cnt_q[0][0] > 1)
            $fatal(1, "[DECAY] count %0d after sparse late beat %0d", gen_dut[0].i_dut.i_ctrl.risk_cnt_q[0][0], i);
        repeat (2500) @(posedge clk_i);
        if (risk[0][0] !== 1'b0) $fatal(1, "[DECAY] at risk after sparse late beats");
    end
    if (gen_dut[0].i_dut.i_ctrl.risk_cnt_q[0][0] != 0) $fatal(1, "[DECAY] count did not decay to 0");

    // 2. Burst: at risk after two or three late beats (a halving may fall
    // between the first two); once at risk, later tasks would go to core 1
    for (int unsigned i = 5; i <= 7 && risk[0][0] !== 1'b1; i++) begin
        rdk_late_task(i);
        repeat (5) @(posedge clk_i);
    end
    if (risk[0][0] !== 1'b1) $fatal(1, "[DECAY] not at risk after a burst of three late beats");
    fork : wait_parked
        wait (gen_dut[0].i_dut.park.parked[0][0] === 1'b1);
        begin
            repeat (200) @(posedge clk_i);
            $fatal(1, "[DECAY] at-risk core 0 not parked");
        end
    join_any
    disable wait_parked;
    $display("Risk decay test passed");
    $finish;
end
