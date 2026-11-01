// =============================================================================
// Level 2: substitute in another cluster
// =============================================================================
// Cluster 0: core 0 type 1, cores 1-2 type 2; cluster 1: core 0 type 2,
// core 1 type 1, core 2 type 3. SubstituteLevelMask = 3'b011.
// Core 0 of cluster 0 dies: its only type-1 peer is core 1 of cluster 1.
//   task 1 (cl0 c0) hangs; sets cl0 row 2 (task 4)
//   task 2 (cl0 c0) queued behind it; sets cl1 row 2 (task 5)
//   task 3 (cl0 c1) independent
//   task 4 (cl0 c2) checks col 0 of cl0 (task 1)
//   task 5 (cl1 c2) checks col 0 of cl1 (task 2)
// after core 0 of cluster 0 is retired:
//   task 6 (cl0 c0) new task of the dead core
//   task 7 (cl1 c0) healthy core 0 of cluster 1 (shares waiting queue 0)
//   task 8 (cl0 c0) new task, sets cl0 row 1 (task 9)
//   task 9 (cl0 c1) checks col 0 of cl0 (task 8)
// EXPECTED: all 9 complete; the outstanding (1, 2) and the new (6, 8) tasks
// of the dead core all run on core 1 of cluster 1; dependencies set from
// cluster 1 release consumers in both clusters.

localparam int unsigned EXPECTED_TASK_COUNT     = 9;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t xf [10];
initial begin
    //                    type    id  chip cl core chk_en chk_code set_en all chip set_cl set_code
    xf[1] = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    xf[2] = pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 1, bingo_hw_manager_dep_code_t'(3'b100));
    xf[3] = pack_normal_task(2'b00, 3, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xf[4] = pack_normal_task(2'b00, 4, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    xf[5] = pack_normal_task(2'b00, 5, 0, 1, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    xf[6] = pack_normal_task(2'b00, 6, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xf[7] = pack_normal_task(2'b00, 7, 0, 1, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    xf[8] = pack_normal_task(2'b00, 8, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
    xf[9] = pack_normal_task(2'b00, 9, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 5; i++) task_queue_master[0].write(task_queue_base[0], '0, xf[i], '1, resp);
    wait_retired(0, 0, 0, 5000);   // chip 0, cluster 0, core 0
    for (int i = 6; i <= 9; i++) task_queue_master[0].write(task_queue_base[0], '0, xf[i], '1, resp);
end

// Every task of logical (core 0, cluster 0) that leaves it goes to (core 1, cluster 1)
int unsigned xf_moves = 0;
int unsigned xf_remaps = 0;
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.replay_step.fire) begin
            if ((gen_dut[0].i_dut.replay_data.assigned_core_id != 0) ||
                (gen_dut[0].i_dut.replay_data.assigned_cluster_id != 0) ||
                (gen_dut[0].i_dut.replay_step.dst_core != 1) || (gen_dut[0].i_dut.replay_step.dst_cluster != 1)) begin
                $error("[XCL_FALLBACK] task %0d replayed to core %0d cluster %0d",
                       gen_dut[0].i_dut.replay_data.task_id, gen_dut[0].i_dut.replay_step.dst_core,
                       gen_dut[0].i_dut.replay_step.dst_cluster);
            end
            xf_moves++;
        end
        for (int p = 0; p < 3; p++) begin
            for (int cl = 0; cl < 2; cl++) begin
                if (gen_dut[0].i_dut.route.fire[p][cl]) begin
                    automatic int src    = gen_dut[0].i_dut.route.src_core[p][cl];
                    automatic int src_cl = gen_dut[0].i_dut.waiting_dep_check_task_desc[src].assigned_cluster_id;
                    if ((src == 0) && (src_cl == 0) && ((p != 0) || (cl != 0)) &&
                        (gen_dut[0].i_dut.waiting_dep_check_task_desc[src].task_type != 2'b01)) begin
                        if ((p != 1) || (cl != 1)) begin
                            $error("[XCL_FALLBACK] new task %0d of the dead core placed on core %0d cluster %0d",
                                   gen_dut[0].i_dut.waiting_dep_check_task_desc[src].task_id, p, cl);
                        end
                        xf_remaps++;
                    end
                end
            end
        end
    end
end

final begin
    for (int c = 0; c < 3; c++) begin
        for (int cl = 0; cl < 2; cl++) begin
            if (fenced_export[0][c][cl] !== ((c == 0) && (cl == 0))) begin
                $error("[XCL_FALLBACK] fenced[%0d][%0d] = %0b", c, cl, fenced_export[0][c][cl]);
            end
        end
    end
    if (gen_dut[0].i_dut.replay_stuck !== 1'b0) $error("[XCL_FALLBACK] nothing may be stuck");
    if (xf_moves != 2 || xf_remaps != 2) begin
        $error("[XCL_FALLBACK] expected 2 replayed and 2 remapped tasks, got %0d / %0d", xf_moves, xf_remaps);
    end
end
