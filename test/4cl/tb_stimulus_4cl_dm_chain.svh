// =============================================================================
// Four clusters: DM cores die one after the other
// =============================================================================
// 4 clusters x 3 cores, the layout of a four-cluster hemaia_ci: core 0 type 1
// (GEMM, bound to its cluster: SubstituteL2TypeEn bit 1 clear), core 1 type 2
// (DM), core 2 type 0 (host / empty slot). SubstituteLevelMask = 3'b011.
// A cluster has one DM core, so a dead DM core's tasks go to the DM core of
// the lowest-numbered other cluster that is still alive.
//   tasks 21, 22 (cl2 DM); 21 hangs                      -> both to cl0 DM
//   tasks 1 (cl0 DM), 11 (cl1 DM), 31 (cl3 DM) independent
//   TB_4CL_DM_FAULTS >= 2: task 22 hangs on cl0 DM       -> cl0's and cl2's tasks to cl1 DM
//   TB_4CL_DM_FAULTS >= 3: task 23 hangs on cl1 DM       -> every DM task to cl3 DM
//   after each retirement, new tasks of the dead logical cores are pushed
//   (remapped to the current substitute)
// Every replay move and every remap must go to the DM core the substitute rule
// gives for the task's logical cluster and the fenced cores at that moment.
// With the event log on, its items name the twelve slots (cluster in the high
// nibble, flat substitute index up to 10 in the move argument).

`ifndef TB_4CL_DM_FAULTS
  `define TB_4CL_DM_FAULTS 1
`endif
localparam int unsigned DM_FAULTS = `TB_4CL_DM_FAULTS;
localparam int unsigned EXPECTED_TASK_COUNT     = DM_FAULTS == 3 ? 10 : 7;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int unsigned DM = 1;

bingo_hw_manager_task_desc_full_t dm_task [32];
initial begin
    for (int id = 1; id < 32; id++) begin
        // task id / 10 is the logical cluster (21-24 -> 2, 1-3 -> 0, 11-12 -> 1, 31 -> 3)
        dm_task[id] = pack_normal_task(2'b00, 16'(id), 0, (id / 10) % 4, DM, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[21], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[22], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[1], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[11], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[31], '1, resp);
    wait_retired(0, 2, DM, 5000);
    if (DM_FAULTS >= 2) wait_retired(0, 0, DM, 5000);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[23], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[2], '1, resp);
    if (DM_FAULTS >= 3) begin
        wait_retired(0, 1, DM, 5000);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[24], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[3], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[12], '1, resp);
    end
end

// The substitute rule for a DM task of logical cluster `logical` (one DM core
// per cluster): the logical core itself if it lives, else the lowest-numbered
// other cluster whose DM core lives.
function automatic int dm_substitute(input int logical);
    if (!fenced_export[0][DM][logical]) return logical;
    for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
        if (cl != logical && !fenced_export[0][DM][cl]) return cl;
    end
    return -1;
endfunction

int unsigned dm_moves = 0;
int unsigned dm_remaps = 0;
int unsigned dm_moves_to [4] = '{0, 0, 0, 0};
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.replay_step.fire) begin
            automatic int lcl = gen_dut[0].i_dut.replay_data.assigned_cluster_id;
            automatic int want = dm_substitute(lcl);
            if ((gen_dut[0].i_dut.replay_data.assigned_core_id != DM) ||
                (gen_dut[0].i_dut.replay_step.dst_core != DM) || (gen_dut[0].i_dut.replay_step.dst_cluster != want)) begin
                $error("[4CL_DM] task %0d (logical core %0d cluster %0d) replayed to core %0d cluster %0d, expected cluster %0d",
                       gen_dut[0].i_dut.replay_data.task_id, gen_dut[0].i_dut.replay_data.assigned_core_id, lcl,
                       gen_dut[0].i_dut.replay_step.dst_core, gen_dut[0].i_dut.replay_step.dst_cluster, want);
            end
            $display("[4CL_DM] %0t move task %0d of cluster %0d to cluster %0d", $time,
                     gen_dut[0].i_dut.replay_data.task_id, lcl, gen_dut[0].i_dut.replay_step.dst_cluster);
            dm_moves++;
            dm_moves_to[gen_dut[0].i_dut.replay_step.dst_cluster]++;
        end
        for (int p = 0; p < NUM_CORES_PER_CLUSTER; p++) begin
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                if (gen_dut[0].i_dut.route.fire[p][cl]) begin
                    automatic int src    = gen_dut[0].i_dut.route.src_core[p][cl];
                    automatic int src_cl = gen_dut[0].i_dut.waiting_dep_check_task_desc[src].assigned_cluster_id;
                    automatic int want   = dm_substitute(src_cl);
                    if ((src != DM) || (p != DM) || (cl != want)) begin
                        $error("[4CL_DM] task %0d of logical core %0d cluster %0d placed on core %0d cluster %0d, expected cluster %0d",
                               gen_dut[0].i_dut.waiting_dep_check_task_desc[src].task_id, src, src_cl, p, cl, want);
                    end
                    if (cl != src_cl) dm_remaps++;
                end
            end
        end
    end
