// =============================================================================
// Replay: a dead core in cluster 1 is replayed inside cluster 1
// =============================================================================
// Cluster 0: chain 1 (core 0) -> 2 (core 1) -> 3 (core 2).
// Cluster 1: chain 11 (core 0, hangs) -> 12 (core 1) -> 13 (core 2), plus
//            14 (core 0, queued behind 11) -> 15 (core 2, tag 1).
// Core 0 of cluster 1 is fenced; 11 and 14 are replayed on core 1 of cluster 1.
// (Waiting queues are per core index and shared by the clusters, so cluster-0
// tasks queued behind blocked cluster-1 tasks wait for the replay as well.)
// EXPECTED: all 8 tasks complete; only (core 0, cluster 1) fenced.

localparam int unsigned EXPECTED_TASK_COUNT     = 8;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t tc_tasks [8];
initial begin
    for (int cl = 0; cl < 2; cl++) begin
        automatic int b = cl * 10;
        tc_tasks[cl * 3 + 0] = pack_normal_task(2'b00, 16'(b + 1), 0, cl, 0,
            1'b0, '0, 1'b1, 1'b0, 0, cl, bingo_hw_manager_dep_code_t'(3'b010));
        tc_tasks[cl * 3 + 1] = pack_normal_task(2'b00, 16'(b + 2), 0, cl, 1,
            1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b1, 1'b0, 0, cl, bingo_hw_manager_dep_code_t'(3'b100));
        tc_tasks[cl * 3 + 2] = pack_normal_task(2'b00, 16'(b + 3), 0, cl, 2,
            1'b1, bingo_hw_manager_dep_code_t'(3'b010), 1'b0, 1'b0, 0, 0, '0);
    end
    tc_tasks[6] = pack_normal_task(2'b00, 16'd14, 0, 1, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 1, bingo_hw_manager_dep_code_t'(3'b100), '0, bingo_hw_manager_dep_tag_t'(1));
    tc_tasks[7] = pack_normal_task(2'b00, 16'd15, 0, 1, 2,
        1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, bingo_hw_manager_dep_tag_t'(1));
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    // Cluster 1 first, so that its core 0 is busy (and hangs) early.
    task_queue_master[0].write(task_queue_base[0], '0, tc_tasks[3], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, tc_tasks[6], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, tc_tasks[4], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, tc_tasks[5], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, tc_tasks[7], '1, resp);
    for (int i = 0; i < 3; i++) task_queue_master[0].write(task_queue_base[0], '0, tc_tasks[i], '1, resp);
end

final begin
    for (int c = 0; c < 3; c++) begin
        for (int cl = 0; cl < 2; cl++) begin
            if (fenced_export[0][c][cl] !== ((c == 0) && (cl == 1))) begin
                $error("[TWO_CL] fenced[%0d][%0d] = %0b", c, cl, fenced_export[0][c][cl]);
            end
        end
    end
    if (retired_export[0][0][1] !== 1'b1) $error("[TWO_CL] core 0 cluster 1 must be retired");
    if (replay_move_count[0] != 2) $error("[TWO_CL] expected 2 replayed entries, got %0d", replay_move_count[0]);
end
