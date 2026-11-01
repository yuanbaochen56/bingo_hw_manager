// =============================================================================
// CERF degradation, end to end: the stuck core's own tasks of the cleared group
// =============================================================================
// Core 0 is the only type-4 core. It runs task 1 (group 0, sets core 1) and
// hangs, so replay sticks. The table clears group 0 and sets group 1. Then:
//   task 2: core 1, group 1 (the backup branch), runs
//   task 3: core 1, waits for core 0 (join on task 1)
//   task 4: core 0, group 0, sets core 1: skipped, never reaches a core
//   task 5: core 1, waits for core 0 (join on task 4)
// Tasks 1 and 4 belong to the cleared group, so they retire as skipped tasks
// in order and their dep_set lets the joins run. Nothing moves to core 1.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

localparam logic [4:0] CERF_FB_TYPE = 5'd4;

bingo_hw_manager_task_desc_full_t cfj_t1, cfj_t2, cfj_t3, cfj_t4, cfj_t5;
initial begin
    cfj_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000010));
    cfj_t1.cond_exec_en       = 1'b1;
    cfj_t1.cond_exec_group_id = 5'd0;
    cfj_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 1,
        1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    cfj_t2.cond_exec_en       = 1'b1;
    cfj_t2.cond_exec_group_id = 5'd1;
    cfj_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 1,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000001), 1'b0, 1'b0, 0, 0, '0);
    cfj_t4 = pack_normal_task(2'b00, 16'd4, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000010));
    cfj_t4.cond_exec_en       = 1'b1;
    cfj_t4.cond_exec_group_id = 5'd0;
    cfj_t5 = pack_normal_task(2'b00, 16'd5, 0, 0, 1,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000001), 1'b0, 1'b0, 0, 0, '0);
end

// A push of task 4 into the ready queue of core c. Sampled ($sampled: the
// value just before the edge), so the check sees the push the queue takes at
// that edge, not the next waiting head that the same edge exposes.
logic [1:0] cfj_t4_push;
for (genvar c = 0; c < 2; c++) begin : gen_cfj_t4_push
    assign cfj_t4_push[c] = gen_dut[0].i_dut.ready_queue_push[c][0] &&
                            (gen_dut[0].i_dut.ready_queue_data_in[c][0].task_id == 4);
end

bit cfj_t4_ready;
always @(posedge clk_i) begin
    if (rst_ni && |$sampled(cfj_t4_push)) cfj_t4_ready <= 1'b1;
end

initial begin : cerf_fallback_join_test
    automatic axi_pkg::resp_t resp;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    cerf_fb_en[0] = '0;
    cerf_fb_clear[0] = '0;
    cerf_fb_set[0] = '0;
    cerf_fb_clear[0][CERF_FB_TYPE] = 5'd0;
    cerf_fb_set[0][CERF_FB_TYPE] = 5'd1;
    cerf_fb_en[0][CERF_FB_TYPE] = 1'b1;
    // Group 0 active: task 1 is dispatched to core 0 and runs there
    cerf_write_bitmask(0, 32'h1);

    task_queue_master[0].write(task_queue_base[0], '0, cfj_t1, '1, resp);
    fork : wait_fallback
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][0] === 1'b1 &&
              gen_dut[0].i_dut.cerf_state === 32'h2);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "[CERF_FBJ] no fallback: stuck %0b CERF %h",
                   gen_dut[0].i_dut.replay_stuck_slot[0][0], gen_dut[0].i_dut.cerf_state);
        end
    join_any
    disable wait_fallback;

    task_queue_master[0].write(task_queue_base[0], '0, cfj_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfj_t3, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfj_t4, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfj_t5, '1, resp);

    fork : wait_joins
        wait (task_completed_bitmap[5] === 1'b1);
        begin
            repeat (3000) @(posedge clk_i);
            $fatal(1, "[CERF_FBJ] joins did not run: done t2 %0b t3 %0b t5 %0b, core 0 checkout empty %0b",
                   task_completed_bitmap[2], task_completed_bitmap[3], task_completed_bitmap[5],
                   gen_dut[0].i_dut.checkout_queue_empty[0][0]);
        end
    join_any
    disable wait_joins;
    repeat (20) @(posedge clk_i);

    if (!task_completed_bitmap[2] || !task_completed_bitmap[3]) begin
        $fatal(1, "[CERF_FBJ] task 2 done %0b, task 3 done %0b",
               task_completed_bitmap[2], task_completed_bitmap[3]);
    end
    if (task_completed_bitmap[1] || task_completed_bitmap[4] || cfj_t4_ready) begin
        $fatal(1, "[CERF_FBJ] skipped work ran: task 1 done %0b, task 4 done %0b, task 4 reached a ready queue %0b",
               task_completed_bitmap[1], task_completed_bitmap[4], cfj_t4_ready);
    end
    if (gen_dut[0].i_dut.checkout_queue_empty[0][0] !== 1'b1 ||
        gen_dut[0].i_dut.checkout_queue_empty[1][0] !== 1'b1) begin
        $fatal(1, "[CERF_FBJ] checkout not empty: core 0 %0b core 1 %0b",
               gen_dut[0].i_dut.checkout_queue_empty[0][0], gen_dut[0].i_dut.checkout_queue_empty[1][0]);
    end
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $fatal(1, "[CERF_FBJ] tasks moved: replay %0d remap %0d",
               replay_move_count[0], remap_count[0]);
    end

    $display("CERF fallback join test passed");
    $finish;
end
