// =============================================================================
// Level 3: the executing core dies after the import (bounce)
// =============================================================================
// Two chiplets in a ring over remote_link, 1 cluster, cores of types 1, 2, 3.
// chiplet 0: task 1 (c0) hangs, task 2 (c0) queued -> exported to chiplet 1.
// chiplet 1: imports 1 and 2 on its core 0, which hangs on task 1. Its replay
//            finds no other type-1 core and bounces both back as rejects: proxy
//            slot 0 of chiplet 0 becomes stuck. Core 0 of chiplet 1 is retired.
//            Its next own task 13 (c0) is exported to chiplet 0, whose type-1
//            core is dead as well: rejected at import.
//            Task 12 (c1) and chiplet 0's task 14 (c2) are local and complete.
// EXPECTED: 12, 14 complete; 1, 2, 13 do not; chiplet 0 rejects {1, 2}, chiplet
// 1 rejects {13}; both stuck on proxy slot 0 only.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t bt [15];
initial begin
    //                    type    id  chip cl core chk_en chk_code set_en all chip set_cl set_code
    bt[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    bt[2]  = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    bt[12] = pack_normal_task(2'b00, 12, 1, 0, 1, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    bt[13] = pack_normal_task(2'b00, 13, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    bt[14] = pack_normal_task(2'b00, 14, 0, 0, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

int unsigned bt_imports [2][$];
int unsigned bt_bounces;
always @(posedge clk_i) begin
    if (rst_ni) begin
        for (int g = 0; g < 2; g++) begin
            if (import_fire_export[g]) bt_imports[g].push_back(import_task_export[g]);
        end
        if (gen_dut[1].i_dut.replay_step.bounce) bt_bounces++;
        if (gen_dut[0].i_dut.replay_step.bounce) $error("[RLINK_BOUNCE] chiplet 0 bounced an entry");
    end
end

initial begin : rlink_bounce_test
    automatic axi_pkg::resp_t resp;
    bt_bounces = 0;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[1].write(task_queue_base[1], '0, bt[12], '1, resp);
    for (int i = 1; i <= 2; i++) task_queue_master[0].write(task_queue_base[0], '0, bt[i], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, bt[14], '1, resp);
    wait (remote_rejects[0].size() == 2);
    wait_retired(1, 0, 0, 5000);
    task_queue_master[1].write(task_queue_base[1], '0, bt[13], '1, resp);
    repeat (3000) @(posedge clk_i);
    foreach (bt[i]) begin
        automatic bit must = (i inside {12, 14});
        if (!(i inside {1, 2, 12, 13, 14})) continue;
        if (task_completed_bitmap[i] !== must) begin
            $error("[RLINK_BOUNCE] task %0d completed = %0b, expected %0b", i, task_completed_bitmap[i], must);
        end
    end
    if (remote_rejects[0] != '{1, 2} || remote_rejects[1] != '{13}) begin
        $error("[RLINK_BOUNCE] rejects %p / %p, expected '{1, 2} / '{13}", remote_rejects[0], remote_rejects[1]);
    end
    if (bt_imports[1] != '{1, 2} || bt_imports[0].size() != 0 || bt_bounces != 2) begin
        $error("[RLINK_BOUNCE] imports %p / %p, bounces %0d, expected none / '{1, 2}, 2",
               bt_imports[0], bt_imports[1], bt_bounces);
    end
    for (int g = 0; g < 2; g++) begin
        if (remote_rejected_export[g] !== 3'b001 || stuck_slot_export[g] !== 3'b000 ||
            fenced_export[g] !== 3'b001 || retired_export[g] !== 3'b001) begin
            $error("[RLINK_BOUNCE] chiplet %0d rejected %b stuck %b fenced %b retired %b", g,
                   remote_rejected_export[g], stuck_slot_export[g],
                   fenced_export[g], retired_export[g]);
        end
    end
    // chiplet 1, core 0: the bounced imports are gone; only its own rejected
    // export (task 13) stays on the proxy
    if ((gen_dut[1].i_dut.checkout_queue_usage[0][0] != 1) ||
        (gen_dut[1].i_dut.checkout_queue_data_out[0][0].task_id != 13)) begin
        $error("[RLINK_BOUNCE] chiplet 1 core 0 holds %0d entries, head task %0d (expected only task 13)",
               gen_dut[1].i_dut.checkout_queue_usage[0][0], gen_dut[1].i_dut.checkout_queue_data_out[0][0].task_id);
    end
    $display("Level-3 bounce test passed");
    $finish;
end
