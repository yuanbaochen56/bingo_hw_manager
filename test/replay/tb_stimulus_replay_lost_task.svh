// =============================================================================
// Replay: the task a dead core was running is replayed on a live core
// =============================================================================
//   task 1 (core 0) sets core 1's column-0 dependency; core 0 hangs on it
//   task 2 (core 1) checks column 0
// Core 0 is fenced, task 1 is replayed on core 1 (lowest live core) and its
// dep_set (still logical core 0) releases task 2.
// EXPECTED: 2 completions, exactly one replayed checkout entry.

localparam int unsigned EXPECTED_TASK_COUNT     = 2;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t lost_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010)
);
bingo_hw_manager_task_desc_full_t consumer_task = pack_normal_task(
    2'b00, 16'd2, 0, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001),
    1'b0, 1'b0, 0, 0, '0
);

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, lost_task, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, consumer_task, '1, resp);
end

final begin
    if (retired_export[0][0][0] !== 1'b1) $error("[REPLAY] core 0 was not retired");
    if (replay_move_count[0] != 1) $error("[REPLAY] expected 1 replayed entry, got %0d", replay_move_count[0]);
end
