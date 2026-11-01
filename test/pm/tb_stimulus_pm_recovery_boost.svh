// =============================================================================
// Recovery boost
// =============================================================================
// One cluster, three cores of one type, all in power domain 1 (idle 25,
// normal 6, boost 3), cores driven by the stimulus.
//   1. Core 0 takes task 1 and goes silent; core 1 takes task 2 and works with
//      heartbeats: the domain is at the normal level 6.
//   2. Core 0 is fenced; its substitute (core 1) is busy: the domain goes to
//      the boost level 3.
//   3. Core 1 finishes task 2, runs the replayed task 1, finishes it and polls
//      again, like core 2: the domain goes to the idle level 25.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

function automatic int unsigned rb_level();
    return gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1];
endfunction

initial begin : pm_recovery_boost_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    automatic bingo_hw_manager_task_desc_full_t t1 = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    automatic bingo_hw_manager_task_desc_full_t t2 = pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    wait (rst_ni);
    fork csr_read(0, 0, 2, CSR_READY, id); join_none   // core 2 polls throughout
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
    csr_read(0, 0, 0, CSR_READY, id);          // core 0: task 1, silent from now on
    csr_read(0, 0, 1, CSR_READY, id);          // core 1: task 2
    fork
        busy_with_heartbeat(0, 0, 1, 2000, 100);
        begin
            repeat (300) @(posedge clk_i);
            if (rb_level() != PM_NORMAL_LEVEL) $error("[BOOST] level %0d before the fence, expected %0d", rb_level(), PM_NORMAL_LEVEL);
            wait (fenced_export[0] === 3'b001);
            repeat (50) @(posedge clk_i);
            if (rb_level() != PM_BOOST_LEVEL) $error("[BOOST] level %0d after the fence, expected the boost level %0d", rb_level(), PM_BOOST_LEVEL);
        end
    join
    csr_done(0, 0, 1, 2);
    csr_read(0, 0, 1, CSR_READY, id);          // the replayed task 1
    if (id[TaskIdWidth-1:0] != 1) $error("[BOOST] core 1 got task %0d, expected the replayed task 1", id[TaskIdWidth-1:0]);
    repeat (100) @(posedge clk_i);
    if (rb_level() != PM_BOOST_LEVEL) $error("[BOOST] level %0d while core 1 runs task 1, expected %0d", rb_level(), PM_BOOST_LEVEL);
    csr_done(0, 0, 1, 1);
    fork csr_read(0, 0, 1, CSR_READY, id); join_none   // core 1 polls again
    repeat (100) @(posedge clk_i);
    if (rb_level() != PM_IDLE_LEVEL) $error("[BOOST] level %0d with every live core polling, expected %0d", rb_level(), PM_IDLE_LEVEL);
    $display("Recovery boost test passed");
    $finish;
end
