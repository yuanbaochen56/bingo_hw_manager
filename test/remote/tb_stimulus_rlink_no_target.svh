// =============================================================================
// Level 3: a core type without an export target
// =============================================================================
// Two chiplets in a ring over remote_link, 1 cluster, 3 cores of distinct
// types, SubstituteLevelMask = 3'b111, but the links only have a target for
// type 1 (TB_REMOTE_TARGET_TYPES), so bingo may only export type 1.
// chiplet 0:
//   task 1 (c1, type 2) hangs                     -> no substitute, no target: stuck
//   task 2 (c1) queued behind it                  -> stays on core 1
//   once core 1 is fenced:
//   task 3 (c0, type 1) hangs; sets c2 (tag 0)    -> outstanding, exported
//   task 4 (c0) queued behind it                  -> outstanding, exported
//   task 5 (c2) checks col 0 tag 0 (task 3)
//   after core 0 is retired:
//   task 6 (c0) new task of the dead core         -> exported
// chiplet 1: tasks 11 (c1), 12 (c0), local work next to the imports.
// EXPECTED: tasks 3, 4, 5, 6, 11, 12 complete, 1 and 2 do not; chiplet 0 is
// stuck on core 1 only; exactly tasks 3, 4, 6 are exported, in this order.
// Before the fix, tasks 1 and 2 went to the export FIFO, which the link never
// drained (no target), and the type-1 exports queued behind them forever.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t nt [13];
initial begin
    //                    type    id  chip cl core chk_en chk_code set_en all chip set_cl set_code  chk_tag set_tag
    nt[1]  = pack_normal_task(2'b00, 1, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    nt[2]  = pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    nt[3]  = pack_normal_task(2'b00, 3, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100), 4'd0, 4'd0);
    nt[4]  = pack_normal_task(2'b00, 4, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    nt[5]  = pack_normal_task(2'b00, 5, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, 4'd0, 4'd0);
    nt[6]  = pack_normal_task(2'b00, 6, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    nt[11] = pack_normal_task(2'b00, 11, 1, 0, 1, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    nt[12] = pack_normal_task(2'b00, 12, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
end

initial begin : chip1_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 11; i <= 12; i++) task_queue_master[1].write(task_queue_base[1], '0, nt[i], '1, resp);
end

// Imports on chiplet 1: tasks 3, 4, 6 in order, on core 0
int unsigned nt_imports [$];
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[1].i_dut.imported.fire) begin
            nt_imports.push_back(gen_dut[1].i_dut.imported.desc.task_id);
            if ((gen_dut[1].i_dut.imported.core != 0) || (gen_dut[1].i_dut.imported.cluster != 0)) begin
                $error("[RLINK_NO_TARGET] task %0d imported to core %0d cluster %0d",
                       gen_dut[1].i_dut.imported.desc.task_id, gen_dut[1].i_dut.imported.core,
                       gen_dut[1].i_dut.imported.cluster);
            end
        end
        if (gen_dut[0].i_dut.imported.fire) $error("[RLINK_NO_TARGET] chiplet 0 imported a task");
        if (rd_valid[0] && (rd_core_type[0] != 4'd1)) begin
            $error("[RLINK_NO_TARGET] chiplet 0 exports a task of type %0d", rd_core_type[0]);
        end
        if (task_completed_bitmap[5] && !task_completed_bitmap[3]) $error("[RLINK_NO_TARGET] task 5 before task 3");
    end
end

initial begin : rlink_no_target_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 2; i++) task_queue_master[0].write(task_queue_base[0], '0, nt[i], '1, resp);
    // core 1 dies first: its tasks must not take the export FIFO
    wait (fenced_export[0][1][0] === 1'b1);
    repeat (50) @(posedge clk_i);
    if (gen_dut[0].i_dut.replay_stuck_slot !== 3'b010) begin
        $error("[RLINK_NO_TARGET] core 1 not stuck after its fence (stuck %b)", gen_dut[0].i_dut.replay_stuck_slot);
    end
    for (int i = 3; i <= 5; i++) task_queue_master[0].write(task_queue_base[0], '0, nt[i], '1, resp);
    wait_retired(0, 0, 0, 5000);
    task_queue_master[0].write(task_queue_base[0], '0, nt[6], '1, resp);
    repeat (3000) @(posedge clk_i);
    for (int i = 1; i <= 12; i++) begin
        automatic bit must = (i inside {3, 4, 5, 6, 11, 12});
        if (i inside {7, 8, 9, 10}) continue;
        if (task_completed_bitmap[i] !== must) begin
            $error("[RLINK_NO_TARGET] task %0d completed = %0b, expected %0b", i, task_completed_bitmap[i], must);
        end
    end
    if (nt_imports != '{3, 4, 6}) $error("[RLINK_NO_TARGET] imports %p, expected '{3, 4, 6}", nt_imports);
    if (remote_export_count[0] != 3 || remote_export_count[1] != 0) begin
        $error("[RLINK_NO_TARGET] exports %0d / %0d, expected 3 / 0", remote_export_count[0], remote_export_count[1]);
    end
    if (fenced_export[0] !== 3'b011 || retired_export[0] !== 3'b001 || fenced_export[1] !== 3'b000) begin
        $error("[RLINK_NO_TARGET] fenced %b / %b, retired %b", fenced_export[0], fenced_export[1], retired_export[0]);
    end
    if (gen_dut[0].i_dut.replay_stuck_slot !== 3'b010 || gen_dut[1].i_dut.replay_stuck !== 1'b0) begin
        $error("[RLINK_NO_TARGET] stuck %b / %b", gen_dut[0].i_dut.replay_stuck_slot, gen_dut[1].i_dut.replay_stuck);
    end
    if (!gen_dut[0].i_dut.checkout_queue_empty[0][0]) $error("[RLINK_NO_TARGET] proxy checkout queue not drained");
    $display("Level-3 no-target test passed");
    $finish;
end
