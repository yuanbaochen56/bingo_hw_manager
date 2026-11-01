// =============================================================================
// Level 3 loopback: one chiplet, its remote_link targets itself (force remote)
// =============================================================================
// 1 cluster, cores 0 and 1 of type 1, core 2 of type 2. SubstituteLevelMask =
// 3'b100 (no local substitute: every task of a fenced core is exported) and
// ImportSubstituteLevelMask = 3'b001, so an import whose home (core 0, the
// lowest type-1 slot) is fenced runs on core 1. The link packets go through
// the AXI-Lite xbar back to the same chiplet.
//   task 1 (c0) hangs; sets c2 (tag 0)          -> outstanding, exported
//   task 2 (c0) queued behind it                -> outstanding, exported
//   task 3 (c2) checks col 0 tag 0 (task 1)
//   after core 0 is retired:
//   task 4 (c0) new task of the dead core       -> exported
// EXPECTED: tasks 1-4 complete; tasks 1, 2, 4 are exported, imported on this
// chiplet on core 1 and their dones return through the link to proxy slot 0.

localparam int unsigned EXPECTED_TASK_COUNT     = 4;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t lt [5];
initial begin
    //                    type    id  chip cl core chk_en chk_code set_en all chip set_cl set_code  chk_tag set_tag
    lt[1] = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100), 4'd0, 4'd0);
    lt[2] = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    lt[3] = pack_normal_task(2'b00, 3, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0, 4'd0, 4'd0);
    lt[4] = pack_normal_task(2'b00, 4, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 3; i++) task_queue_master[0].write(task_queue_base[0], '0, lt[i], '1, resp);
    wait_retired(0, 0, 0, 5000);
    task_queue_master[0].write(task_queue_base[0], '0, lt[4], '1, resp);
end

int unsigned lb_imports [$];
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.imported.fire) begin
            lb_imports.push_back(gen_dut[0].i_dut.imported.desc.task_id);
            if ((gen_dut[0].i_dut.imported.core != 1) || (gen_dut[0].i_dut.imported.cluster != 0)) begin
                $error("[RLINK_LOOPBACK] task %0d imported to core %0d cluster %0d",
                       gen_dut[0].i_dut.imported.desc.task_id, gen_dut[0].i_dut.imported.core,
                       gen_dut[0].i_dut.imported.cluster);
            end
            if (gen_dut[0].i_dut.remote_dispatch_origin_chip_i != 0 ||
                gen_dut[0].i_dut.remote_dispatch_proxy_slot_i != 0) begin
                $error("[RLINK_LOOPBACK] import from chip %0d slot %0d",
                       gen_dut[0].i_dut.remote_dispatch_origin_chip_i,
                       gen_dut[0].i_dut.remote_dispatch_proxy_slot_i);
            end
        end
        if (task_completed_bitmap[3] && !task_completed_bitmap[1]) $error("[RLINK_LOOPBACK] task 3 before task 1");
    end
end

final begin
    if (lb_imports != '{1, 2, 4}) $error("[RLINK_LOOPBACK] imports %p, expected '{1, 2, 4}", lb_imports);
    if (remote_export_count[0] != 3 || remote_done_in_count[0] != 3) begin
        $error("[RLINK_LOOPBACK] exports %0d, dones in %0d, expected 3 / 3",
               remote_export_count[0], remote_done_in_count[0]);
    end
    if (gen_dut[0].i_dut.replay_stuck !== 1'b0) $error("[RLINK_LOOPBACK] must not be stuck");
    if (fenced_export[0] !== 3'b001) $error("[RLINK_LOOPBACK] fenced %b", fenced_export[0]);
    if (retired_export[0] !== 3'b001) $error("[RLINK_LOOPBACK] core 0 not retired");
    if (!gen_dut[0].i_dut.checkout_queue_empty[0][0]) $error("[RLINK_LOOPBACK] proxy checkout queue not drained");
end
