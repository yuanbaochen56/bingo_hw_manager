// =============================================================================
// Level 3: no live core of the type on any chiplet
// =============================================================================
// Same system as remote_dispatch, chiplets linked in a ring (0 -> 1 -> 0).
// Core 0 dies on both chiplets, so type 1 exists nowhere: each chiplet exports
// the tasks of its core 0 and the other one cannot accept them.
// chiplet 0: task 1 (c0) hangs, sets c1 (task 4); task 2 (c0) queued;
//            task 4 (c1) checks col 0 (task 1); tasks 5, 6 (c2) independent;
//            after the retire: task 7 (c2) independent, task 8 (c0) exported
// chiplet 1: task 11 (c0) hangs; task 13 (c0) queued; tasks 12 (c1), 14 (c2)
//            independent; after the retire: task 15 (c1)
// EXPECTED: 5, 6, 7, 12, 14, 15 complete; 1, 2, 4, 8, 11, 13 do not. Each
// chiplet rejects the other's exports (at import, or by bouncing them once its
// own core 0 is fenced), so both proxy slots 0 end up stuck and nothing waits
// at the chiplet boundary.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t ne [16];
initial begin
    ne[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
    ne[2]  = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    ne[4]  = pack_normal_task(2'b00, 4, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    ne[5]  = pack_normal_task(2'b00, 5, 0, 0, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    ne[6]  = pack_normal_task(2'b00, 6, 0, 0, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    ne[7]  = pack_normal_task(2'b00, 7, 0, 0, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    ne[8]  = pack_normal_task(2'b00, 8, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    ne[11] = pack_normal_task(2'b00, 11, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    ne[12] = pack_normal_task(2'b00, 12, 1, 0, 1, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    ne[13] = pack_normal_task(2'b00, 13, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    ne[14] = pack_normal_task(2'b00, 14, 1, 0, 2, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    ne[15] = pack_normal_task(2'b00, 15, 1, 0, 1, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
end

initial begin : chip1_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 11; i <= 14; i++) task_queue_master[1].write(task_queue_base[1], '0, ne[i], '1, resp);
    wait_retired(1, 0, 0, 5000);
    task_queue_master[1].write(task_queue_base[1], '0, ne[15], '1, resp);
end

initial begin : remote_no_executor_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 6; i++) if (i != 3) task_queue_master[0].write(task_queue_base[0], '0, ne[i], '1, resp);
    wait_retired(0, 0, 0, 5000);
    for (int i = 7; i <= 8; i++) task_queue_master[0].write(task_queue_base[0], '0, ne[i], '1, resp);
    repeat (3000) @(posedge clk_i);
    for (int i = 1; i <= 15; i++) begin
        automatic bit must = (i inside {5, 6, 7, 12, 14, 15});
        if ((i == 3) || (i == 9) || (i == 10)) continue;
        if (task_completed_bitmap[i] !== must) begin
            $error("[REMOTE_NO_EXEC] task %0d completed = %0b, expected %0b", i, task_completed_bitmap[i], must);
        end
    end
    for (int g = 0; g < 2; g++) begin
        automatic int unsigned first = (g == 0) ? 1 : 11;
        automatic int unsigned second = (g == 0) ? 2 : 13;
        if (fenced_export[g] !== 3'b001 || retired_export[g] !== 3'b001) begin
            $error("[REMOTE_NO_EXEC] chiplet %0d fenced %b retired %b", g, fenced_export[g], retired_export[g]);
        end
        // its exports were rejected in order; nothing waits at the boundary
        if ((remote_rejects[g].size() < 2) || (remote_rejects[g][0] != first) || (remote_rejects[g][1] != second)) begin
            $error("[REMOTE_NO_EXEC] chiplet %0d rejects %p, expected %0d, %0d first", g, remote_rejects[g], first, second);
        end
        if (rd_valid[g] !== 1'b0 || rd_in_valid[g] !== 1'b0) begin
            $error("[REMOTE_NO_EXEC] chiplet %0d: export %b / import %b still pending", g, rd_valid[g], rd_in_valid[g]);
        end
        if (remote_rejected_export[g] !== 3'b001 || replay_stuck_export[g] !== 1'b1) begin
            $error("[REMOTE_NO_EXEC] chiplet %0d rejected %b stuck %b", g, remote_rejected_export[g],
                   replay_stuck_export[g]);
        end
        if (stuck_slot_export[g] !== 3'b000) begin
            $error("[REMOTE_NO_EXEC] chiplet %0d locally stuck %b", g, stuck_slot_export[g]);
        end
    end
    $display("Level-3 no-executor test passed");
    $finish;
end
