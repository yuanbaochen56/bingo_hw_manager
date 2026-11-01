// =============================================================================
// Full remap flow: dead core -> replay -> remap -> dependency by logical core
// =============================================================================
//   1. Core 0 takes task 1 and stops sending heartbeats -> dead_suspect, then
//      fenced. Its outstanding task 1 is replayed on core 1 (retired).
//   2. Task 2 (logical core 0, sets core 2's dependency on column 0) is
//      remapped to physical core 1 and runs there.
//   3. Task 3 (core 2, checks column 0) must be released by task 2's
//      completion on physical core 1: the dep matrix uses the logical core.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;// expected task count for the test
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;// deadlock threshold for the test
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;// dep matrix log interval for the test

// Task 1 hangs on core 0 (no heartbeat, never completes there).
bingo_hw_manager_task_desc_full_t remap_hang_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,//task_type, task_id, assigned_chiplet_id, assigned_cluster_id, assigned_core_id
    1'b0, '0,//dep_check_en, dep_check_code
    1'b0, 1'b0, 0, 0, '0//dep_set_en, dep_set_all_chiplet, dep_set_chiplet_id, dep_set_cluster_id, dep_set_code
);

// Task 2 is logically assigned to core 0 and sets a dependency for core 2.
// With core 0 retired it must run on physical core 1.
bingo_hw_manager_task_desc_full_t remap_source_task = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100)//dep_set to core 2
);

// Task 3 waits on logical core 0 (column 0). It must be released when task 2
// completes on physical core 1.
bingo_hw_manager_task_desc_full_t remap_dependent_task = pack_normal_task(
    2'b00, 16'd3, 0, 0, 2,//assigned to core 2
    1'b1, bingo_hw_manager_dep_code_t'(3'b001),//need to check dependency on core 0
    1'b0, 1'b0, 0, 0, '0//no dep set
);

initial begin : remap_full_flow_test
    automatic axi_pkg::resp_t resp;
    automatic bit core2_read_done;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t core1_task_id;
    automatic device_axi_lite_data_t core2_task_id;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    core2_read_done = 1'b0;

    // --- Step 1: core 0 takes task 1 and goes silent ---
    $display("[REMAP_FULL] Core 0 takes task 1 and stops sending heartbeats");
    task_queue_master[0].write(task_queue_base[0], '0, remap_hang_task, '1, resp);
    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    if (core0_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 0 read wrong task id: expected 1 got %0d", core0_task_id[TaskIdWidth-1:0]);
    end

    wait_retired(0, 0, 0, 1000);
    $display("[REMAP_FULL] Core 0 is fenced and retired");

    // Core 1 gets the replayed task 1 and completes it.
    fork : wait_replay
        begin
            csr_read(0, 0, 1, CSR_READY, core1_task_id);
        end
        begin
            repeat (300) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "core 1 did not receive replayed task 1");
        end
    join_any
    disable wait_replay;
    if (core1_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 1 should run replayed task 1, got %0d", core1_task_id[TaskIdWidth-1:0]);
    end
    csr_done(0, 0, 1, 1);

    // Core 2 is idle and polling.
    fork
        begin : core2_ready_reader
            csr_read(0, 0, 2, CSR_READY, core2_task_id);
            core2_read_done = 1'b1;
        end
    join_none// the reader runs in the background
    repeat (5) @(posedge clk_i);

    // --- Step 2: task 2 of retired logical core 0 runs on physical core 1 ---
    $display("[REMAP_FULL] Push source task 2: logical core 0, expected physical core 1");
    task_queue_master[0].write(task_queue_base[0], '0, remap_source_task, '1, resp);

    $display("[REMAP_FULL] Push dependent task 3: core 2, waits on logical core 0");
    task_queue_master[0].write(task_queue_base[0], '0, remap_dependent_task, '1, resp);

    fork : wait_core1_or_timeout
        begin
            csr_read(0, 0, 1, CSR_READY, core1_task_id);
        end
        begin
            repeat (300) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "physical core 1 did not receive remapped task 2");
        end
    join_any
    disable wait_core1_or_timeout;

    if (core1_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(2)) begin
        $fatal(1, "physical core 1 read wrong task id: expected 2 got %0d",
               core1_task_id[TaskIdWidth-1:0]);
    end

    // Task 3 must wait until task 2 has completed.
    repeat (50) @(posedge clk_i);
    if (core2_read_done) begin
        $fatal(1, "dependent task 3 started before its source task 2 completed");
    end

    // --- Step 3: completion on physical core 1 sets logical core 0's column ---
    $display("[REMAP_FULL] Complete source task 2 from physical core 1");
    csr_done(0, 0, 1, 2);

    fork : wait_core2_or_timeout
        begin
            wait (core2_read_done);
        end
        begin
            repeat (300) @(posedge clk_i);
            dump_dep_matrix_state();
            dump_queue_state();
            $fatal(1, "dependent task 3 was not released by logical core 0 dep_set");
        end
    join_any
    disable wait_core2_or_timeout;

    if (core2_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(3)) begin
        $fatal(1, "core 2 read wrong task id: expected 3 got %0d",
               core2_task_id[TaskIdWidth-1:0]);
    end

    $display("Top-level remap full-flow test passed");
    $finish;
end
