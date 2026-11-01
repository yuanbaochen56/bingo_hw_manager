// =============================================================================
// Probe the remap selector inside the top level
// =============================================================================
// Phase 1: logical core 0 is healthy but not polling, core 1 is idle and
//          polling. The selector must keep logical core 0 (no work stealing).
// Phase 2: core 0 takes a task and stops sending heartbeats. While it is only
//          dead_suspect the selector keeps logical core 0; once it is fenced
//          the selector holds logical core 0 until its outstanding task 1 has
//          been replayed (retired), then points logical core 0 to core 1.
// The probe task (logical core 0) waits on a dependency that is never set, so
// it stays at the head of core 0's waiting queue and only the selector output
// is observed.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t probe_hang_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t remap_probe_task = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0,//task info
    1'b1, bingo_hw_manager_dep_code_t'(3'b010),  // waits on core 1, which never sets it
    1'b0, 1'b0, 0, 0, '0// set info
);

initial begin : remap_probe_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t core0_task_id;
    automatic device_axi_lite_data_t unused_task_id;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    // Core 1 is idle and blocked in a ready-queue read.
    fork
        begin
            csr_read(0, 0, 1, CSR_READY, unused_task_id); // cluster 0, core 1
        end
    join_none
    repeat (5) @(posedge clk_i);

    // --- Phase 1: healthy core 0 keeps its task ---
    task_queue_master[0].write(task_queue_base[0], '0, probe_hang_task, '1, resp);
    repeat (10) @(posedge clk_i);
    #1;
    if (gen_dut[0].i_dut.remap_select.core[0] !== bingo_hw_manager_assigned_core_id_t'(0)) begin
        $fatal(1, "healthy logical core 0 must not be remapped, got physical core %0d",
               gen_dut[0].i_dut.remap_select.core[0]);
    end
    if (gen_dut[0].i_dut.ready_queue_empty[0][0] !== 1'b0) begin
        $fatal(1, "task 1 should wait in core 0's ready queue even though core 0 is not polling");
    end

    // Core 0 picks task 1 and then stops sending heartbeats.
    csr_read(0, 0, 0, CSR_READY, core0_task_id);
    if (core0_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 0 read wrong task id: expected 1 got %0d", core0_task_id[TaskIdWidth-1:0]);
    end

    // --- Phase 2: dead core 0 is replaced by core 1 ---
    task_queue_master[0].write(task_queue_base[0], '0, remap_probe_task, '1, resp);
    repeat (10) @(posedge clk_i);
    #1;
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "core 0 should not be dead_suspect yet");
    end
    if (gen_dut[0].i_dut.remap_select.core[0] !== bingo_hw_manager_assigned_core_id_t'(0)) begin
        $fatal(1, "busy but not yet dead core 0 must keep its tasks, got physical core %0d",
               gen_dut[0].i_dut.remap_select.core[0]);
    end

    wait (gen_dut[0].i_dut.core_dead_suspect[0][0] === 1'b1);
    @(posedge clk_i);
    #1;
    if (gen_dut[0].i_dut.remap_select.core[0] !== bingo_hw_manager_assigned_core_id_t'(0)) begin
        $fatal(1, "dead_suspect (not fenced) core 0 must keep its tasks, got physical core %0d",
               gen_dut[0].i_dut.remap_select.core[0]);
    end

    wait (gen_dut[0].i_dut.core_fenced[0][0] === 1'b1);
    #1;
    if (gen_dut[0].i_dut.core_retired[0][0] === 1'b0 &&
        gen_dut[0].i_dut.remap_select.valid[0] !== 1'b0) begin
        $fatal(1, "fenced core 0 must be held until its outstanding tasks are replayed");
    end

    wait_retired(0, 0, 0, 100);
    @(posedge clk_i);
    #1;

    if (gen_dut[0].i_dut.remap_select.valid[0] !== 1'b1) begin
        $fatal(1, "logical core 0 remap_select_valid should assert");
    end

    if (gen_dut[0].i_dut.remap_select.core[0] !== bingo_hw_manager_assigned_core_id_t'(1)) begin
        $fatal(1, "retired logical core 0 should fall back to physical core 1, got %0d",
               gen_dut[0].i_dut.remap_select.core[0]);
    end

    if (gen_dut[0].i_dut.remap_select.cluster[0] !== bingo_hw_manager_assigned_cluster_id_t'(0)) begin
        $fatal(1, "logical core 0 should stay in cluster 0");
    end

    // Task 1 was replayed on core 1, which was polling.
    repeat (5) @(posedge clk_i);
    if (unused_task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 1 should have received replayed task 1, got %0d", unused_task_id[TaskIdWidth-1:0]);
    end

    disable fork;

    $display("Top-level remap probe test passed");
    $finish;
end
