// =============================================================================
// Least-loaded substitute (SubstitutePolicy 1)
// =============================================================================
// One cluster, four cores of the same type, cores driven by the stimulus.
//   1. Core 1 takes task 11 and stays busy with heartbeats; tasks 12, 13 queue
//      behind it (3 entries in its checkout queue).
//   2. Core 0 takes task 1 and goes silent: dead_suspect, then fenced.
//   3. The substitute of core 0 is chosen when it dies: core 1 is the lowest
//      live core but the busiest, cores 2 and 3 are empty -> core 2.
//   4. Replayed task 1 and the later task 2 of logical core 0 run on core 2.
// With SubstitutePolicy 0 they would go to core 1 (the check on core 2 fails).

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t lt [14];
initial begin
    lt[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    lt[2]  = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    for (int i = 11; i <= 13; i++) lt[i] = pack_normal_task(2'b00, i, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

task automatic ll_read(input int core, input int unsigned expected);
    automatic device_axi_lite_data_t id;
    fork : ll_read_or_timeout
        csr_read(0, 0, core, CSR_READY, id);
        begin
            repeat (2000) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "[LEAST_LOADED] core %0d did not get task %0d", core, expected);
        end
    join_any
    disable ll_read_or_timeout;
    if (id[TaskIdWidth-1:0] != expected) $fatal(1, "[LEAST_LOADED] core %0d got task %0d, expected %0d", core, id[TaskIdWidth-1:0], expected);
endtask

initial begin : least_loaded_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 11; i <= 13; i++) task_queue_master[0].write(task_queue_base[0], '0, lt[i], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, lt[1], '1, resp);
    ll_read(1, 11);
    ll_read(0, 1);               // core 0 now goes silent
    fork
        busy_with_heartbeat(0, 0, 1, 3000, 100);   // core 1 stays busy, 12 and 13 queued
        begin
            wait_retired(0, 0, 0, 5000);
            if (gen_dut[0].i_dut.smt.core[0][0] != 2) begin
                $error("[LEAST_LOADED] substitute of core 0 is core %0d, expected core 2", gen_dut[0].i_dut.smt.core[0][0]);
            end
            ll_read(2, 1);       // replayed on the least loaded core
            csr_done(0, 0, 2, 1);
            task_queue_master[0].write(task_queue_base[0], '0, lt[2], '1, resp);
            ll_read(2, 2);       // later task of logical core 0: same substitute
            csr_done(0, 0, 2, 2);
        end
    join
    csr_done(0, 0, 1, 11);
    for (int i = 12; i <= 13; i++) begin
        ll_read(1, i);
        csr_done(0, 0, 1, i);
    end
    repeat (100) @(posedge clk_i);
    // every task retired (manual cores: no completion bitmap)
    if (gen_dut[0].i_dut.checkout_queue_empty !== '1) begin
        $error("[LEAST_LOADED] checkout queues not drained: empty %b", gen_dut[0].i_dut.checkout_queue_empty);
    end
    $display("Least-loaded substitute test passed");
    $finish;
end
