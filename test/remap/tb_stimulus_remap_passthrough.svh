// =============================================================================
// Passthrough: a healthy logical core keeps its task
// =============================================================================
// The task for logical core 0 arrives while core 0 is NOT polling and core 1
// is idle and polling. The task must wait in core 0's ready queue (as in the
// original bingo design) and be read by core 0 later; core 1 gets nothing.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t passthrough_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

initial begin : remap_passthrough_test
    automatic axi_pkg::resp_t resp;
    automatic bit core1_read_done;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    core1_read_done = 1'b0;

    // Core 1 is idle and polling; core 0 is not polling yet.
    fork
        begin : core1_ready_reader
            csr_read(0, 0, 1, CSR_READY, core1_task_id);
            core1_read_done = 1'b1;
        end
    join_none
    repeat (5) @(posedge clk_i);

    $display("[PASSTHROUGH] Push task 1 targeting logical core 0 (core 0 not polling)");
    task_queue_master[0].write(task_queue_base[0], '0, passthrough_task, '1, resp);
    repeat (20) @(posedge clk_i);

    if (core1_read_done) begin
        $fatal(1, "task %0d went to core 1 although logical core 0 is healthy",
               core1_task_id[TaskIdWidth-1:0]);
    end
    if (gen_dut[0].i_dut.ready_queue_empty[0][0] !== 1'b0) begin
        dump_queue_state();
        $fatal(1, "task 1 should wait in core 0's ready queue");
    end

    // Core 0 polls later and finds its task.
    fork : wait_core0_or_timeout
        begin
            csr_read(0, 0, 0, CSR_READY, core0_task_id);
        end
        begin
            repeat (300) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "core 0 did not receive task 1");
        end
    join_any
    disable wait_core0_or_timeout;

    if (core0_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(16'd1)) begin
        $fatal(1, "core 0 read wrong task id: expected 1 got %0d",
               core0_task_id[TaskIdWidth-1:0]);
    end
    if (core1_read_done) begin
        $fatal(1, "core 1 received a task; nothing should have been remapped");
    end

    $display("Remap passthrough test passed - task stayed on logical core 0");
    $finish;
end
