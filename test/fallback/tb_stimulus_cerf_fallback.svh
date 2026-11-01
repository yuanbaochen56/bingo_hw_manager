// =============================================================================
// CERF degradation: stuck type 4 clears group 0 and sets group 1
// =============================================================================
// Core 0 is the only type-4 core and hangs on task 1, so replay sticks.
// The table stays disabled across that, and the CERF must not move.
// Enabling type 4 then does one read-modify-write: bit 0 clears, bit 1 sets,
// bit 2 (unrelated) stays. Task 2 (group 0, core 1) is skipped. Task 3
// (group 1, core 1) runs. A later host bitmask write is not overwritten.
// Re-arming while the host write is held defers the policy until it drops.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

localparam logic [4:0] CERF_FB_TYPE = 5'd4;

bingo_hw_manager_task_desc_full_t cerf_fb_task_1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t cerf_fb_task_2;
bingo_hw_manager_task_desc_full_t cerf_fb_task_3;
initial begin
    cerf_fb_task_2 = pack_normal_task(
        2'b00, 16'd2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    cerf_fb_task_2.cond_exec_en = 1'b1;
    cerf_fb_task_2.cond_exec_group_id = 5'd0;
    cerf_fb_task_3 = pack_normal_task(
        2'b00, 16'd3, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    cerf_fb_task_3.cond_exec_en = 1'b1;
    cerf_fb_task_3.cond_exec_group_id = 5'd1;
end

// A push of task 2 into the ready queue of core 1. Sampled ($sampled: the
// value just before the edge), so the check sees the push the queue takes at
// that edge, not the next waiting head that the same edge exposes.
logic cerf_fb_task2_push;
assign cerf_fb_task2_push = gen_dut[0].i_dut.ready_queue_push[1][0] &&
                            (gen_dut[0].i_dut.ready_queue_data_in[1][0].task_id == 2);

bit cerf_fb_task2_ready;
always @(posedge clk_i) begin
    if (rst_ni && $sampled(cerf_fb_task2_push)) cerf_fb_task2_ready <= 1'b1;
end

initial begin : cerf_fallback_test
    automatic axi_pkg::resp_t resp;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    if (gen_dut[0].i_dut.CoreTypeId[0][0] !== 4 || gen_dut[0].i_dut.CoreTypeId[1][0] !== 1) begin
        $fatal(1, "[CERF_FB] core types are %0d and %0d, expected 4 and 1",
               gen_dut[0].i_dut.CoreTypeId[0][0], gen_dut[0].i_dut.CoreTypeId[1][0]);
    end

    cerf_fb_en[0] = '0;
    cerf_fb_clear[0] = '0;
    cerf_fb_set[0] = '0;
    cerf_fb_clear[0][CERF_FB_TYPE] = 5'd0;
    cerf_fb_set[0][CERF_FB_TYPE] = 5'd1;
    // Groups 0 and 2 active. The fallback must keep group 2.
    cerf_write_bitmask(0, 32'h5);
    if (gen_dut[0].i_dut.cerf_state !== 32'h5) begin
        $fatal(1, "[CERF_FB] host write left CERF %h", gen_dut[0].i_dut.cerf_state);
    end

    task_queue_master[0].write(task_queue_base[0], '0, cerf_fb_task_1, '1, resp);
    fork : wait_stuck
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][0] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "[CERF_FB] core 0 never stuck (fenced %0b)",
                   gen_dut[0].i_dut.core_fenced[0][0]);
        end
    join_any
    disable wait_stuck;

    repeat (20) @(posedge clk_i);
    if (gen_dut[0].i_dut.cerf_state !== 32'h5 || cerf_fb_evt[0] !== '0) begin
        $fatal(1, "[CERF_FB] disabled table changed CERF %h evt %h",
               gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0]);
    end

    @(negedge clk_i);
    cerf_fb_en[0][CERF_FB_TYPE] <= 1'b1;
    fork : wait_fallback
        wait (gen_dut[0].i_dut.cerf_state === 32'h6 && cerf_fb_evt[0] === 16'h10);
        begin
            repeat (20) @(posedge clk_i);
            $fatal(1, "[CERF_FB] fallback CERF %h evt %h",
                   gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0]);
        end
    join_any
    disable wait_fallback;

    task_queue_master[0].write(task_queue_base[0], '0, cerf_fb_task_2, '1, resp);
    repeat (5) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, cerf_fb_task_3, '1, resp);

    fork : wait_task3
        wait (task_completed_bitmap[3] === 1'b1);
        begin
            repeat (2000) @(posedge clk_i);
            $fatal(1, "[CERF_FB] task 3 did not run (done %b %b %b)",
                   task_completed_bitmap[1], task_completed_bitmap[2], task_completed_bitmap[3]);
        end
    join_any
    disable wait_task3;
    repeat (20) @(posedge clk_i);

    if (task_completed_bitmap[1] || task_completed_bitmap[2] || cerf_fb_task2_ready) begin
        $fatal(1, "[CERF_FB] task 1 done %0b, task 2 done %0b, task 2 reached ready %0b",
               task_completed_bitmap[1], task_completed_bitmap[2], cerf_fb_task2_ready);
    end
    if (gen_dut[0].i_dut.checkout_queue_empty[1][0] !== 1'b1) begin
        $fatal(1, "[CERF_FB] core 1 checkout still holds a task");
    end
    if (gen_dut[0].i_dut.checkout_queue_empty[0][0] !== 1'b0) begin
        $fatal(1, "[CERF_FB] the stuck task left core 0");
    end
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $fatal(1, "[CERF_FB] tasks moved: replay %0d remap %0d",
               replay_move_count[0], remap_count[0]);
    end

    // One fire per enable: a host clear stays cleared.
    cerf_write_bitmask(0, 32'h0);
    repeat (8) begin
        @(posedge clk_i);
        #1;
        if (gen_dut[0].i_dut.cerf_state !== 32'h0 || cerf_fb_evt[0] !== 16'h10) begin
            $fatal(1, "[CERF_FB] policy rewrote the host mask: CERF %h evt %h",
                   gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0]);
        end
    end

    @(negedge clk_i);
    cerf_fb_en[0][CERF_FB_TYPE] <= 1'b0;
    @(posedge clk_i);
    #1;
    if (cerf_fb_evt[0] !== '0) $fatal(1, "[CERF_FB] evt stayed %h after enable dropped", cerf_fb_evt[0]);

    // Host bitmask wins the cycle; the deferred update keeps bit 2 of 32'h5.
    @(negedge clk_i);
    cerf_write_data[0] <= 32'h5;
    cerf_write_en[0]   <= 1'b1;
    cerf_fb_en[0][CERF_FB_TYPE] <= 1'b1;
    repeat (4) begin
        @(posedge clk_i);
        #1;
        if (gen_dut[0].i_dut.cerf_state !== 32'h5 || cerf_fb_evt[0][CERF_FB_TYPE] !== 1'b0) begin
            $fatal(1, "[CERF_FB] policy wrote during the host hold: CERF %h evt %h",
                   gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0]);
        end
    end
    @(negedge clk_i);
    cerf_write_en[0] <= 1'b0;
    @(posedge clk_i);
    #1;
    if (gen_dut[0].i_dut.cerf_state !== 32'h6 || cerf_fb_evt[0] !== 16'h10) begin
        $fatal(1, "[CERF_FB] deferred update CERF %h evt %h",
               gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0]);
    end

    $display("CERF fallback test passed");
    $finish;
end
