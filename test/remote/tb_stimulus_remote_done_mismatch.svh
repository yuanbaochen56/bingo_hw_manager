// =============================================================================
// Level 3: remote done with a wrong task id
// =============================================================================
// Same system as remote_dispatch. Core 0 of chiplet 0 hangs on task 1; tasks
// 1 and 2 are exported and run on chiplet 1. The remote done stream to
// chiplet 0 is corrupted (task id forced to 99).
// EXPECTED: chiplet 0 flags remote_done_mismatch_o, its proxy slot retires
// nothing (tasks 1, 2 stay in its checkout queue, task 4 that depends on
// task 1 never starts), task 6 on core 2 completes.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t dm [7];
initial begin
    dm[1] = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
    dm[2] = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    dm[4] = pack_normal_task(2'b00, 4, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    dm[6] = pack_normal_task(2'b00, 6, 0, 0, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

initial begin : remote_done_mismatch_test
    automatic axi_pkg::resp_t resp;
    force gen_dut[0].i_dut.remote_done_task_id_i = 12'd99;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 6; i++) if (i inside {1, 2, 4, 6}) task_queue_master[0].write(task_queue_base[0], '0, dm[i], '1, resp);
    wait_retired(0, 0, 0, 5000);
    repeat (3000) @(posedge clk_i);
    if (gen_dut[0].i_dut.remote_done_mismatch_o !== 1'b1) $error("[DONE_MISMATCH] mismatch not flagged");
    if (gen_dut[1].i_dut.remote_done_mismatch_o !== 1'b0) $error("[DONE_MISMATCH] chiplet 1 flagged a mismatch");
    if (remote_import_count[1] != 2) $error("[DONE_MISMATCH] chiplet 1 imported %0d tasks, expected 2", remote_import_count[1]);
    if (!task_completed_bitmap[1] || !task_completed_bitmap[2]) $error("[DONE_MISMATCH] tasks 1, 2 did not run on chiplet 1");
    if (!task_completed_bitmap[6]) $error("[DONE_MISMATCH] task 6 did not complete");
    if (task_completed_bitmap[4]) $error("[DONE_MISMATCH] task 4 started although task 1 never retired");
    if (gen_dut[0].i_dut.checkout_queue_empty[0][0]) $error("[DONE_MISMATCH] proxy slot retired its tasks");
    if (retire_count[0][1] != 0 || retire_count[0][2] != 0) $error("[DONE_MISMATCH] tasks 1 / 2 retired on chiplet 0");
    $display("Level-3 remote done mismatch test passed");
    $finish;
end
