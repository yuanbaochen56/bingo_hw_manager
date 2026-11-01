// =============================================================================
// Fault precursors: late beats -> at risk -> parked
// =============================================================================
// Two cores of one type, one cluster, cores driven by the stimulus. Late
// threshold 100 cycles (heartbeat timeout 200, confirm 800); two late beats
// make a slot at risk; action: park.
//   1. Task 1 on core 0: heartbeat after 50 cycles, then done. Not late.
//   2. Task 2 on core 0: silent for 150 cycles, then a heartbeat (late beat 1,
//      count 1), then done at once (the beat cleared the timer: not late).
//   3. Task 3 on core 0: silent for 150 cycles, then done (late beat 2): core
//      0 is at risk and, with nothing left to drain, PARKED on core 1.
//   4. Tasks 4 and 5 of logical core 0 run on core 1. Core 0 polls and gets
//      nothing; it is never fenced, even after the confirm timeout.
//   5. The host clears the risk: core 0 moves back and task 6 runs on it.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

function automatic bingo_hw_manager_task_desc_full_t rp_task(input int unsigned id);
    return pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
endfunction

function automatic int unsigned rp_cnt();
    return gen_dut[0].i_dut.i_ctrl.risk_cnt_q[0][0];
endfunction

task automatic rp_expect_task(input int core, input int unsigned id);
    automatic device_axi_lite_data_t got;
    csr_read(0, 0, core, CSR_READY, got);
    if (got[TaskIdWidth-1:0] != id) $fatal(1, "[RISK] core %0d read task %0d, expected %0d", core, got[TaskIdWidth-1:0], id);
endtask

initial begin : risk_park_test
    automatic axi_pkg::resp_t resp;
    automatic bit core0_got;
    automatic device_axi_lite_data_t core0_id;

    wait (rst_ni);
    risk_late[0]   = 32'd100;
    risk_policy[0] = 32'h12;          // threshold 2, park
    repeat (20) @(posedge clk_i);

    // 1. On time
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(1), '1, resp);
    rp_expect_task(0, 1);
    repeat (50) @(posedge clk_i);
    csr_write(0, 0, 0, CSR_HEARTBEAT, device_axi_lite_data_t'(1));
    csr_done(0, 0, 0, 1);
    repeat (5) @(posedge clk_i);
    if (rp_cnt() != 0) $fatal(1, "[RISK] count %0d after an on-time beat, expected 0", rp_cnt());

    // 2. Late heartbeat
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(2), '1, resp);
    rp_expect_task(0, 2);
    repeat (150) @(posedge clk_i);
    csr_write(0, 0, 0, CSR_HEARTBEAT, device_axi_lite_data_t'(1));
    csr_done(0, 0, 0, 2);
    repeat (5) @(posedge clk_i);
    if (rp_cnt() != 1) $fatal(1, "[RISK] count %0d after one late heartbeat, expected 1", rp_cnt());
    if (risk[0][0] !== 1'b0) $fatal(1, "[RISK] at risk after one late beat");

    // 3. Late done
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(3), '1, resp);
    rp_expect_task(0, 3);
    repeat (150) @(posedge clk_i);
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) $fatal(1, "[RISK] dead_suspect below the heartbeat timeout");
    csr_done(0, 0, 0, 3);
    fork : wait_parked
        wait (gen_dut[0].i_dut.park.parked[0][0] === 1'b1);
        begin
            repeat (200) @(posedge clk_i);
            $fatal(1, "[RISK] core 0 not PARKED (risk %0b hold %0b fail %0b count %0d)", risk[0][0],
                   gen_dut[0].i_dut.park.hold[0][0], gen_dut[0].i_dut.park.fail[0][0], rp_cnt());
        end
    join_any
    disable wait_parked;
    if (risk[0][0] !== 1'b1) $fatal(1, "[RISK] parked without being at risk");
    if (park_fail[0][0] !== 1'b0) $fatal(1, "[RISK] park failed with a live substitute");
    if (gen_dut[0].i_dut.smt.core[0][0] !== 1) $fatal(1, "[RISK] SMT sent core 0 to core %0d", gen_dut[0].i_dut.smt.core[0][0]);

    // 4. Later tasks of logical core 0 run on core 1; core 0 is idle, not fenced
    core0_got = 1'b0;
    fork
        begin
            csr_read(0, 0, 0, CSR_READY, core0_id);
            core0_got = 1'b1;
        end
    join_none
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(4), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(5), '1, resp);
    rp_expect_task(1, 4);
    csr_done(0, 0, 1, 4);
    rp_expect_task(1, 5);
    csr_done(0, 0, 1, 5);
    repeat (1000) @(posedge clk_i);
    if (core0_got) $fatal(1, "[RISK] parked core 0 read task %0d", core0_id[TaskIdWidth-1:0]);
    if (gen_dut[0].i_dut.core_fenced[0][0] !== 1'b0) $fatal(1, "[RISK] parked core 0 was fenced");

    // 5. Host clears the risk: back to core 0
    @(negedge clk_i);
    risk_clear[0] = 32'd1;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    risk_clear[0] = 32'd0;
    if (risk[0][0] !== 1'b0 || rp_cnt() != 0) $fatal(1, "[RISK] clear left risk %0b count %0d", risk[0][0], rp_cnt());
    fork : wait_back
        wait (gen_dut[0].i_dut.park.parked[0][0] === 1'b0 && gen_dut[0].i_dut.park.unpark[0][0] === 1'b0);
        begin
            repeat (200) @(posedge clk_i);
            $fatal(1, "[RISK] core 0 did not move back after the clear");
        end
    join_any
    disable wait_back;
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(6), '1, resp);
    fork : wait_core0
        wait (core0_got);
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "[RISK] task 6 did not reach core 0 after the clear");
        end
    join_any
    disable wait_core0;
    if (core0_id[TaskIdWidth-1:0] != 6) $fatal(1, "[RISK] core 0 read task %0d, expected 6", core0_id[TaskIdWidth-1:0]);
    csr_done(0, 0, 0, 6);
    repeat (20) @(posedge clk_i);
    $display("Risk park test passed");
    $finish;
end
