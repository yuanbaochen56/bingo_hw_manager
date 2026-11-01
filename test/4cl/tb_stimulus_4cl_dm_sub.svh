// =============================================================================
// Four clusters: the substitute choice of the host (sub_cfg_i)
// =============================================================================
// The layout of tb_stimulus_4cl_dm_chain.svh (4 clusters x 3 cores, core 1 the
// DM core of type 2, levels 1 and 2), with cluster 3 left empty as a spare:
// no task is assigned to it.
//   TB_4CL_SUB_CASE 1  spare = cluster 3 (TB_SUB_SPARE). Task 21 hangs on the
//      cl2 DM core: 21 and 22 go to the spare, cl3, not to cl0. Task 22 hangs
//      there too (second fault on flat core 10): cl2's tasks go on to cl0, the
//      lowest live cluster, as without a spare (the spare is dead).
//   TB_4CL_SUB_CASE 2  spare = cluster 3; task 21 hangs on cl2 -> cl3. Then
//      the host makes cluster 1 the spare: the table keeps cl3 for the fenced
//      cl2 (task 23 goes there); a live slot's entry is unread until the slot
//      is fenced or parked, and written then. Task 2 hangs on the cl0 DM core
//      (third fault, flat core 1): it goes to the new spare cl1, as does task 3.
//   TB_4CL_SUB_CASE 3  partitions {0, 1} and {2, 3} (TB_SUB_PART 32'h2211), no
//      spare. Task 21 hangs on cl2: 21 and 22 go to cl3, the other cluster of
//      its partition, not to cl0. Task 22 hangs there too: no live DM core is
//      left in the partition, so the slot is stuck; the other partition is not
//      touched: tasks 2 (cl0) and 12 (cl1) run where they belong, task 23 of
//      cl2 is held, and no DM task of cl2 or cl3 reaches cl0 or cl1.
//   TB_4CL_SUB_CASE 4  the same partitions with cluster 3 a spare. Task 11
//      hangs on the cl1 DM core: the spare is in the other partition, so 11
//      and 12 go to cl0, and so does 13, pushed after the retirement.
//   TB_4CL_SUB_CASE 5  spare = cluster 3, no fault: the host parks the cl1 DM
//      core (park_req bit 4) after task 11; it parks on the spare, and task 12,
//      pushed after that, runs there.
//   TB_4CL_SUB_CASE 6  as case 5 in the two partitions: it parks on cl0.
// Every replay move and every remap must go where a model of the table says:
// a fenced logical cluster gets a substitute when it is fenced, or when its
// substitute is fenced, by the rule at that moment (live spare clusters first,
// then the other live clusters in index order, both only in a partition the
// logical cluster shares), and a parked one when it is parked (itself
// excluded); later changes of the spare keep it. The summary at the end checks
// where the tasks went.

`ifndef TB_4CL_SUB_CASE
  `define TB_4CL_SUB_CASE 1
`endif
localparam int unsigned SUB_CASE                = `TB_4CL_SUB_CASE;
// Case 3 ends with a stuck slot: the stimulus checks it and finishes itself
localparam int unsigned EXPECTED_TASK_COUNT     = SUB_CASE == 1 ? 6 : SUB_CASE == 2 ? 7 : SUB_CASE == 3 ? 999 :
                                                  SUB_CASE == 4 ? 5 : 4;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int unsigned DM = 1;

