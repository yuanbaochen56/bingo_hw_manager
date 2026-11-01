// =============================================================================
// Replay: no substitute (no other core has core 0's type, e.g. HeMAiA)
// =============================================================================
// Core 0 hangs on task 1 and is fenced, but no other core may run its tasks:
// replay_stuck is raised, nothing is replayed or remapped. Task 3 (core 1)
// depends on task 1 and never runs; independent tasks on cores 1 and 2 still do.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t ns_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
bingo_hw_manager_task_desc_full_t ns_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 2,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t ns_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t ns_t4 = pack_normal_task(2'b00, 16'd4, 0, 0, 2,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

initial begin : no_substitute_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, ns_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, ns_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, ns_t3, '1, resp);

    fork : wait_stuck
        begin
            wait (replay_stuck_seen[0]);
        end
        begin
            repeat (5000) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "[NO_SUB] replay_stuck was not raised");
        end
    join_any
    disable wait_stuck;

    // The rest of the cluster keeps running.
    task_queue_master[0].write(task_queue_base[0], '0, ns_t4, '1, resp);
    repeat (2000) @(posedge clk_i);

    if (!task_completed_bitmap[2] || !task_completed_bitmap[4]) begin
        $error("[NO_SUB] independent tasks 2 and 4 must complete");
    end
    if (task_completed_bitmap[1] || task_completed_bitmap[3]) begin
        $error("[NO_SUB] task 1 (no substitute) and its dependent task 3 cannot complete");
    end
    if (fenced_export[0][0][0] !== 1'b1 || retired_export[0][0][0] !== 1'b0) begin
        $error("[NO_SUB] core 0 must be fenced but not retired");
    end
    if (gen_dut[0].i_dut.replay_stuck_o !== 1'b1) $error("[NO_SUB] replay_stuck_o must stay high");
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $error("[NO_SUB] nothing may be replayed (%0d) or remapped (%0d)", replay_move_count[0], remap_count[0]);
    end
    $display("Replay no-substitute test passed");
    $finish;
end
