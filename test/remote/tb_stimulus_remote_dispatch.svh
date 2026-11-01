// =============================================================================
// Level 3: remote dispatch to another chiplet
// =============================================================================
// Two chiplets, 1 cluster, 3 cores of distinct types, SubstituteLevelMask =
// 3'b111, chiplet 0 exports to chiplet 1. Core 0 of chiplet 0 dies and no core
// of chiplet 0 has its type.
// chiplet 0:
//   task 1 (c0) hangs; sets c1 (tag 0)          -> outstanding, exported
//   task 2 (c0) queued behind it                -> outstanding, exported
//   task 3 (c0) dummy-set, sets c1 (tag 1)      -> stays on the proxy, not exported
//   task 4 (c1) checks col 0 tag 0 (task 1)
//   task 5 (c1) checks col 0 tag 1 (dummy 3, i.e. after task 2)
//   task 6 (c2) independent
//   after core 0 is retired:
//   task 7 (c0) new task of the dead core, sets c1 (tag 0) -> exported
//   task 8 (c1) checks col 0 tag 0 (task 7)
// chiplet 1: tasks 11, 13 (c0) and 12 (c1), local work next to the imports.
// EXPECTED: all 10 executing tasks complete; tasks 1, 2, 7 are exported in
// this order and run on core 0 of chiplet 1; the dependents on chiplet 0 only
// start after the remote done of their producer.

localparam int unsigned EXPECTED_TASK_COUNT     = 10;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t rt [14];
initial begin
    //                    type    id  chip cl core chk_en chk_code set_en all chip set_cl set_code  chk_tag set_tag
    rt[1] = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010), 4'd0, 4'd0);
    rt[2] = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    rt[3] = pack_dummy_set_task(2'b01, 3, 0, 0, 0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010), 4'd1);
    rt[4] = pack_normal_task(2'b00, 4, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, 4'd0, 4'd0);
    rt[5] = pack_normal_task(2'b00, 5, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, 4'd1, 4'd0);
    rt[6] = pack_normal_task(2'b00, 6, 0, 0, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    rt[7] = pack_normal_task(2'b00, 7, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010), 4'd0, 4'd0);
    rt[8] = pack_normal_task(2'b00, 8, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, 4'd0, 4'd0);
    rt[11] = pack_normal_task(2'b00, 11, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    rt[12] = pack_normal_task(2'b00, 12, 1, 0, 1, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
    rt[13] = pack_normal_task(2'b00, 13, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 6; i++) task_queue_master[0].write(task_queue_base[0], '0, rt[i], '1, resp);
    wait_retired(0, 0, 0, 5000);
    for (int i = 7; i <= 8; i++) task_queue_master[0].write(task_queue_base[0], '0, rt[i], '1, resp);
end

initial begin : chip1_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 11; i <= 13; i++) task_queue_master[1].write(task_queue_base[1], '0, rt[i], '1, resp);
end

// Imports on chiplet 1: tasks 1, 2, 7 in order, on core 0
int unsigned rd_imports [$];
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[1].i_dut.imported.fire) begin
            rd_imports.push_back(gen_dut[1].i_dut.imported.desc.task_id);
            if ((gen_dut[1].i_dut.imported.core != 0) || (gen_dut[1].i_dut.imported.cluster != 0)) begin
                $error("[REMOTE_DISPATCH] task %0d imported to core %0d cluster %0d",
                       gen_dut[1].i_dut.imported.desc.task_id, gen_dut[1].i_dut.imported.core,
                       gen_dut[1].i_dut.imported.cluster);
            end
        end
        if (gen_dut[0].i_dut.imported.fire) $error("[REMOTE_DISPATCH] chiplet 0 imported a task");
        // Dependents start only after their producer completed
        if (task_completed_bitmap[4] && !task_completed_bitmap[1]) $error("[REMOTE_DISPATCH] task 4 before task 1");
        if (task_completed_bitmap[5] && !task_completed_bitmap[2]) $error("[REMOTE_DISPATCH] task 5 before task 2");
        if (task_completed_bitmap[8] && !task_completed_bitmap[7]) $error("[REMOTE_DISPATCH] task 8 before task 7");
    end
end

final begin
    if (rd_imports != '{1, 2, 7}) $error("[REMOTE_DISPATCH] imports %p, expected '{1, 2, 7}", rd_imports);
    if (remote_export_count[0] != 3 || remote_export_count[1] != 0) begin
        $error("[REMOTE_DISPATCH] exports %0d / %0d, expected 3 / 0", remote_export_count[0], remote_export_count[1]);
    end
    if (gen_dut[0].i_dut.replay_stuck !== 1'b0) $error("[REMOTE_DISPATCH] chiplet 0 must not be stuck");
    if (fenced_export[0] !== 3'b001 || fenced_export[1] !== 3'b000) begin
        $error("[REMOTE_DISPATCH] fenced %b / %b", fenced_export[0], fenced_export[1]);
    end
    if (retired_export[0] !== 3'b001) $error("[REMOTE_DISPATCH] core 0 of chiplet 0 not retired");
    if (!gen_dut[0].i_dut.checkout_queue_empty[0][0]) $error("[REMOTE_DISPATCH] proxy checkout queue not drained");
end
