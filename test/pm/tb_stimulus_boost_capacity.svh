// =============================================================================
// Capacity boost with a budget
// =============================================================================
// Two clusters, cluster c in power domain 1 + c (idle 25, normal 6, boost 3),
// cores 0 and 1 of type 1, core 2 of type 2, level 1 only.
//   Core 0 of cluster 0 takes task 1 and goes silent; core 1 of cluster 0 and
//   core 0 of cluster 1 work with heartbeats; the others poll.
//   A. Capacity policy, one domain per lost core: nothing lost, no boost.
//   B. Core 0 of cluster 0 is fenced (task 1 replayed on core 1, behind task 2):
//      one lost core, two candidate domains, only domain 1 is boosted.
//   C. Two domains per lost core: both boosted.
//   D. Minimum load 16 (above any checkout occupancy here): none boosted.
//   E. Substitute policy (P3b): only the substitute's domain 1 is boosted.
//   F. Capacity policy, no limit, but cluster 1 now only has its type-2 core
//      busy: domain 2 stays at the normal level, domain 1 is boosted.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

function automatic int unsigned bc_level(input int unsigned d);
    return gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[d];
endfunction

task automatic bc_expect(input string step, input int unsigned l1, input int unsigned l2);
    if (bc_level(1) != l1 || bc_level(2) != l2)
        $fatal(1, "[BOOSTCAP] %s: domain levels %0d/%0d, expected %0d/%0d", step, bc_level(1), bc_level(2), l1, l2);
endtask

task automatic bc_set(input int unsigned policy, input int unsigned credit, input int unsigned load_min);
    @(negedge clk_i);
    boost_policy[0] = device_axi_lite_data_t'(policy | (credit << 8) | (load_min << 16));
    repeat (100) @(posedge clk_i);
endtask

function automatic bingo_hw_manager_task_desc_full_t bc_task(input int unsigned id, input int cl, input int core);
    return pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, cl, core, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
endfunction

initial begin : boost_capacity_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    automatic device_axi_lite_data_t id5;

    wait (rst_ni);
    boost_policy[0] = 32'h101;        // capacity, one domain per lost core
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, bc_task(1, 0, 0), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, bc_task(2, 0, 1), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, bc_task(3, 1, 0), '1, resp);
    csr_read(0, 0, 0, CSR_READY, id);          // core 0, cluster 0: task 1, silent
    csr_read(0, 0, 1, CSR_READY, id);          // core 1, cluster 0: task 2
    csr_read(0, 1, 0, CSR_READY, id);          // core 0, cluster 1: task 3
    fork
        csr_read(0, 0, 2, CSR_READY, id);
        csr_read(0, 1, 1, CSR_READY, id);
        csr_read(0, 1, 2, CSR_READY, id5);     // gets task 5 in step F
    join_none
    fork
        busy_with_heartbeat(0, 0, 1, 4000, 50);
        begin
            busy_with_heartbeat(0, 1, 0, 2500, 50);
            csr_done(0, 1, 0, 3);
            fork csr_read(0, 1, 0, CSR_READY, id); join_none
        end
        begin
            repeat (300) @(posedge clk_i);
            bc_expect("A (nothing lost)", PM_NORMAL_LEVEL, PM_NORMAL_LEVEL);
            wait (fenced_export[0][0][0] === 1'b1);
            repeat (100) @(posedge clk_i);
            bc_expect("B (budget 1)", PM_BOOST_LEVEL, PM_NORMAL_LEVEL);
            bc_set(1, 2, 0);
            bc_expect("C (budget 2)", PM_BOOST_LEVEL, PM_BOOST_LEVEL);
            bc_set(1, 2, 16);
            bc_expect("D (minimum load)", PM_NORMAL_LEVEL, PM_NORMAL_LEVEL);
            bc_set(0, 0, 0);
            bc_expect("E (substitute policy)", PM_BOOST_LEVEL, PM_NORMAL_LEVEL);
            bc_set(1, 0, 0);
            wait (gen_dut[0].i_dut.core_status_waiting_task[0][1] === 1'b1);   // core 0 of cluster 1 polls again
            task_queue_master[0].write(task_queue_base[0], '0, bc_task(5, 1, 2), '1, resp);
            repeat (100) @(posedge clk_i);
            if (id5[TaskIdWidth-1:0] != 5) $fatal(1, "[BOOSTCAP] core 2 of cluster 1 read task %0d, expected 5", id5[TaskIdWidth-1:0]);
            bc_expect("F (only a type-2 core busy in cluster 1)", PM_BOOST_LEVEL, PM_NORMAL_LEVEL);
            // Keep this unrelated type healthy until cleanup: this case must
            // not accidentally gain another lost slot while core 1 finishes.
            busy_with_heartbeat(0, 1, 2, 1400, 50);
        end
    join
    csr_done(0, 0, 1, 2);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 1) $fatal(1, "[BOOSTCAP] core 1 of cluster 0 read task %0d, expected the replayed task 1", id[TaskIdWidth-1:0]);
    csr_done(0, 0, 1, 1);
    csr_done(0, 1, 2, 5);
    repeat (20) @(posedge clk_i);
    $display("Capacity boost test passed");
    $finish;
end
