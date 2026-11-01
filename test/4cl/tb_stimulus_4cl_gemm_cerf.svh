// =============================================================================
// Four clusters: a GEMM core hangs, no substitute, CERF degradation
// =============================================================================
// Layout of tb_stimulus_4cl_dm_chain.svh: core 0 type 1 (GEMM, bound to its
// cluster: SubstituteL2TypeEn bit 1 clear), core 1 type 2 (DM), core 2 type 0.
// The GEMM core of cluster 1 hangs on task 11. Its cluster has no other type-1
// core and type 1 may not leave the cluster, so the slot is stuck: nothing is
// replayed or remapped. The degradation table of type 1 clears CERF group 0 and
// sets group 1: task 12 (group 0, GEMM core of cluster 2) is skipped, task 13
// (group 1, GEMM core of cluster 3) runs. The other clusters keep working: the
// DM tasks 1, 21, 31 and the GEMM task 2 of cluster 0 complete.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam logic [4:0] GEMM_TYPE = 5'd1;

bingo_hw_manager_task_desc_full_t gc_task [32];
initial begin
    gc_task[11] = pack_normal_task(2'b00, 16'd11, 0, 1, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    gc_task[2]  = pack_normal_task(2'b00, 16'd2,  0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    gc_task[1]  = pack_normal_task(2'b00, 16'd1,  0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    gc_task[21] = pack_normal_task(2'b00, 16'd21, 0, 2, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    gc_task[31] = pack_normal_task(2'b00, 16'd31, 0, 3, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    gc_task[12] = pack_normal_task(2'b00, 16'd12, 0, 2, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    gc_task[12].cond_exec_en = 1'b1;
    gc_task[12].cond_exec_group_id = 5'd0;
    gc_task[13] = pack_normal_task(2'b00, 16'd13, 0, 3, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    gc_task[13].cond_exec_en = 1'b1;
    gc_task[13].cond_exec_group_id = 5'd1;
end

// task 12 reaching any ready queue ($sampled, see tb_stimulus_cerf_fallback.svh)
logic gc_task12_push;
always_comb begin
    gc_task12_push = 1'b0;
    for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++)
        for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
            if (gen_dut[0].i_dut.ready_queue_push[c][cl] && gen_dut[0].i_dut.ready_queue_data_in[c][cl].task_id == 12)
                gc_task12_push = 1'b1;
end
bit gc_task12_ready;
always @(posedge clk_i) begin
    if (rst_ni && $sampled(gc_task12_push)) gc_task12_ready <= 1'b1;
end

initial begin : gemm_cerf_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int cl = 0; cl < 4; cl++) begin
        if (gen_dut[0].i_dut.CoreTypeId[0][cl] !== 1 || gen_dut[0].i_dut.CoreTypeId[1][cl] !== 2 ||
            gen_dut[0].i_dut.CoreTypeId[2][cl] !== 0) begin
            $fatal(1, "[4CL_GEMM_CERF] core types of cluster %0d differ from the four-cluster layout", cl);
        end
    end
    cerf_fb_en[0] = '0;
    cerf_fb_clear[0] = '0;
    cerf_fb_set[0] = '0;
    cerf_fb_clear[0][GEMM_TYPE] = 5'd0;
    cerf_fb_set[0][GEMM_TYPE] = 5'd1;
    cerf_fb_en[0][GEMM_TYPE] = 1'b1;
    cerf_write_bitmask(0, 32'h1);   // group 0 active, group 1 (the backup) not

    task_queue_master[0].write(task_queue_base[0], '0, gc_task[11], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, gc_task[1], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, gc_task[21], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, gc_task[31], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, gc_task[2], '1, resp);
    fork : wait_stuck
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][1] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "[4CL_GEMM_CERF] the GEMM core of cluster 1 never became stuck (fenced %0b)",
                   gen_dut[0].i_dut.core_fenced[0][1]);
        end
    join_any
    disable wait_stuck;
    fork : wait_fallback
        wait (gen_dut[0].i_dut.cerf_state === 32'h2);
        begin
            repeat (200) @(posedge clk_i);
            $fatal(1, "[4CL_GEMM_CERF] CERF %h after the stuck GEMM core, expected 2",
                   gen_dut[0].i_dut.cerf_state);
        end
    join_any
    disable wait_fallback;
    task_queue_master[0].write(task_queue_base[0], '0, gc_task[12], '1, resp);
    repeat (5) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, gc_task[13], '1, resp);
    fork : wait_done
        wait (task_completed_bitmap[13] && task_completed_bitmap[1] && task_completed_bitmap[2] &&
              task_completed_bitmap[21] && task_completed_bitmap[31]);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "[4CL_GEMM_CERF] not done: 1 %0b 2 %0b 21 %0b 31 %0b 13 %0b", task_completed_bitmap[1],
                   task_completed_bitmap[2], task_completed_bitmap[21], task_completed_bitmap[31],
                   task_completed_bitmap[13]);
        end
    join_any
    disable wait_done;
    repeat (50) @(posedge clk_i);
    if (task_completed_bitmap[11] || task_completed_bitmap[12] || gc_task12_ready) begin
        $fatal(1, "[4CL_GEMM_CERF] task 11 done %0b, task 12 done %0b, task 12 reached a ready queue %0b",
               task_completed_bitmap[11], task_completed_bitmap[12], gc_task12_ready);
    end
    if (replay_move_count[0] != 0 || remap_count[0] != 0) begin
        $fatal(1, "[4CL_GEMM_CERF] tasks moved: replay %0d remap %0d", replay_move_count[0], remap_count[0]);
    end
    for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++)
        for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
            if (gen_dut[0].i_dut.replay_stuck_slot[c][cl] !== ((c == 0) && (cl == 1)))
                $fatal(1, "[4CL_GEMM_CERF] stuck[%0d][%0d] = %0b", c, cl, gen_dut[0].i_dut.replay_stuck_slot[c][cl]);
    if (cerf_fb_evt[0] !== 16'h0002) $fatal(1, "[4CL_GEMM_CERF] degradation events %h, expected type 1", cerf_fb_evt[0]);
    $display("4CL GEMM CERF test passed");
    $finish;
end
