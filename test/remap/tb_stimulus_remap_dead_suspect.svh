// =============================================================================
// dead_suspect alone does not move work; a fenced core's tasks continue on core 1
// =============================================================================
//   1. Core 0 takes task 1 and sends no heartbeat -> dead_suspect.
//   2. Task 2 (logical core 0) is pushed while core 0 is only dead_suspect: it
//      must still go to core 0's own ready queue, not to the polling core 1.
//   3. Core 0 is fenced: task 1 (running) and task 2 (queued) are replayed on
//      core 1, in that order.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

// Task 1: dispatch to core 0, which will become dead_suspect.
bingo_hw_manager_task_desc_full_t task_to_die = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

// Task 2: also targets logical core 0.
bingo_hw_manager_task_desc_full_t task_after_dead = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

initial begin : remap_dead_suspect_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;
    automatic bit core1_read_done;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    // --- Phase 1: dispatch task 1 to core 0 and let it become dead_suspect ---

    // Make core 0 available.
    fork
        begin
            csr_read(0, 0, 0, CSR_READY, core0_task_id);
        end
    join_none
    repeat (5) @(posedge clk_i);

    $display("[DEAD_REMAP] Push task 1 to logical core 0");
    task_queue_master[0].write(task_queue_base[0], '0, task_to_die, '1, resp);

    // Wait for core 0 to pick up task 1.
    fork : wait_task1
        begin
            wait (gen_dut[0].i_dut.wd_status.busy[0][0] === 1'b1);
        end
        begin
            repeat (300) @(posedge clk_i);
            $fatal(1, "core 0 never became busy with task 1");
        end
    join_any
    disable wait_task1;

    // Do NOT send heartbeat — let the watchdog timer expire.
    $display("[DEAD_REMAP] Waiting for core 0 to become dead_suspect (no heartbeat)");
    fork : wait_dead
        begin
            wait (gen_dut[0].i_dut.core_dead_suspect[0][0] === 1'b1);
        end
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "core 0 did not become dead_suspect after timeout");
        end
    join_any
    disable wait_dead;

    $display("[DEAD_REMAP] core 0 is now dead_suspect");

    // --- Phase 2: task 2 still goes to core 0 while it is only dead_suspect ---

    core1_read_done = 1'b0;
    core1_task_id = '0;

    // Make core 1 available.
    fork
        begin : core1_reader
            csr_read(0, 0, 1, CSR_READY, core1_task_id);
            core1_read_done = 1'b1;
        end
    join_none

    repeat (5) @(posedge clk_i);

    if (gen_dut[0].i_dut.core_available[1][0] !== 1'b1) begin
        $fatal(1, "core 1 should be available");
    end

    $display("[DEAD_REMAP] Push task 2 to logical core 0 (expect core 0's ready queue)");
    task_queue_master[0].write(task_queue_base[0], '0, task_after_dead, '1, resp);
    repeat (10) @(posedge clk_i);
    if (gen_dut[0].i_dut.core_fenced[0][0] !== 1'b0) begin
        $fatal(1, "core 0 was fenced too early; raise TB_WATCHDOG_CONFIRM_TIMEOUT");
    end
    if (core1_read_done || gen_dut[0].i_dut.ready_queue_empty[0][0] !== 1'b0) begin
        $fatal(1, "task 2 must stay on dead_suspect core 0 (core 1 read %0b)", core1_read_done);
    end

    // --- Phase 3: core 0 is fenced; tasks 1 and 2 are replayed on core 1 ---

    fork : wait_core1_or_timeout
        begin
            wait (core1_read_done);
        end
        begin
            repeat (300) @(posedge clk_i);
            if (!core1_read_done) begin
                dump_queue_state();
                $fatal(1, "task 1 was not replayed on core 1");
            end
        end
    join_any
    disable wait_core1_or_timeout;

    if (gen_dut[0].i_dut.core_fenced[0][0] !== 1'b1) begin
        $fatal(1, "core 0 should be fenced once its tasks move");
    end
    if (core1_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 1 should first run replayed task 1, got %0d",
               core1_task_id[TaskIdWidth-1:0]);
    end
    csr_done(0, 0, 1, 1);

    csr_read(0, 0, 1, CSR_READY, core1_task_id);
    if (core1_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(2)) begin
        $fatal(1, "core 1 should then run task 2, got %0d", core1_task_id[TaskIdWidth-1:0]);
    end
    csr_done(0, 0, 1, 2);
    repeat (10) @(posedge clk_i);

    $display("Dead-suspect remap test passed - tasks 1,2 of fenced core 0 continued on core 1");
    $finish;
end
