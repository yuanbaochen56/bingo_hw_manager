// =============================================================================
// Level 2: no same-type core anywhere in the chiplet
// =============================================================================
// Core 0 of cluster 0 is the only type-4 core, SubstituteLevelMask = 3'b011.
//   task 1 (cl0 c0) hangs -> fenced, stuck; sets cl0 row 2 (task 6)
//   task 2 (cl0 c1), 3 (cl1 c2) independent
//   task 4 (cl1 c0) healthy core 0 of cluster 1; sets cl1 row 1 (task 5)
//   task 5 (cl1 c1) checks col 0 of cl1 (task 4)
//   task 6 (cl0 c2) checks col 0 of cl0 (task 1): never runs
// after the stuck:
//   tasks 7 (cl0 c1), 8 (cl1 c1) independent: must still complete
//   task 9 (cl0 c0) new task of the stuck core: held
//   task 10 (cl1 c0) behind task 9 in the waiting queue of core index 0, which
//     the clusters share: held as well (known limitation, locked in here)
// EXPECTED: 2, 3, 4, 5, 7, 8 complete; 1, 6, 9, 10 do not.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t xn [11];
initial begin
    xn[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    xn[2]  = pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xn[3]  = pack_normal_task(2'b00, 3, 0, 1, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xn[4]  = pack_normal_task(2'b00, 4, 0, 1, 0, 1'b0, '0, 1'b1, 1'b0, 0, 1, bingo_hw_manager_dep_code_t'(3'b010));
    xn[5]  = pack_normal_task(2'b00, 5, 0, 1, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    xn[6]  = pack_normal_task(2'b00, 6, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    xn[7]  = pack_normal_task(2'b00, 7, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xn[8]  = pack_normal_task(2'b00, 8, 0, 1, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xn[9]  = pack_normal_task(2'b00, 9, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xn[10] = pack_normal_task(2'b00, 10, 0, 1, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

initial begin : xcl_no_substitute_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 6; i++) task_queue_master[0].write(task_queue_base[0], '0, xn[i], '1, resp);
    fork : wait_stuck
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][0] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $error("[XCL_NO_SUB] core 0 of cluster 0 never became stuck");
        end
    join_any
    disable wait_stuck;
    for (int i = 7; i <= 10; i++) task_queue_master[0].write(task_queue_base[0], '0, xn[i], '1, resp);
    repeat (2000) @(posedge clk_i);

    foreach (xn[i]) begin
        automatic bit must = (i inside {2, 3, 4, 5, 7, 8});
        if (i == 0) continue;
        if (task_completed_bitmap[i] !== must) begin
            $error("[XCL_NO_SUB] task %0d completed = %0b, expected %0b", i, task_completed_bitmap[i], must);
        end
    end
    for (int c = 0; c < 3; c++) begin
        for (int cl = 0; cl < 2; cl++) begin
            if (fenced_export[0][c][cl] !== ((c == 0) && (cl == 0))) begin
                $error("[XCL_NO_SUB] fenced[%0d][%0d] = %0b", c, cl, fenced_export[0][c][cl]);
            end
        end
    end
    if (gen_dut[0].i_dut.replay_stuck_slot !== 6'b000001) begin
        $error("[XCL_NO_SUB] only core 0 of cluster 0 may be stuck: %b", gen_dut[0].i_dut.replay_stuck_slot);
    end
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $error("[XCL_NO_SUB] nothing may move: %0d replayed, %0d remapped", replay_move_count[0], remap_count[0]);
    end
    $display("Level-2 no-substitute test passed");
    $finish;
end
