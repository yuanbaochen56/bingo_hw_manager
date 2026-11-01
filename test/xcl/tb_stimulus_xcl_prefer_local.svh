// =============================================================================
// Level 2: the dead core's own cluster is preferred
// =============================================================================
// All cores type 1, SubstituteLevelMask = 3'b011. Core 0 of cluster 1 dies;
// cores 0-2 of cluster 0 are lower-indexed candidates, core 1 of cluster 1 is
// the lowest candidate of its own cluster and must win.
//   task 11 (cl1 c0) hangs
//   task 12 (cl1 c0) queued behind it; sets cl0 row 2 (task 3)
//   tasks 1 (cl0 c0), 2 (cl0 c1) independent
//   task 3 (cl0 c2) checks col 0 of cl0 (task 12)
//   task 13 (cl1 c0), pushed after the dead core is retired
// EXPECTED: all 6 complete; 11, 12 (replay) and 13 (remap) run on core 1 of cluster 1.

localparam int unsigned EXPECTED_TASK_COUNT     = 6;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t xp [14];
initial begin
    xp[11] = pack_normal_task(2'b00, 11, 0, 1, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xp[12] = pack_normal_task(2'b00, 12, 0, 1, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    xp[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xp[2]  = pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xp[3]  = pack_normal_task(2'b00, 3, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    xp[13] = pack_normal_task(2'b00, 13, 0, 1, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, xp[11], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xp[12], '1, resp);
    for (int i = 1; i <= 3; i++) task_queue_master[0].write(task_queue_base[0], '0, xp[i], '1, resp);
    wait_retired(0, 1, 0, 5000);   // chip 0, cluster 1, core 0
    task_queue_master[0].write(task_queue_base[0], '0, xp[13], '1, resp);
end

int unsigned xp_moves = 0;
int unsigned xp_remaps = 0;
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.replay_step.fire) begin
            if ((gen_dut[0].i_dut.replay_step.dst_core != 1) || (gen_dut[0].i_dut.replay_step.dst_cluster != 1)) begin
                $error("[XCL_PREFER_LOCAL] task %0d replayed to core %0d cluster %0d",
                       gen_dut[0].i_dut.replay_data.task_id, gen_dut[0].i_dut.replay_step.dst_core,
                       gen_dut[0].i_dut.replay_step.dst_cluster);
            end
            xp_moves++;
        end
        for (int p = 0; p < 3; p++) begin
            for (int cl = 0; cl < 2; cl++) begin
                if (gen_dut[0].i_dut.route.fire[p][cl]) begin
                    automatic int src    = gen_dut[0].i_dut.route.src_core[p][cl];
                    automatic int src_cl = gen_dut[0].i_dut.waiting_dep_check_task_desc[src].assigned_cluster_id;
                    if ((src == 0) && (src_cl == 1) && ((p != 0) || (cl != 1))) begin
                        if ((p != 1) || (cl != 1)) begin
                            $error("[XCL_PREFER_LOCAL] new task %0d placed on core %0d cluster %0d",
                                   gen_dut[0].i_dut.waiting_dep_check_task_desc[src].task_id, p, cl);
                        end
                        xp_remaps++;
                    end
                end
            end
        end
    end
end

final begin
    if (xp_moves != 2 || xp_remaps != 1) begin
        $error("[XCL_PREFER_LOCAL] expected 2 replayed and 1 remapped task, got %0d / %0d", xp_moves, xp_remaps);
    end
end