bingo_hw_manager_task_desc_full_t dm_task [32];
initial begin
    for (int id = 1; id < 32; id++) begin
        // task id / 10 is the logical cluster (21-24 -> 2, 1-3 -> 0, 11-13 -> 1)
        dm_task[id] = pack_normal_task(2'b00, 16'(id), 0, (id / 10) % 4, DM, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    if (SUB_CASE == 4) begin
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[21], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[1], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[11], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[12], '1, resp);
        wait_retired(0, 1, DM, 5000);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[13], '1, resp);
        disable chip0_push;
    end
    if (SUB_CASE == 5 || SUB_CASE == 6) begin
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[21], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[1], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[11], '1, resp);
        wait (task_completed_bitmap[11] === 1'b1);
        park_req[0] = 32'd1 << (1 + 3 * 1);   // the DM core of cluster 1
        fork : wait_parked
            wait (gen_dut[0].i_dut.park.parked[DM][1] === 1'b1);
            begin
                repeat (2000) @(posedge clk_i);
                $fatal(1, "[4CL_SUB] the cl1 DM core did not park");
            end
        join_any
        disable wait_parked;
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[12], '1, resp);
        disable chip0_push;
    end
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[21], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[22], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[1], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dm_task[11], '1, resp);
    if (SUB_CASE == 3) begin
        // cl2 fenced, its tasks on cl3; then cl3 fenced, nothing left in the partition
        fork : wait_stuck
            wait (gen_dut[0].i_dut.replay_stuck === 1'b1 && fenced_export[0][DM][3] === 1'b1);
            begin
                repeat (8000) @(posedge clk_i);
                $fatal(1, "[4CL_SUB] no stuck slot after the two faults in partition {2, 3}");
            end
        join_any
        disable wait_stuck;
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[2], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[12], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[23], '1, resp);
        fork : wait_other_partition
            wait (task_completed_bitmap[1] && task_completed_bitmap[11] && task_completed_bitmap[2] &&
                  task_completed_bitmap[12]);
            begin
                repeat (4000) @(posedge clk_i);
                $fatal(1, "[4CL_SUB] the tasks of partition {0, 1} did not finish");
            end
        join_any
        disable wait_other_partition;
        repeat (2000) @(posedge clk_i);
        if (!task_completed_bitmap[21] || task_completed_bitmap[22] || task_completed_bitmap[23])
            $fatal(1, "[4CL_SUB] done: task 21 %0b, 22 %0b, 23 %0b", task_completed_bitmap[21],
                   task_completed_bitmap[22], task_completed_bitmap[23]);
        $display("[4CL_SUB] partition {2, 3} stuck, partition {0, 1} untouched");
        $finish;
    end
    wait_retired(0, 2, DM, 5000);
    if (SUB_CASE == 1) begin
        wait_retired(0, 3, DM, 5000);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[23], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[2], '1, resp);
    end else begin
        sub_cfg[0].spare = 32'h2;
        $display("[4CL_SUB] %0t the host makes cluster 1 the spare", $time);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[23], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[2], '1, resp);
        wait_retired(0, 0, DM, 5000);
        task_queue_master[0].write(task_queue_base[0], '0, dm_task[3], '1, resp);
    end
end

// Model of the table for the DM cores (one per cluster): exp_sub[l] is the
// cluster whose DM core runs the tasks of a fenced logical cluster l
function automatic int dm_rule(input int logical, input logic [3:0] fenced, input logic [3:0] spare,
                               input logic [31:0] part);
    for (int pass = 0; pass < 2; pass++) begin
        for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
            if (cl != logical && !fenced[cl] && (pass == 1 || spare[cl]) &&
                ((part[4 * logical +: 4] & part[4 * cl +: 4]) != '0)) return cl;
        end
    end
    return -1;
endfunction

logic [3:0] dm_fenced_q = '0, dm_parked_q = '0;
int         exp_sub [4] = '{-1, -1, -1, -1};
always @(posedge clk_i) begin
    if (rst_ni) begin
        automatic logic [3:0] now, fresh, parked, parked_fresh;
        for (int cl = 0; cl < 4; cl++) begin
            now[cl]    = fenced_export[0][DM][cl];
            parked[cl] = gen_dut[0].i_dut.park.parked[DM][cl];
        end
        fresh        = now & ~dm_fenced_q;
        parked_fresh = parked & ~dm_parked_q;
        if (fresh != '0) begin
            for (int l = 0; l < 4; l++) begin
                if (fresh[l] || (now[l] && exp_sub[l] >= 0 && fresh[exp_sub[l]])) begin
                    exp_sub[l] = dm_rule(l, now, sub_cfg[0].spare[3:0], sub_cfg[0].partition);
                    $display("[4CL_SUB] %0t cluster %0d fenced: its DM tasks go to cluster %0d", $time, l, exp_sub[l]);
                end
            end
        end
        for (int l = 0; l < 4; l++) begin
            if (parked_fresh[l]) begin
                exp_sub[l] = dm_rule(l, now | (4'b1 << l), sub_cfg[0].spare[3:0], sub_cfg[0].partition);
                $display("[4CL_SUB] %0t cluster %0d parked: its DM tasks go to cluster %0d", $time, l, exp_sub[l]);
            end
        end
        dm_fenced_q <= now;
        dm_parked_q <= parked;
    end
end

function automatic int dm_where(input int logical);
    return (fenced_export[0][DM][logical] || dm_parked_q[logical]) ? exp_sub[logical] : logical;
endfunction

int unsigned dm_moves_to [4] = '{0, 0, 0, 0};
int unsigned dm_remaps_to [4] = '{0, 0, 0, 0};
int          task_cluster [32];
initial for (int i = 0; i < 32; i++) task_cluster[i] = -1;
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.replay_step.fire) begin
            automatic int lcl  = gen_dut[0].i_dut.replay_data.assigned_cluster_id;
            automatic int want = dm_where(lcl);
            if ((gen_dut[0].i_dut.replay_data.assigned_core_id != DM) ||
                (gen_dut[0].i_dut.replay_step.dst_core != DM) || (gen_dut[0].i_dut.replay_step.dst_cluster != want)) begin
                $error("[4CL_SUB] task %0d (logical core %0d cluster %0d) replayed to core %0d cluster %0d, expected cluster %0d",
                       gen_dut[0].i_dut.replay_data.task_id, gen_dut[0].i_dut.replay_data.assigned_core_id, lcl,
                       gen_dut[0].i_dut.replay_step.dst_core, gen_dut[0].i_dut.replay_step.dst_cluster, want);
            end
            $display("[4CL_SUB] %0t move task %0d of cluster %0d to cluster %0d", $time,
                     gen_dut[0].i_dut.replay_data.task_id, lcl, gen_dut[0].i_dut.replay_step.dst_cluster);
            dm_moves_to[gen_dut[0].i_dut.replay_step.dst_cluster]++;
            task_cluster[gen_dut[0].i_dut.replay_data.task_id] = gen_dut[0].i_dut.replay_step.dst_cluster;
        end
        for (int p = 0; p < NUM_CORES_PER_CLUSTER; p++) begin
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                if (gen_dut[0].i_dut.route.fire[p][cl]) begin
                    automatic int src    = gen_dut[0].i_dut.route.src_core[p][cl];
                    automatic int src_cl = gen_dut[0].i_dut.waiting_dep_check_task_desc[src].assigned_cluster_id;
                    automatic int id     = gen_dut[0].i_dut.waiting_dep_check_task_desc[src].task_id;
                    automatic int want   = dm_where(src_cl);
                    if ((src != DM) || (p != DM) || (cl != want)) begin
                        $error("[4CL_SUB] task %0d of logical core %0d cluster %0d placed on core %0d cluster %0d, expected cluster %0d",
                               id, src, src_cl, p, cl, want);
                    end
                    if (cl != src_cl) begin
                        dm_remaps_to[cl]++;
                        $display("[4CL_SUB] %0t remap task %0d of cluster %0d to cluster %0d", $time, id, src_cl, cl);
                    end
                    task_cluster[id] = cl;
                end
            end
        end
    end
end

final begin
    // Where each task ran last (placed or moved), per case
    automatic int want [32];
    automatic bit ok = 1'b1;
    for (int i = 0; i < 32; i++) want[i] = -1;
    if (SUB_CASE == 1) begin
        want[21] = 3; want[22] = 0; want[1] = 0; want[11] = 1; want[23] = 0; want[2] = 0;
    end else if (SUB_CASE == 2) begin
        want[21] = 3; want[22] = 3; want[1] = 0; want[11] = 1; want[23] = 3; want[2] = 1; want[3] = 1;
    end else if (SUB_CASE == 3) begin
        want[21] = 3; want[22] = 3; want[1] = 0; want[11] = 1; want[2] = 0; want[12] = 1;
    end else if (SUB_CASE == 4) begin
        want[21] = 2; want[1] = 0; want[11] = 0; want[12] = 0; want[13] = 0;
    end else begin
        want[21] = 2; want[1] = 0; want[11] = 1; want[12] = SUB_CASE == 5 ? 3 : 0;
    end
    for (int i = 0; i < 32; i++) begin
        if (want[i] != task_cluster[i]) begin
            $error("[4CL_SUB] task %0d ran on cluster %0d, expected %0d", i, task_cluster[i], want[i]);
            ok = 1'b0;
        end
    end
    // Nothing of another cluster went to cluster 2 (dead first) or, in case 2,
    // to cluster 0 after it died
    if (SUB_CASE <= 3 && (dm_moves_to[2] != 0 || dm_remaps_to[2] != 0))
        $error("[4CL_SUB] tasks moved or remapped to the dead cluster 2: %0d / %0d", dm_moves_to[2], dm_remaps_to[2]);
    // Nothing across partitions (cases 3, 4, 6)
    if (SUB_CASE == 3 && (dm_moves_to[0] + dm_moves_to[1] + dm_remaps_to[0] + dm_remaps_to[1] != 0))
        $error("[4CL_SUB] tasks of partition {2, 3} reached partition {0, 1}");
    if ((SUB_CASE == 4 || SUB_CASE == 6) && (dm_moves_to[2] + dm_moves_to[3] + dm_remaps_to[2] + dm_remaps_to[3] != 0))
        $error("[4CL_SUB] tasks of partition {0, 1} reached partition {2, 3}");
    $display("[4CL_SUB] summary: case %0d, moves to clusters %0d %0d %0d %0d, remaps to %0d %0d %0d %0d, %s",
             SUB_CASE, dm_moves_to[0], dm_moves_to[1], dm_moves_to[2], dm_moves_to[3],
             dm_remaps_to[0], dm_remaps_to[1], dm_remaps_to[2], dm_remaps_to[3], ok ? "as expected" : "WRONG");
end
