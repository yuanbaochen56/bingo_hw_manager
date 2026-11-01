localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam device_axi_lite_data_t HEARTBEAT_EXIT = 32'h80000000;

function automatic bingo_hw_manager_task_desc_full_t ei_task(input int id, input int cl, input int core);
    return pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, cl, core, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
endfunction

task automatic ei_expect(input string step, input int l1, input int l2);
    if (gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1] != l1 ||
        gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[2] != l2)
        $fatal(1, "[EXIT_IDLE] %s: expected domain levels %0d/%0d", step, l1, l2);
endtask

initial begin : exit_idle_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    automatic device_axi_lite_data_t poll_id;

    wait (rst_ni);
    if (gen_dut[0].i_dut.exited_q != '0) $fatal(1, "[EXIT_IDLE] exit bits not reset");
    boost_policy[0] = 32'h1; // capacity policy, unlimited, load_min 0
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, ei_task(1, 0, 0), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, ei_task(2, 0, 1), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, ei_task(3, 1, 0), '1, resp);
    csr_read(0, 0, 0, CSR_READY, id); // silent victim
    csr_read(0, 0, 1, CSR_READY, id); // its future substitute
    csr_read(0, 1, 0, CSR_READY, id); // same-type survivor in domain 2
    fork
        csr_read(0, 0, 2, CSR_READY, poll_id);
        csr_read(0, 1, 1, CSR_READY, poll_id);
        csr_read(0, 1, 2, CSR_READY, poll_id);
    join_none
    fork
        busy_with_heartbeat(0, 0, 1, 1200, 50);
        busy_with_heartbeat(0, 1, 0, 1200, 50);
    join
    if (!fenced_export[0][0][0]) $fatal(1, "[EXIT_IDLE] victim not fenced");
    ei_expect("busy survivors", PM_BOOST_LEVEL, PM_BOOST_LEVEL);

    // Ordinary done + heartbeat (including a taken-over exit) never marks exit.
    csr_done(0, 0, 1, 2);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 1) $fatal(1, "[EXIT_IDLE] expected replayed task 1");
    csr_done(0, 0, 1, 1);
    csr_write(0, 0, 1, CSR_HEARTBEAT, 1);
    csr_done(0, 1, 0, 3);
    csr_write(0, 1, 0, CSR_HEARTBEAT, 1);
    // Data without a valid heartbeat cannot set an exit bit.
    @(negedge clk_i);
    csr_req[0][1][0].data = HEARTBEAT_EXIT;
    repeat (100) @(posedge clk_i);
    if (gen_dut[0].i_dut.exited_q != '0) $fatal(1, "[EXIT_IDLE] ordinary/invalid heartbeat set exit");
    ei_expect("done without exit heartbeat", PM_BOOST_LEVEL, PM_BOOST_LEVEL);

    csr_write(0, 1, 0, CSR_HEARTBEAT, HEARTBEAT_EXIT);
    repeat (100) @(posedge clk_i);
    if (!gen_dut[0].i_dut.exited_q[0][1] || gen_dut[0].i_dut.exited_q[1][0])
        $fatal(1, "[EXIT_IDLE] wrong exit slot");
    if (gen_dut[0].i_dut.ctrl_view.boost[0][1]) $fatal(1, "[EXIT_IDLE] exited survivor still a boost candidate");
    ei_expect("capacity exit", PM_BOOST_LEVEL, PM_IDLE_LEVEL);
    csr_write(0, 1, 0, CSR_HEARTBEAT, 1);
    repeat (100) @(posedge clk_i);
    if (!gen_dut[0].i_dut.exited_q[0][1]) $fatal(1, "[EXIT_IDLE] ordinary beat cleared exit");

    @(negedge clk_i);
    boost_policy[0] = '0; // P3b: the substitute must also idle after its real exit
    csr_write(0, 0, 1, CSR_HEARTBEAT, HEARTBEAT_EXIT);
    repeat (100) @(posedge clk_i);
    if (!gen_dut[0].i_dut.exited_q[1][0] || gen_dut[0].i_dut.ctrl_view.boost[1][0])
        $fatal(1, "[EXIT_IDLE] exited substitute still a boost candidate");
    ei_expect("substitute exit", PM_IDLE_LEVEL, PM_IDLE_LEVEL);

    // Re-poll an empty queue: clear exit, then become busy on the next task.
    @(negedge clk_i);
    boost_policy[0] = 32'h1;
    fork csr_read(0, 1, 0, CSR_READY, poll_id); join_none
    repeat (10) @(posedge clk_i);
    if (gen_dut[0].i_dut.exited_q[0][1]) $fatal(1, "[EXIT_IDLE] re-poll did not clear exit");
    task_queue_master[0].write(task_queue_base[0], '0, ei_task(4, 1, 0), '1, resp);
    repeat (100) @(posedge clk_i);
    if (poll_id[TaskIdWidth-1:0] != 4) $fatal(1, "[EXIT_IDLE] re-poll did not receive task 4");
    ei_expect("new offload after polling", PM_IDLE_LEVEL, PM_BOOST_LEVEL);
    csr_done(0, 1, 0, 4);
    csr_write(0, 1, 0, CSR_HEARTBEAT, HEARTBEAT_EXIT);

    // Re-poll a nonempty queue: no stalled-ready waiting signal is required.
    task_queue_master[0].write(task_queue_base[0], '0, ei_task(5, 0, 1), '1, resp);
    repeat (30) @(posedge clk_i);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 5) $fatal(1, "[EXIT_IDLE] expected next-offload task 5");
    repeat (100) @(posedge clk_i);
    if (gen_dut[0].i_dut.exited_q[1][0]) $fatal(1, "[EXIT_IDLE] nonempty ready read did not clear exit");
    ei_expect("new offload with task ready", PM_BOOST_LEVEL, PM_IDLE_LEVEL);
    csr_done(0, 0, 1, 5);
    csr_write(0, 0, 1, CSR_HEARTBEAT, HEARTBEAT_EXIT);
    repeat (100) @(posedge clk_i);
    ei_expect("all live cores exited or polling", PM_IDLE_LEVEL, PM_IDLE_LEVEL);
    if (gen_dut[0].i_dut.exited_q[0][0]) $fatal(1, "[EXIT_IDLE] victim falsely exited");
    if (fenced_export[0] != 6'b000001) $fatal(1, "[EXIT_IDLE] watchdog changed for healthy cores");
    $display("Exit idle test passed");
    $finish;
end
