// =============================================================================
// Replay: all queued tasks of a dead core move to a live core, in order
// =============================================================================
// Core 0 hangs on task 1. Before it is fenced, its queues already hold:
//   task 2 (normal), task 3 (normal, sets core 2 col 0 tag 1),
//   task 4 (dummy-set, sets core 2 col 0 tag 2),
//   task 5 (CERF-skipped, sets core 2 col 0 tag 3)
// Consumers on core 2: task 6 (tag 1), task 7 (tag 2), task 8 (tag 3).
// All five checkout entries of core 0 move to core 1: tasks 1-3 are executed
// there, tasks 4 and 5 only retire through the checkout queue.
// EXPECTED: 6 executed tasks (1, 2, 3, 6, 7, 8), 5 replayed entries.

localparam int unsigned EXPECTED_TASK_COUNT     = 6;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t q_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t q_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t q_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 0, 1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100), '0, bingo_hw_manager_dep_tag_t'(1));
bingo_hw_manager_task_desc_full_t q_t4 = pack_dummy_set_task(2'b01, 16'd4, 0, 0, 0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100), bingo_hw_manager_dep_tag_t'(2));
bingo_hw_manager_task_desc_full_t q_t5;
initial begin
    q_t5 = pack_normal_task(2'b00, 16'd5, 0, 0, 0, 1'b0, '0,
        1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100), '0, bingo_hw_manager_dep_tag_t'(3));
    q_t5.cond_exec_en       = 1'b1;   // CERF group 0 stays inactive: skipped
    q_t5.cond_exec_group_id = 5'd0;
    q_t5.cond_exec_invert   = 1'b0;
end
bingo_hw_manager_task_desc_full_t q_t6 = pack_normal_task(2'b00, 16'd6, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, bingo_hw_manager_dep_tag_t'(1));
bingo_hw_manager_task_desc_full_t q_t7 = pack_normal_task(2'b00, 16'd7, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, bingo_hw_manager_dep_tag_t'(2));
bingo_hw_manager_task_desc_full_t q_t8 = pack_normal_task(2'b00, 16'd8, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, bingo_hw_manager_dep_tag_t'(3));

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, q_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, q_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, q_t3, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, q_t4, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, q_t5, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, q_t6, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, q_t7, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, q_t8, '1, resp);
    repeat (100) @(posedge clk_i);
    if (fenced_export[0][0][0] !== 1'b0 || checkout_empty_export[0][0][0] !== 1'b0) begin
        $fatal(1, "[REPLAY] tasks 1-5 should be queued on core 0 before it is fenced");
    end
end

final begin
    if (retired_export[0][0][0] !== 1'b1) $error("[REPLAY] core 0 was not retired");
    if (replay_move_count[0] != 5) $error("[REPLAY] expected 5 replayed entries, got %0d", replay_move_count[0]);
end
