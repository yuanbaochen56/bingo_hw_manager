// =============================================================================
// Level 3: reject on import, then another type over the same link
// =============================================================================
// Two chiplets in a ring over remote_link, 1 cluster, cores of types 1, 2, 3
// (no local substitute for any core).
// 1. chiplet 1: task 11 (c0) hangs, task 12 (c1) local. Core 0 is fenced and
//    task 11 is exported to chiplet 0, where core 0 is still alive: imported,
//    run and its done returned (normal level 3).
// 2. chiplet 0: task 1 (c0) hangs, task 2 (c0) queued. Exported to chiplet 1,
//    whose only type-1 core is fenced: both are rejected at import, in order,
//    and proxy slot 0 of chiplet 0 is stuck. Task 5 (c0), sent after that, is
//    held (never exported).
// 3. chiplet 0: task 3 (c1, type 2) hangs, sets c2; task 4 (c1) queued; task 6
//    (c2) checks col 1 (task 3). Exported to chiplet 1 behind the rejects and
//    run on its core 1: the link keeps working after a reject.
// EXPECTED: 11, 12, 3, 4, 6 complete; 1, 2, 5 do not; chiplet 0 rejects {1, 2},
// stuck on proxy slot 0 only; chiplet 1 not stuck.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t jt [13];
initial begin
    //                    type    id  chip cl core chk_en chk_code set_en all chip set_cl set_code  chk_tag set_tag
    jt[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    jt[2]  = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    jt[3]  = pack_normal_task(2'b00, 3, 0, 0, 1, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100), 4'd0, 4'd0);
    jt[4]  = pack_normal_task(2'b00, 4, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    jt[5]  = pack_normal_task(2'b00, 5, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    jt[6]  = pack_normal_task(2'b00, 6, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b010), 1'b0, 1'b0, 0, 0, '0, 4'd0, 4'd0);
    jt[11] = pack_normal_task(2'b00, 11, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    jt[12] = pack_normal_task(2'b00, 12, 1, 0, 1, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
end

int unsigned jt_imports [2][$];
always @(posedge clk_i) begin
    if (rst_ni) begin
        for (int g = 0; g < 2; g++) begin
            if (import_fire_export[g]) jt_imports[g].push_back(import_task_export[g]);
        end
        if (rd_valid[0] && rd_in_ready[0]) begin
            automatic bingo_hw_manager_task_desc_full_t ed = bingo_hw_manager_task_desc_full_t'(rd_desc[0]);
            if (ed.task_id == 5) $error("[RLINK_REJECT] task 5 of a rejected proxy was exported");
        end
        if (task_completed_bitmap[6] && !task_completed_bitmap[3]) $error("[RLINK_REJECT] task 6 before task 3");
    end
end

initial begin : rlink_reject_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    // 1. chiplet 1's core 0 dies; chiplet 0 runs task 11 for it
    for (int i = 11; i <= 12; i++) task_queue_master[1].write(task_queue_base[1], '0, jt[i], '1, resp);
    wait_retired(1, 0, 0, 5000);
    wait (task_completed_bitmap[11] === 1'b1);
    // 2. chiplet 0's core 0 dies: nobody can run type 1 any more
    for (int i = 1; i <= 2; i++) task_queue_master[0].write(task_queue_base[0], '0, jt[i], '1, resp);
    wait (remote_rejects[0].size() == 2);
    task_queue_master[0].write(task_queue_base[0], '0, jt[5], '1, resp);
    // 3. chiplet 0's core 1 dies: type 2 still runs on chiplet 1
    for (int i = 3; i <= 4; i++) task_queue_master[0].write(task_queue_base[0], '0, jt[i], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, jt[6], '1, resp);
    repeat (4000) @(posedge clk_i);
    for (int i = 1; i <= 12; i++) begin
        automatic bit must = (i inside {3, 4, 6, 11, 12});
        if (i inside {7, 8, 9, 10}) continue;
        if (task_completed_bitmap[i] !== must) begin
            $error("[RLINK_REJECT] task %0d completed = %0b, expected %0b", i, task_completed_bitmap[i], must);
        end
    end
    if (remote_rejects[0] != '{1, 2} || remote_rejects[1].size() != 0) begin
        $error("[RLINK_REJECT] rejects %p / %p, expected '{1, 2} / none", remote_rejects[0], remote_rejects[1]);
    end
    if (jt_imports[0] != '{11} || jt_imports[1] != '{3, 4}) begin
        $error("[RLINK_REJECT] imports %p / %p, expected '{11} / '{3, 4}", jt_imports[0], jt_imports[1]);
    end
    if (gen_dut[0].i_dut.remote_rejected_q !== 3'b001 || gen_dut[0].i_dut.replay_stuck !== 1'b1 ||
        gen_dut[0].i_dut.replay_stuck_slot !== 3'b000) begin
        $error("[RLINK_REJECT] chiplet 0 rejected %b stuck %b / %b", gen_dut[0].i_dut.remote_rejected_q,
               gen_dut[0].i_dut.replay_stuck, gen_dut[0].i_dut.replay_stuck_slot);
    end
    if (gen_dut[1].i_dut.remote_rejected_q !== 3'b000 || gen_dut[1].i_dut.replay_stuck !== 1'b0) begin
        $error("[RLINK_REJECT] chiplet 1 rejected %b stuck %b", gen_dut[1].i_dut.remote_rejected_q, gen_dut[1].i_dut.replay_stuck);
    end
    if (fenced_export[0] !== 3'b011 || retired_export[0] !== 3'b011 || fenced_export[1] !== 3'b001) begin
        $error("[RLINK_REJECT] fenced %b / %b, retired %b", fenced_export[0], fenced_export[1], retired_export[0]);
    end
    // proxy slot 0 keeps its rejected entries; slot 1 drained through remote dones
    if (!gen_dut[0].i_dut.checkout_queue_empty[1][0]) $error("[RLINK_REJECT] proxy slot 1 not drained");
    if (rd_in_valid[0] !== 1'b0 || rd_in_valid[1] !== 1'b0) $error("[RLINK_REJECT] an import is still pending");
    $display("Level-3 reject test passed");
    $finish;
end
