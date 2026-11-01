// =============================================================================
// Replay: a slow core (silent between the two timeouts) is not fenced
// =============================================================================
// Core 0 stays silent on task 1 for longer than the heartbeat timeout (200)
// but shorter than the confirm timeout (800), then completes it.
// EXPECTED: dead_suspect raised and cleared, no fence, no replay, 2 completions.

localparam int unsigned EXPECTED_TASK_COUNT     = 2;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t slow_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
bingo_hw_manager_task_desc_full_t slow_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, slow_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, slow_t2, '1, resp);
end

final begin
    if (!dead_suspect_seen[0]) $error("[REPLAY] core 0 should have been dead_suspect");
    if (fenced_export[0] !== '0) $error("[REPLAY] no core may be fenced");
    if (replay_move_count[0] != 0) $error("[REPLAY] expected no replay, got %0d", replay_move_count[0]);
end
