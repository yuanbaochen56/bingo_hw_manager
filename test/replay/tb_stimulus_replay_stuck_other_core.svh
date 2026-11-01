// =============================================================================
// Replay: a stuck core does not block the replay of another fenced core
// =============================================================================
// CoreTypeId: core 0 is the only core of its type, cores 1 and 2 share a type.
//   task 1 (core 0) hangs -> core 0 fenced, no substitute: stuck
//   task 2 (core 2) independent, runs
//   task 3 (core 1) hangs -> core 1 fenced, replayed on core 2 although the
//                            lower core 0 is fenced and stuck
//   task 4 (core 1), pushed after core 1 retired -> remapped to core 2
//   task 5 (core 3) checks col 1 (task 3)
//   task 6 (core 3) checks col 0 (task 1): never runs
// EXPECTED: tasks 2-5 complete; tasks 1 and 6 do not; core 0 stuck, core 1 retired.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t so_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b1000));
bingo_hw_manager_task_desc_full_t so_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 2,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t so_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 1,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b1000));
bingo_hw_manager_task_desc_full_t so_t4 = pack_normal_task(2'b00, 16'd4, 0, 0, 1,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t so_t5 = pack_normal_task(2'b00, 16'd5, 0, 0, 3,
    1'b1, bingo_hw_manager_dep_code_t'(4'b0010), 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t so_t6 = pack_normal_task(2'b00, 16'd6, 0, 0, 3,
    1'b1, bingo_hw_manager_dep_code_t'(4'b0001), 1'b0, 1'b0, 0, 0, '0);

initial begin : stuck_other_core_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, so_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, so_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, so_t3, '1, resp);

    wait_retired(0, 0, 1, 5000);   // chip 0, cluster 0, core 1
    task_queue_master[0].write(task_queue_base[0], '0, so_t4, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, so_t5, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, so_t6, '1, resp);
    repeat (2000) @(posedge clk_i);

    for (int unsigned t = 2; t <= 5; t++) begin
        if (!task_completed_bitmap[t]) $error("[STUCK_OTHER] task %0d must complete", t);
    end
    if (task_completed_bitmap[1] || task_completed_bitmap[6]) begin
        $error("[STUCK_OTHER] task 1 (no substitute) and its dependent task 6 cannot complete");
    end
    if (fenced_export[0][0][0] !== 1'b1 || retired_export[0][0][0] !== 1'b0 ||
        gen_dut[0].i_dut.replay_stuck_slot[0][0] !== 1'b1) begin
        $error("[STUCK_OTHER] core 0 must be fenced and stuck, not retired");
    end
    if (retired_export[0][1][0] !== 1'b1 || gen_dut[0].i_dut.replay_stuck_slot[1][0] !== 1'b0) begin
        $error("[STUCK_OTHER] core 1 must be retired, not stuck");
    end
    if (gen_dut[0].i_dut.replay_stuck_o !== 1'b1) $error("[STUCK_OTHER] replay_stuck_o must stay high");
    if (replay_move_count[0] != 1 || remap_count[0] != 1) begin
        $error("[STUCK_OTHER] expected 1 replayed entry (task 3) and 1 remap (task 4), got %0d / %0d",
               replay_move_count[0], remap_count[0]);
    end
    $display("Replay stuck-other-core test passed");
    $finish;
end

// Everything that leaves core 1 goes to core 2 (same type), never to core 0 or 3
always @(posedge clk_i) begin
    if (rst_ni && gen_dut[0].i_dut.replay_step.fire && (gen_dut[0].i_dut.replay_step.dst_core != 2)) begin
        $error("[STUCK_OTHER] task %0d replayed to core %0d",
               gen_dut[0].i_dut.replay_data.task_id, gen_dut[0].i_dut.replay_step.dst_core);
    end
end
