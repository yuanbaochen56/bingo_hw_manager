// =============================================================================
// Level 2 off: the dead core's only same-type peer is in the other cluster
// =============================================================================
// Same CoreTypeId as xcl_fallback, default SubstituteLevelMask (3'b001).
//   task 1 (cl0 c0) hangs -> fenced, no substitute in cluster 0: stuck
//   tasks 2 (cl0 c1), 3 (cl1 c1) independent: complete
// EXPECTED: core 0 of cluster 0 stuck, nothing moved to cluster 1.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t xd [4];
initial begin
    xd[1] = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xd[2] = pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xd[3] = pack_normal_task(2'b00, 3, 0, 1, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

initial begin : xcl_disabled_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 3; i++) task_queue_master[0].write(task_queue_base[0], '0, xd[i], '1, resp);
    fork : wait_stuck
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][0] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $error("[XCL_DISABLED] core 0 of cluster 0 never became stuck");
        end
    join_any
    disable wait_stuck;
    repeat (1000) @(posedge clk_i);
    if (!task_completed_bitmap[2] || !task_completed_bitmap[3]) $error("[XCL_DISABLED] tasks 2 and 3 must complete");
    if (task_completed_bitmap[1]) $error("[XCL_DISABLED] task 1 has no substitute");
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $error("[XCL_DISABLED] nothing may move: %0d replayed, %0d remapped", replay_move_count[0], remap_count[0]);
    end
    if (retired_export[0][0][0] !== 1'b0) $error("[XCL_DISABLED] core 0 of cluster 0 must not be retired");
    $display("Level-2-disabled test passed");
    $finish;
end
