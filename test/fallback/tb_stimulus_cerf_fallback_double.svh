// =============================================================================
// CERF degradation when a type with a substitute loses both of its cores
// =============================================================================
// Cores 0 and 1 are type 4 (each other's substitute), core 2 is type 1. Core 0
// runs task 1 (group 0, sets core 2) and hangs: it is fenced and task 1 is
// replayed onto core 1, which hangs on it as well. Core 1 is fenced with no live
// type-4 core left: stuck, and the table clears group 0 and sets group 1. Then:
//   task 2: core 2, group 1 (the backup branch), runs
//   task 3: core 2, waits for core 0 (join on task 1)
//   task 4: core 0, group 0, sets core 2: skipped, never reaches a core
//   task 5: core 2, waits for core 0 (join on task 4)
// Task 1 now heads core 1's queue but belongs to logical core 0, which is
// retired and has no other task elsewhere: with ForeignStuckDrain it retires as
// skipped, then task 4 (held until then) does too, and both joins run. Without
// it (TB_CERF_DOUBLE_EXPECT_STUCK) task 1 stays and neither join runs.
// TB_CERF_DOUBLE_T1_UNGATED: task 1 is no CERF task, so it is still needed; it
// stays at the head even with ForeignStuckDrain, and task 4 cannot overtake it.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

localparam logic [4:0] CERF_FB_TYPE = 5'd4;
`ifndef TB_CERF_DOUBLE_EXPECT_STUCK
  `define TB_CERF_DOUBLE_EXPECT_STUCK 0
`endif
`ifndef TB_CERF_DOUBLE_T1_UNGATED
  `define TB_CERF_DOUBLE_T1_UNGATED 0
`endif
localparam bit CFD_EXPECT_STUCK = `TB_CERF_DOUBLE_EXPECT_STUCK || `TB_CERF_DOUBLE_T1_UNGATED;

bingo_hw_manager_task_desc_full_t cfd_t1, cfd_t2, cfd_t3, cfd_t4, cfd_t5;
initial begin
    cfd_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000100));
    cfd_t1.cond_exec_en       = !`TB_CERF_DOUBLE_T1_UNGATED;
    cfd_t1.cond_exec_group_id = 5'd0;
    cfd_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 2,
        1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    cfd_t2.cond_exec_en       = 1'b1;
    cfd_t2.cond_exec_group_id = 5'd1;
    cfd_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 2,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000001), 1'b0, 1'b0, 0, 0, '0);
    cfd_t4 = pack_normal_task(2'b00, 16'd4, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000100));
    cfd_t4.cond_exec_en       = 1'b1;
    cfd_t4.cond_exec_group_id = 5'd0;
    cfd_t5 = pack_normal_task(2'b00, 16'd5, 0, 0, 2,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000001), 1'b0, 1'b0, 0, 0, '0);
end

// A push of task 4 into the ready queue of core c. Sampled ($sampled: the
// value just before the edge), so the check sees the push the queue takes at
// that edge, not the next waiting head that the same edge exposes.
logic [2:0] cfd_t4_push;
for (genvar c = 0; c < 3; c++) begin : gen_cfd_t4_push
    assign cfd_t4_push[c] = gen_dut[0].i_dut.ready_queue_push[c][0] &&
                            (gen_dut[0].i_dut.ready_queue_data_in[c][0].task_id == 4);
end

bit cfd_t4_ready;
always @(posedge clk_i) begin
    if (rst_ni && |$sampled(cfd_t4_push)) cfd_t4_ready <= 1'b1;
end

initial begin : cerf_fallback_double_test
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

    task_queue_master[0].write(task_queue_base[0], '0, cfd_t1, '1, resp);
    fork : wait_fallback
        wait (gen_dut[0].i_dut.replay_stuck_slot[1][0] === 1'b1 &&
              gen_dut[0].i_dut.core_retired[0][0] === 1'b1 &&
              gen_dut[0].i_dut.cerf_state === 32'h2);
        begin
            repeat (8000) @(posedge clk_i);
            $fatal(1, "[CERF_FBD] no fallback: fenced %b retired %b stuck %b CERF %h",
                   gen_dut[0].i_dut.core_fenced, gen_dut[0].i_dut.core_retired,
                   gen_dut[0].i_dut.replay_stuck_slot, gen_dut[0].i_dut.cerf_state);
        end
    join_any
    disable wait_fallback;
    if (replay_move_count[0] != 1) $fatal(1, "[CERF_FBD] %0d replay moves, expected task 1 once", replay_move_count[0]);

    task_queue_master[0].write(task_queue_base[0], '0, cfd_t2, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfd_t3, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfd_t4, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfd_t5, '1, resp);

    if (!CFD_EXPECT_STUCK) begin
        fork : wait_joins
            wait (task_completed_bitmap[3] === 1'b1 && task_completed_bitmap[5] === 1'b1);
            begin
                repeat (3000) @(posedge clk_i);
                $fatal(1, "[CERF_FBD] joins did not run: done t2 %0b t3 %0b t5 %0b, core 1 checkout empty %0b",
                       task_completed_bitmap[2], task_completed_bitmap[3], task_completed_bitmap[5],
                       gen_dut[0].i_dut.checkout_queue_empty[1][0]);
            end
        join_any
        disable wait_joins;
        repeat (20) @(posedge clk_i);
        if (!task_completed_bitmap[2]) $fatal(1, "[CERF_FBD] backup task 2 did not run");
        if (task_completed_bitmap[1] || task_completed_bitmap[4] || cfd_t4_ready)
            $fatal(1, "[CERF_FBD] skipped work ran: task 1 done %0b, task 4 done %0b, task 4 reached a ready queue %0b",
                   task_completed_bitmap[1], task_completed_bitmap[4], cfd_t4_ready);
        for (int c = 0; c < 3; c++)
            if (gen_dut[0].i_dut.checkout_queue_empty[c][0] !== 1'b1)
                $fatal(1, "[CERF_FBD] core %0d checkout not empty", c);
        if (gen_dut[0].i_dut.remap_outstanding_q[0][0] != 0)
            $fatal(1, "[CERF_FBD] logical core 0 still has %0d moved tasks", gen_dut[0].i_dut.remap_outstanding_q[0][0]);
        $display("CERF fallback double test passed");
    end else begin
        repeat (3000) @(posedge clk_i);
        if (!task_completed_bitmap[2]) $fatal(1, "[CERF_FBD] backup task 2 did not run");
        if (task_completed_bitmap[3] || task_completed_bitmap[5])
            $fatal(1, "[CERF_FBD] a join ran without ForeignStuckDrain: t3 %0b t5 %0b",
                   task_completed_bitmap[3], task_completed_bitmap[5]);
        if (gen_dut[0].i_dut.checkout_queue_empty[1][0] ||
            gen_dut[0].i_dut.checkout_queue_data_out[1][0].task_id != 1)
            $fatal(1, "[CERF_FBD] core 1 checkout head is not task 1");
        if (task_completed_bitmap[4] || cfd_t4_ready)
            $fatal(1, "[CERF_FBD] task 4 overtook task 1");
        $display("CERF fallback double (task 1 kept) test passed");
    end
    $finish;
end
