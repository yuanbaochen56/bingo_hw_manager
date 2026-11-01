// =============================================================================
// Replay: a fenced core that comes back cannot retire its task a second time
// =============================================================================
// Core 0 is silent on task 1 until it is fenced, then reports task 1 done and
// polls for more work. Task 1 is replayed on core 1; the zombie done is
// dropped and the zombie never gets another task (the harness checks it).
// EXPECTED: 3 completions, 1 replayed entry, 1 dropped done.

localparam int unsigned EXPECTED_TASK_COUNT     = 3;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t z_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
bingo_hw_manager_task_desc_full_t z_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t z_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 2,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, z_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, z_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, z_t3, '1, resp);
end

final begin
    if (replay_move_count[0] != 1) $error("[REPLAY] expected 1 replayed entry, got %0d", replay_move_count[0]);
    if (fence_drop_count[0] != 1) $error("[REPLAY] expected 1 dropped zombie done, got %0d", fence_drop_count[0]);
end
