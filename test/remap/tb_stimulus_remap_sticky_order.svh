// =============================================================================
// Replay + remap are deterministic: all tasks of a dead core go to one substitute, in order
// =============================================================================
// Core 0 takes task 1 and goes silent. Tasks 2, 3 of logical core 0 are pushed
// while it is dead_suspect (they queue on core 0), task 4 after it is retired.
// Task 1 (replayed), 2, 3 (moved) and 4 (remapped) must all run on core 1
// (lowest live core), in push order, although core 2 is idle and polling.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t sticky_hang_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

initial begin : remap_sticky_order_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;
    automatic device_axi_lite_data_t core2_task_id;
    automatic bit core2_read_done;
    automatic int unsigned core1_order [4];

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    core2_read_done = 1'b0;

    $display("[STICKY] Core 0 takes task 1 and goes silent");
    task_queue_master[0].write(task_queue_base[0], '0, sticky_hang_task, '1, resp);
    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    wait (gen_dut[0].i_dut.core_dead_suspect[0][0] === 1'b1);

    // Core 2 idles and polls; it must stay empty.
    fork
        begin : core2_ready_reader
            csr_read(0, 0, 2, CSR_READY, core2_task_id);
            core2_read_done = 1'b1;
        end
    join_none

    $display("[STICKY] Push tasks 2, 3 to dead_suspect logical core 0");
    for (int unsigned t = 2; t <= 3; t++) begin
        automatic bingo_hw_manager_task_desc_full_t desc = pack_normal_task(
            2'b00, bingo_hw_manager_task_id_t'(t), 0, 0, 0,
            1'b0, '0,
            1'b0, 1'b0, 0, 0, '0
        );
        task_queue_master[0].write(task_queue_base[0], '0, desc, '1, resp);
    end
    if (gen_dut[0].i_dut.core_fenced[0][0] !== 1'b0) begin
        $fatal(1, "core 0 was fenced too early; raise TB_WATCHDOG_CONFIRM_TIMEOUT");
    end

    wait_retired(0, 0, 0, 1000);
    $display("[STICKY] Core 0 retired; push task 4 to logical core 0");
    begin
        automatic bingo_hw_manager_task_desc_full_t desc = pack_normal_task(
            2'b00, bingo_hw_manager_task_id_t'(4), 0, 0, 0,
            1'b0, '0,
            1'b0, 1'b0, 0, 0, '0
        );
        task_queue_master[0].write(task_queue_base[0], '0, desc, '1, resp);
    end

    // Core 1 executes whatever it gets (short tasks, below the timeout).
    for (int i = 0; i < 4; i++) begin
        fork : wait_core1_task
            begin
                csr_read(0, 0, 1, CSR_READY, core1_task_id);
            end
            begin
                repeat (500) @(posedge clk_i);
                dump_queue_state();
                $fatal(1, "core 1 did not receive task #%0d of core 0", i);
            end
        join_any
        disable wait_core1_task;
        core1_order[i] = core1_task_id[TaskIdWidth-1:0];
        repeat (5) @(posedge clk_i);
        csr_done(0, 0, 1, core1_order[i]);
    end

    for (int i = 0; i < 4; i++) begin
        if (core1_order[i] != i + 1) begin
            $fatal(1, "core 1 task order mismatch at #%0d: expected %0d got %0d",
                   i, i + 1, core1_order[i]);
        end
    end

    repeat (50) @(posedge clk_i);
    if (core2_read_done) begin
        $fatal(1, "core 2 received task %0d; all tasks of core 0 must use the same substitute",
               core2_task_id[TaskIdWidth-1:0]);
    end

    $display("Remap sticky-order test passed - tasks 1,2,3,4 ran on core 1 in order");
    $finish;
end
