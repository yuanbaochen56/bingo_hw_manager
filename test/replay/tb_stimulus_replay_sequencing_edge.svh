// =============================================================================
// Replay: a same-core sequencing edge behind a lost task no longer deadlocks
// =============================================================================
//   task 1 (core 0) sets core 0's own column-0 dependency; core 0 hangs on it
//   task 2 (core 0) checks column 0 (sequencing edge 1 -> 2), sets core 2 col 0 tag 1
//   task 3 (core 2) checks column 0 tag 1
// Without replay, task 2 waits forever for the lost task 1. With replay, task 1
// runs again on core 1, its dep_set releases task 2, which is then remapped to
// core 1 (core 0 is retired), and task 3 follows.
// EXPECTED: 3 completions, 1 replayed entry, task 2 remapped.

localparam int unsigned EXPECTED_TASK_COUNT     = 3;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t s_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b001));
bingo_hw_manager_task_desc_full_t s_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001),
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100), '0, bingo_hw_manager_dep_tag_t'(1));
bingo_hw_manager_task_desc_full_t s_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, bingo_hw_manager_dep_tag_t'(1));

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, s_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, s_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, s_t3, '1, resp);
end

final begin
    if (replay_move_count[0] != 1) $error("[REPLAY] expected 1 replayed entry, got %0d", replay_move_count[0]);
    if (remap_count[0] != 1) $error("[REPLAY] expected task 2 to be remapped, remap count %0d", remap_count[0]);
end
