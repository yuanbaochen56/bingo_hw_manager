// =============================================================================
// Replay disabled (confirm timeout 0): detection only
// =============================================================================
// Core 0 hangs on task 1. It becomes dead_suspect, but is never fenced;
// nothing is replayed or remapped, so task 2 (depends on task 1) never runs.
// Independent task 3 completes.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t off_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
bingo_hw_manager_task_desc_full_t off_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t off_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 2,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

initial begin : replay_disabled_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, off_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, off_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, off_t3, '1, resp);
    repeat (4000) @(posedge clk_i);

    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b1) $error("[OFF] core 0 must be dead_suspect");
    if (fenced_export[0] !== '0) $error("[OFF] nothing may be fenced with the confirm timeout at 0");
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $error("[OFF] nothing may be replayed (%0d) or remapped (%0d)", replay_move_count[0], remap_count[0]);
    end
    if (!task_completed_bitmap[3]) $error("[OFF] independent task 3 must complete");
    if (task_completed_bitmap[1] || task_completed_bitmap[2]) $error("[OFF] tasks 1 and 2 cannot complete");
    $display("Replay disabled test passed");
    $finish;
end
