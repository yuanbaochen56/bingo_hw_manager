// =============================================================================
// Level 2: two dead cores in different clusters
// =============================================================================
// Cluster 0: core 0 type 1, core 1 type 2, cores 2-3 type 3
// Cluster 1: core 0 type 2, cores 1-2 type 1, core 3 type 3
// SubstituteLevelMask = 3'b011.
//   A: core 0 of cluster 0 (type 1) dies on task 1 -> core 1 of cluster 1
//   B: core 0 of cluster 1 (type 2) dies on task 21 -> core 1 of cluster 0
//   tasks 2 / 22 queued behind 1 / 21, set row 2 of their cluster
//   tasks 3 (cl0 c2) / 23 (cl1 c2) check col 0 of their cluster
//   tasks 4 (cl0 c3) / 24 (cl1 c3) independent
//   tasks 5 (cl0 c0) / 25 (cl1 c0) pushed after both are retired
// EXPECTED: all 10 complete; A's tasks on (1, cl1), B's tasks on (1, cl0).

localparam int unsigned EXPECTED_TASK_COUNT     = 10;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t xt [26];
initial begin
    for (int cl = 0; cl < 2; cl++) begin
        automatic int b = cl * 20;
        xt[b + 1] = pack_normal_task(2'b00, 16'(b + 1), 0, cl, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
        xt[b + 2] = pack_normal_task(2'b00, 16'(b + 2), 0, cl, 0, 1'b0, '0, 1'b1, 1'b0, 0, cl,
                                     bingo_hw_manager_dep_code_t'(4'b0100));
        xt[b + 3] = pack_normal_task(2'b00, 16'(b + 3), 0, cl, 2, 1'b1, bingo_hw_manager_dep_code_t'(4'b0001),
                                     1'b0, 1'b0, 0, 0, '0);
        xt[b + 4] = pack_normal_task(2'b00, 16'(b + 4), 0, cl, 3, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
        xt[b + 5] = pack_normal_task(2'b00, 16'(b + 5), 0, cl, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, xt[1], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[21], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[2], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[22], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[3], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[23], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[4], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[24], '1, resp);
    wait_retired(0, 0, 0, 5000);
    wait_retired(0, 1, 0, 5000);
    task_queue_master[0].write(task_queue_base[0], '0, xt[5], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, xt[25], '1, resp);
end

int unsigned xt_moves = 0;
int unsigned xt_remaps = 0;
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.replay_step.fire) begin
            automatic int lcl = gen_dut[0].i_dut.replay_data.assigned_cluster_id;
            if ((gen_dut[0].i_dut.replay_data.assigned_core_id != 0) ||
                (gen_dut[0].i_dut.replay_step.dst_core != 1) || (gen_dut[0].i_dut.replay_step.dst_cluster != 1 - lcl)) begin
                $error("[XCL_TWO_FAULTS] task %0d (logical core %0d cluster %0d) replayed to core %0d cluster %0d",
                       gen_dut[0].i_dut.replay_data.task_id, gen_dut[0].i_dut.replay_data.assigned_core_id, lcl,
                       gen_dut[0].i_dut.replay_step.dst_core, gen_dut[0].i_dut.replay_step.dst_cluster);
            end
            xt_moves++;
        end
        for (int p = 0; p < 4; p++) begin
            for (int cl = 0; cl < 2; cl++) begin
                if (gen_dut[0].i_dut.route.fire[p][cl]) begin
                    automatic int src    = gen_dut[0].i_dut.route.src_core[p][cl];
                    automatic int src_cl = gen_dut[0].i_dut.waiting_dep_check_task_desc[src].assigned_cluster_id;
                    if ((src != p) || (src_cl != cl)) begin
                        if ((src != 0) || (p != 1) || (cl != 1 - src_cl)) begin
                            $error("[XCL_TWO_FAULTS] task %0d of logical core %0d cluster %0d placed on core %0d cluster %0d",
                                   gen_dut[0].i_dut.waiting_dep_check_task_desc[src].task_id, src, src_cl, p, cl);
                        end
                        xt_remaps++;
                    end
                end
            end
        end
    end
end

final begin
    for (int c = 0; c < 4; c++) begin
        for (int cl = 0; cl < 2; cl++) begin
            if (fenced_export[0][c][cl] !== (c == 0)) begin
                $error("[XCL_TWO_FAULTS] fenced[%0d][%0d] = %0b", c, cl, fenced_export[0][c][cl]);
            end
        end
    end
    if (xt_moves != 4 || xt_remaps != 2) begin
        $error("[XCL_TWO_FAULTS] expected 4 replayed and 2 remapped tasks, got %0d / %0d", xt_moves, xt_remaps);
    end
end
