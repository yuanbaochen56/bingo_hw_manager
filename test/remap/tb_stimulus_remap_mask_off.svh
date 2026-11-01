// =============================================================================
// No same-type core (CoreTypeId all different): detection only
// =============================================================================
// This is the HeMAiA configuration, where the cores of a cluster are not
// interchangeable (accelerator core, DM core, host slot). Core 0 stalls on task 1 and becomes dead_suspect, but task 2
// of logical core 0 must stay queued on core 0 (idle core 1 gets nothing).
// When core 0 recovers it completes task 1 and then runs task 2.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t mask_off_task_1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t mask_off_task_2 = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

initial begin : remap_mask_off_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;
    automatic bit core1_read_done;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    core1_read_done = 1'b0;

    $display("[MASK_OFF] Core 0 takes task 1 and stalls without heartbeat");
    task_queue_master[0].write(task_queue_base[0], '0, mask_off_task_1, '1, resp);
    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    wait (gen_dut[0].i_dut.core_dead_suspect[0][0] === 1'b1);
    $display("[MASK_OFF] Core 0 is dead_suspect");

    fork
        begin : core1_ready_reader
            csr_read(0, 0, 1, CSR_READY, core1_task_id);
            core1_read_done = 1'b1;
        end
    join_none
    repeat (5) @(posedge clk_i);

    $display("[MASK_OFF] Push task 2 to dead logical core 0");
    task_queue_master[0].write(task_queue_base[0], '0, mask_off_task_2, '1, resp);
    repeat (200) @(posedge clk_i);

    if (core1_read_done) begin
        $fatal(1, "task %0d was remapped although no core has the type of core 0",
               core1_task_id[TaskIdWidth-1:0]);
    end
    if (gen_dut[0].i_dut.ready_queue_empty[0][0] !== 1'b0) begin
        dump_queue_state();
        $fatal(1, "task 2 should wait in core 0's ready queue");
    end

    $display("[MASK_OFF] Core 0 recovers: completes task 1, then runs task 2");
    csr_done(0, 0, 0, 1);
    repeat (2) @(posedge clk_i);
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "core 0 dead_suspect should clear after done");
    end
    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    if (core0_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(2)) begin
        $fatal(1, "core 0 read wrong task id: expected 2 got %0d", core0_task_id[TaskIdWidth-1:0]);
    end
    csr_done(0, 0, 0, 2);
    repeat (20) @(posedge clk_i);
    if (core1_read_done) begin
        $fatal(1, "core 1 must not receive any task");
    end

    $display("Remap mask-off test passed - dead core detected, no task remapped");
    $finish;
end
