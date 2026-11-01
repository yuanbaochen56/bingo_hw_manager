// =============================================================================
// CERF degradation: a lost task the CERF does not skip still blocks its core
// =============================================================================
// Core 0 is the only type-4 core. It hangs on task 1, which is no CERF task
// and sets core 1, so replay sticks with task 1 at the head of core 0. The
// table clears group 0 and sets group 1. Then:
//   task 6: core 1, group 1 (backup branch, no dependency), runs
//   task 4: core 0, group 0, sets core 1: skipped, but queued behind task 1
//   task 5: core 1, waits for core 0: never runs (task 1 is lost and was
//           first; task 4's dep_set must not stand in for it)
// Core 0 keeps tasks 1 and 4 in that order.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

localparam logic [4:0] CERF_FB_TYPE = 5'd4;

bingo_hw_manager_task_desc_full_t cfo_t1, cfo_t4, cfo_t5, cfo_t6;
initial begin
    cfo_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000010));
    cfo_t4 = pack_normal_task(2'b00, 16'd4, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000010));
    cfo_t4.cond_exec_en       = 1'b1;
    cfo_t4.cond_exec_group_id = 5'd0;
    cfo_t5 = pack_normal_task(2'b00, 16'd5, 0, 0, 1,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000001), 1'b0, 1'b0, 0, 0, '0);
    cfo_t6 = pack_normal_task(2'b00, 16'd6, 0, 0, 1,
        1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    cfo_t6.cond_exec_en       = 1'b1;
    cfo_t6.cond_exec_group_id = 5'd1;
end

initial begin : cerf_fallback_order_test
    automatic axi_pkg::resp_t resp;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    cerf_fb_en[0] = '0;
    cerf_fb_clear[0] = '0;
    cerf_fb_set[0] = '0;
    cerf_fb_clear[0][CERF_FB_TYPE] = 5'd0;
    cerf_fb_set[0][CERF_FB_TYPE] = 5'd1;
    cerf_fb_en[0][CERF_FB_TYPE] = 1'b1;
    cerf_write_bitmask(0, 32'h1);

    task_queue_master[0].write(task_queue_base[0], '0, cfo_t1, '1, resp);
    fork : wait_fallback
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][0] === 1'b1 &&
              gen_dut[0].i_dut.cerf_state === 32'h2);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "[CERF_FBO] no fallback: stuck %0b CERF %h",
                   gen_dut[0].i_dut.replay_stuck_slot[0][0], gen_dut[0].i_dut.cerf_state);
        end
    join_any
    disable wait_fallback;

    task_queue_master[0].write(task_queue_base[0], '0, cfo_t6, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfo_t4, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfo_t5, '1, resp);

    fork : wait_t6
        wait (task_completed_bitmap[6] === 1'b1);
        begin
            repeat (2000) @(posedge clk_i);
            $fatal(1, "[CERF_FBO] backup task 6 did not run");
        end
    join_any
    disable wait_t6;
    // Task 4 reaches core 0's checkout (behind task 1), then nothing moves
    fork : wait_t4_in
        wait (gen_dut[0].i_dut.waiting_dep_check_queue_empty[0] === 1'b1);
        begin
            repeat (2000) @(posedge clk_i);
            $fatal(1, "[CERF_FBO] task 4 never left the waiting queue");
        end
    join_any
    disable wait_t4_in;
    repeat (2000) @(posedge clk_i);

    if (task_completed_bitmap[1] || task_completed_bitmap[4] || task_completed_bitmap[5]) begin
        $fatal(1, "[CERF_FBO] done: task 1 %0b, task 4 %0b, task 5 %0b (task 5 must wait for lost task 1)",
               task_completed_bitmap[1], task_completed_bitmap[4], task_completed_bitmap[5]);
    end
    if (gen_dut[0].i_dut.checkout_queue_empty[0][0] !== 1'b0 ||
        gen_dut[0].i_dut.checkout_queue_data_out[0][0].task_id !== 16'd1) begin
        $fatal(1, "[CERF_FBO] core 0 checkout head is not task 1 (empty %0b, head %0d)",
               gen_dut[0].i_dut.checkout_queue_empty[0][0],
               gen_dut[0].i_dut.checkout_queue_data_out[0][0].task_id);
    end
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $fatal(1, "[CERF_FBO] tasks moved: replay %0d remap %0d",
               replay_move_count[0], remap_count[0]);
    end

    $display("CERF fallback order test passed");
    $finish;
end
