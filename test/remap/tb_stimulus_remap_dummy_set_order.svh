// =============================================================================
// A dummy-set must not release its consumer before its source task finishes
// =============================================================================
// This is the pattern the DFG compiler emits (sw/bingo_dfg.py
// bingo_transform_dfg_add_dummy_set_nodes): the dummy-set node is placed on the
// SAME core right after its source node, and only the checkout-queue FIFO order
// of that core makes the dep_set wait for the source task.
//
//   task 1 (core 0, normal)      -- source, runs for a while
//   task 2 (core 0, dummy-set)   -- sets core 2's column-0 dependency
//   task 3 (core 2, normal)      -- checks core 0, must start after task 1 is done
//
// Core 1 sits idle and polling, which is exactly when a work-stealing remap
// would move the dummy-set away from core 0's checkout queue.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t dso_source_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t dso_dummy_set_task = pack_dummy_set_task(
    2'b01, 16'd2, 0, 0, 0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100)
);

bingo_hw_manager_task_desc_full_t dso_consumer_task = pack_normal_task(
    2'b00, 16'd3, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001),
    1'b0, 1'b0, 0, 0, '0
);

initial begin : remap_dummy_set_order_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;
    automatic device_axi_lite_data_t core2_task_id;
    automatic bit core1_read_done;
    automatic bit core2_read_done;
    automatic bit source_done;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    core1_read_done = 1'b0;
    core2_read_done = 1'b0;
    source_done     = 1'b0;

    // Cores 1 and 2 are idle and polling for work.
    fork
        begin : core1_reader
            csr_read(0, 0, 1, CSR_READY, core1_task_id);
            core1_read_done = 1'b1;
        end
        begin : core2_reader
            csr_read(0, 0, 2, CSR_READY, core2_task_id);
            core2_read_done = 1'b1;
            if (!source_done) begin
                dump_dep_matrix_state();
                dump_queue_state();
                $error("[DUMMY_SET_ORDER] consumer task %0d dispatched to core 2 before source task 1 finished",
                       core2_task_id[TaskIdWidth-1:0]);
            end
        end
    join_none
    repeat (5) @(posedge clk_i);

    $display("[DUMMY_SET_ORDER] Push source (1), dummy-set (2) on core 0 and consumer (3) on core 2");
    task_queue_master[0].write(task_queue_base[0], '0, dso_source_task,    '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dso_dummy_set_task, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dso_consumer_task,  '1, resp);

    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    if (core0_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 0 read wrong task id: expected 1 got %0d", core0_task_id[TaskIdWidth-1:0]);
    end

    // The source task runs for a while (healthy, with heartbeats).
    busy_with_heartbeat(0, 0, 0, 400, 25);

    if (core2_read_done) begin
        $fatal(1, "dependency released early: consumer task %0d started while source task 1 was still running",
               core2_task_id[TaskIdWidth-1:0]);
    end

    $display("[DUMMY_SET_ORDER] Source task 1 completes on core 0");
    source_done = 1'b1;
    csr_done(0, 0, 0, 1);

    fork : wait_consumer
        begin
            wait (core2_read_done);
        end
        begin
            repeat (300) @(posedge clk_i);
            dump_dep_matrix_state();
            dump_queue_state();
            $fatal(1, "consumer task 3 was not released after source task 1 finished");
        end
    join_any
    disable wait_consumer;

    if (core2_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(3)) begin
        $fatal(1, "core 2 read wrong task id: expected 3 got %0d", core2_task_id[TaskIdWidth-1:0]);
    end
    if (core1_read_done) begin
        $fatal(1, "core 1 received task %0d; nothing should run on core 1",
               core1_task_id[TaskIdWidth-1:0]);
    end

    $display("Remap dummy-set order test passed - consumer released only after its source finished");
    $finish;
end
