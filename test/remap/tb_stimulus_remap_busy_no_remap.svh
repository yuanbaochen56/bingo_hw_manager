// =============================================================================
// A healthy core that is merely busy must keep its tasks (no remap)
// =============================================================================
// Core 0 runs task 1 and keeps writing heartbeats. Task 2 also targets logical
// core 0 while core 1 sits idle, blocked in a ready-queue read. Task 2 must
// wait in core 0's ready queue and run on core 0 after task 1; core 1 must
// never receive it.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t busy_task_1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t busy_task_2 = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

initial begin : remap_busy_no_remap_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;
    automatic bit core1_read_done;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    core1_read_done = 1'b0;
    core1_task_id   = '0;

    $display("[BUSY_NO_REMAP] Push task 1 and let core 0 pick it up");
    task_queue_master[0].write(task_queue_base[0], '0, busy_task_1, '1, resp);
    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    if (core0_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 0 read wrong task id: expected 1 got %0d", core0_task_id[TaskIdWidth-1:0]);
    end

    // Core 1 is idle and polling: an "available" core in the same cluster.
    fork
        begin : core1_reader
            csr_read(0, 0, 1, CSR_READY, core1_task_id);
            core1_read_done = 1'b1;
        end
    join_none
    repeat (5) @(posedge clk_i);

    $display("[BUSY_NO_REMAP] Push task 2 to logical core 0 while core 0 is busy but healthy");
    task_queue_master[0].write(task_queue_base[0], '0, busy_task_2, '1, resp);

    // Core 0 keeps working on task 1 with regular heartbeats.
    busy_with_heartbeat(0, 0, 0, 300, 25);

    if (core1_read_done) begin
        dump_queue_state();
        $fatal(1, "task %0d was remapped to core 1 although logical core 0 is healthy (only busy)",
               core1_task_id[TaskIdWidth-1:0]);
    end
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "core 0 must not be dead_suspect while it sends heartbeats");
    end

    $display("[BUSY_NO_REMAP] Core 0 completes task 1 and reads again");
    csr_done(0, 0, 0, 1);
    fork : wait_task2
        begin
            csr_read(0, 0, 0, CSR_READY, core0_task_id);
        end
        begin
            repeat (300) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "core 0 did not receive task 2");
        end
    join_any
    disable wait_task2;

    if (core0_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(2)) begin
        $fatal(1, "core 0 read wrong task id: expected 2 got %0d", core0_task_id[TaskIdWidth-1:0]);
    end
    csr_done(0, 0, 0, 2);
    repeat (20) @(posedge clk_i);

    if (core1_read_done) begin
        $fatal(1, "core 1 received task %0d; nothing should have been remapped",
               core1_task_id[TaskIdWidth-1:0]);
    end

    $display("Remap busy-no-remap test passed - task 2 stayed on busy but healthy core 0");
    $finish;
end
