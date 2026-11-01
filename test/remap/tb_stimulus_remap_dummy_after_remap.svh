// =============================================================================
// A dummy-set waits for earlier tasks of its logical core that run elsewhere
// =============================================================================
//   task 1 (core 0, normal)      -- core 0 stalls on it (no heartbeat) -> fenced,
//                                   task 1 is replayed on core 1
//   task 2 (core 0, normal)      -- pushed after core 0 retired: remapped to core 1
//   task 3 (core 0, dummy-set)   -- sets core 2's column-0 dependency
//   task 4 (core 2, normal)      -- checks column 0
//
// The dummy-set stays on core 0's (retired) checkout queue, so without extra
// care it would fire right away and release task 4 before tasks 1 and 2
// finished on core 1. Core 0 also comes back as a zombie and reports task 1
// done; that done must be dropped.
// Expected: task 4 only starts after BOTH task 1 and task 2 are done on core 1.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t dar_stall_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t dar_remapped_task = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t dar_dummy_set_task = pack_dummy_set_task(
    2'b01, 16'd3, 0, 0, 0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100)
);

bingo_hw_manager_task_desc_full_t dar_consumer_task = pack_normal_task(
    2'b00, 16'd4, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001),
    1'b0, 1'b0, 0, 0, '0
);

initial begin : remap_dummy_after_remap_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;
    automatic device_axi_lite_data_t core2_task_id;
    automatic bit core2_read_done;
    automatic bit task2_done;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    core2_read_done = 1'b0;
    task2_done      = 1'b0;

    // Core 2 is idle and polling for the consumer.
    fork
        begin : core2_reader
            csr_read(0, 0, 2, CSR_READY, core2_task_id);
            core2_read_done = 1'b1;
            if (!task2_done) begin
                dump_dep_matrix_state();
                dump_queue_state();
                $error("[DUMMY_AFTER_REMAP] consumer task %0d started before remapped task 2 finished",
                       core2_task_id[TaskIdWidth-1:0]);
            end
        end
    join_none

    $display("[DUMMY_AFTER_REMAP] Core 0 takes task 1 and stalls without heartbeat");
    task_queue_master[0].write(task_queue_base[0], '0, dar_stall_task, '1, resp);
    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    wait_retired(0, 0, 0, 1000);

    // Core 1 takes the replayed task 1 and keeps it running.
    csr_read(0, 0, 1, CSR_READY, core1_task_id);
    if (core1_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 1 should run replayed task 1, got %0d", core1_task_id[TaskIdWidth-1:0]);
    end

    $display("[DUMMY_AFTER_REMAP] Push task 2, dummy-set 3 (core 0) and consumer 4 (core 2)");
    task_queue_master[0].write(task_queue_base[0], '0, dar_remapped_task,  '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dar_dummy_set_task, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dar_consumer_task,  '1, resp);
    repeat (5) @(posedge clk_i);
    if (gen_dut[0].i_dut.remap_outstanding_q[0][0] != 2) begin
        $fatal(1, "expected two outstanding tasks (replayed 1, remapped 2) for logical core 0, got %0d",
               gen_dut[0].i_dut.remap_outstanding_q[0][0]);
    end

    // Core 1 works on task 1 (healthy, with heartbeats). Meanwhile the fenced
    // core 0 comes back and reports task 1 done: it must be dropped.
    fork
        begin
            busy_with_heartbeat(0, 0, 1, 100, 10);
        end
        begin
            repeat (20) @(posedge clk_i);
            $display("[DUMMY_AFTER_REMAP] Zombie core 0 reports task 1 done");
            csr_done(0, 0, 0, 1);
        end
    join
    if (core2_read_done) begin
        $fatal(1, "consumer task 4 was released by the zombie done of core 0");
    end
    csr_done(0, 0, 1, 1);

    csr_read(0, 0, 1, CSR_READY, core1_task_id);
    if (core1_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(2)) begin
        $fatal(1, "core 1 should run remapped task 2, got %0d", core1_task_id[TaskIdWidth-1:0]);
    end
    busy_with_heartbeat(0, 0, 1, 100, 10);
    if (core2_read_done) begin
        $fatal(1, "consumer task 4 was released while remapped task 2 was still running");
    end

    $display("[DUMMY_AFTER_REMAP] Core 1 completes remapped task 2");
    task2_done = 1'b1;
    csr_done(0, 0, 1, 2);

    fork : wait_consumer
        begin
            wait (core2_read_done);
        end
        begin
            repeat (300) @(posedge clk_i);
            dump_dep_matrix_state();
            dump_queue_state();
            $fatal(1, "consumer task 4 was not released after tasks 1 and 2 completed");
        end
    join_any
    disable wait_consumer;

    if (core2_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(4)) begin
        $fatal(1, "core 2 read wrong task id: expected 4 got %0d", core2_task_id[TaskIdWidth-1:0]);
    end
    if (gen_dut[0].i_dut.remap_outstanding_q[0][0] != 0) begin
        $fatal(1, "outstanding remap counter of logical core 0 should be back to 0");
    end

    $display("Remap dummy-after-remap test passed - dummy-set waited for the replayed and remapped tasks");
    $finish;
end
