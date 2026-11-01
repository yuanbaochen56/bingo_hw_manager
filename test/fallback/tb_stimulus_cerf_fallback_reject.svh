// =============================================================================
// CERF degradation after a level-3 reject
// =============================================================================
// Two chiplets in a ring over remote_link, 1 cluster, cores of types 1, 2, 3
// (no local substitute). Chiplet 1's core 0 dies first (task 11, run on
// chiplet 0), so no chiplet has a live type-1 core left except chiplet 0's.
// Chiplet 0, CERF group 0 active, table: type 1 clears group 0, sets group 1.
//   task 1: c0, group 0, sets c1. Core 0 hangs; task 1 is exported to
//           chiplet 1 and rejected there. The proxy slot is rejected, the
//           fallback fires (CERF 0x2) and task 1 retires as skipped.
//   task 2: c1, group 1 (backup branch), runs
//   task 3: c1, waits for c0 (join on task 1), runs
//   task 4: c0, group 0, sets c1: skipped at dispatch, stays on the proxy
//           slot (never exported) and retires as skipped
//   task 5: c1, waits for c0 (join on task 4), runs

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t cfr [12];
initial begin
    //                     type    id  chip cl core chk_en chk_code set_en all chip set_cl set_code
    cfr[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
    cfr[1].cond_exec_en = 1'b1;
    cfr[1].cond_exec_group_id = 5'd0;
    cfr[2]  = pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    cfr[2].cond_exec_en = 1'b1;
    cfr[2].cond_exec_group_id = 5'd1;
    cfr[3]  = pack_normal_task(2'b00, 3, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    cfr[4]  = pack_normal_task(2'b00, 4, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
    cfr[4].cond_exec_en = 1'b1;
    cfr[4].cond_exec_group_id = 5'd0;
    cfr[5]  = pack_normal_task(2'b00, 5, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    cfr[11] = pack_normal_task(2'b00, 11, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
end

always @(posedge clk_i) begin
    if (rst_ni && rd_valid[0] && rd_in_ready[0]) begin
        automatic bingo_hw_manager_task_desc_full_t ed = bingo_hw_manager_task_desc_full_t'(rd_desc[0]);
        if (ed.task_id == 4) $error("[CERF_FBR] skipped task 4 was exported");
    end
end

initial begin : cerf_fallback_reject_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    cerf_fb_en[0] = '0;
    cerf_fb_clear[0] = '0;
    cerf_fb_set[0] = '0;
    cerf_fb_clear[0][1] = 5'd0;
    cerf_fb_set[0][1]   = 5'd1;
    cerf_fb_en[0][1]    = 1'b1;
    cerf_write_bitmask(0, 32'h1);

    // Chiplet 1's core 0 dies; chiplet 0 runs task 11 for it
    task_queue_master[1].write(task_queue_base[1], '0, cfr[11], '1, resp);
    wait_retired(1, 0, 0, 5000);
    wait (task_completed_bitmap[11] === 1'b1);
    if (gen_dut[0].i_dut.cerf_state !== 32'h1) $error("[CERF_FBR] CERF moved early: %h", gen_dut[0].i_dut.cerf_state);

    // Chiplet 0's core 0 dies on task 1: rejected by chiplet 1, then degrade
    task_queue_master[0].write(task_queue_base[0], '0, cfr[1], '1, resp);
    fork : wait_fallback
        wait (remote_rejects[0].size() == 1 && gen_dut[0].i_dut.cerf_state === 32'h2);
        begin
            repeat (20000) @(posedge clk_i);
            $fatal(1, "[CERF_FBR] no fallback: rejects %p rejected %b CERF %h", remote_rejects[0],
                   gen_dut[0].i_dut.remote_rejected_q, gen_dut[0].i_dut.cerf_state);
        end
    join_any
    disable wait_fallback;

    for (int i = 2; i <= 5; i++) task_queue_master[0].write(task_queue_base[0], '0, cfr[i], '1, resp);
    fork : wait_joins
        wait (task_completed_bitmap[5] === 1'b1);
        begin
            repeat (4000) @(posedge clk_i);
            $fatal(1, "[CERF_FBR] joins did not run: done t2 %0b t3 %0b t5 %0b, proxy empty %0b",
                   task_completed_bitmap[2], task_completed_bitmap[3], task_completed_bitmap[5],
                   gen_dut[0].i_dut.checkout_queue_empty[0][0]);
        end
    join_any
    disable wait_joins;
    repeat (200) @(posedge clk_i);

    for (int i = 1; i <= 5; i++) begin
        automatic bit must = (i inside {2, 3, 5});
        if (task_completed_bitmap[i] !== must) begin
            $error("[CERF_FBR] task %0d completed = %0b, expected %0b", i, task_completed_bitmap[i], must);
        end
    end
    if (remote_rejects[0] != '{1} || remote_rejects[1].size() != 0) begin
        $error("[CERF_FBR] rejects %p / %p, expected '{1} / none", remote_rejects[0], remote_rejects[1]);
    end
    if (gen_dut[0].i_dut.remote_rejected_q !== 3'b001 || cerf_fb_evt[0] !== 16'h0002 ||
        gen_dut[0].i_dut.cerf_state !== 32'h2) begin
        $error("[CERF_FBR] chiplet 0 rejected %b evt %h CERF %h", gen_dut[0].i_dut.remote_rejected_q,
               cerf_fb_evt[0], gen_dut[0].i_dut.cerf_state);
    end
    if (gen_dut[0].i_dut.checkout_queue_empty[0][0] !== 1'b1) $error("[CERF_FBR] proxy slot 0 not drained");
    if (rd_in_valid[0] !== 1'b0 || rd_in_valid[1] !== 1'b0) $error("[CERF_FBR] an import is still pending");
    $display("CERF fallback reject test passed");
    $finish;
end