end

// With the event log on: its items for the dead DM cores and the moves to the
// cluster-3 DM core (flat index 3 * 3 + 1 = 10) when three have died.
int unsigned dm_evlog_fence [4] = '{0, 0, 0, 0};
int unsigned dm_evlog_moves_to_10 = 0;
int unsigned dm_evlog_items = 0;
if (`TB_EVLOG_DEPTH != 0) begin : gen_dm_evlog_items
    always @(posedge clk_i) begin
        if (rst_ni && gen_dut[0].i_dut.gen_evlog.i_evlog.write_fire) begin
            automatic logic [63:0] item = gen_dut[0].i_dut.gen_evlog.i_evlog.write_data;
            dm_evlog_items++;
            if (item[31:24] == 8'd3 && item[19:16] == 4'(DM)) dm_evlog_fence[item[23:20]]++;
            if (item[31:24] == 8'd4 && item[15:12] == 4'd10) dm_evlog_moves_to_10++;
        end
    end
end

final begin
    automatic int fenced_n = 0;
    for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
        for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
            automatic bit want = (c == DM) && ((cl == 2) || (cl == 0 && DM_FAULTS >= 2) || (cl == 1 && DM_FAULTS >= 3));
            if (fenced_export[0][c][cl] !== want) begin
                $error("[4CL_DM] fenced[%0d][%0d] = %0b, expected %0b", c, cl, fenced_export[0][c][cl], want);
            end
            fenced_n += fenced_export[0][c][cl];
        end
    end
    // 21, 22 to cl0; then 22 (again) to cl1; then 23 to cl3
    if (dm_moves_to[0] < 2 || (DM_FAULTS >= 2 && dm_moves_to[1] < 1) || (DM_FAULTS >= 3 && dm_moves_to[3] < 1) ||
        (DM_FAULTS < 2 && dm_moves_to[1] != 0) || (DM_FAULTS < 3 && dm_moves_to[3] != 0) || dm_moves_to[2] != 0) begin
        $error("[4CL_DM] moves to clusters 0..3: %0d %0d %0d %0d", dm_moves_to[0], dm_moves_to[1],
               dm_moves_to[2], dm_moves_to[3]);
    end
    // remapped: 23 (one fault); 23 and 2 (two); and then 24, 3 and 12 (three)
    if (dm_remaps != (DM_FAULTS == 3 ? 5 : DM_FAULTS)) begin
        $error("[4CL_DM] %0d remapped tasks, expected %0d", dm_remaps, DM_FAULTS == 3 ? 5 : DM_FAULTS);
    end
    if (`TB_EVLOG_DEPTH != 0) begin
        if (dm_evlog_fence[2] != 1 || dm_evlog_fence[0] != (DM_FAULTS >= 2) || dm_evlog_fence[1] != (DM_FAULTS >= 3) ||
            dm_evlog_fence[3] != 0 || (DM_FAULTS >= 3 && dm_evlog_moves_to_10 < 1)) begin
            $error("[4CL_DM] event log: fence items per cluster %0d %0d %0d %0d, moves to slot 10: %0d",
                   dm_evlog_fence[0], dm_evlog_fence[1], dm_evlog_fence[2], dm_evlog_fence[3], dm_evlog_moves_to_10);
        end
    end
    $display("[4CL_DM] summary: faults %0d, fenced %0d, moves %0d (to clusters %0d %0d %0d %0d), remaps %0d, evlog items %0d",
             DM_FAULTS, fenced_n, dm_moves, dm_moves_to[0], dm_moves_to[1], dm_moves_to[2], dm_moves_to[3],
             dm_remaps, dm_evlog_items);
end
