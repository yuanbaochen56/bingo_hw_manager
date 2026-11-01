// =============================================================================
// Fence fallback: a fenced slot of a type in TB_FENCE_FB takes no substitute
// =============================================================================
// Cluster 0: core 0 type 1, cores 1-2 type 2; cluster 1: core 0 type 2,
// core 1 type 1, core 2 type 3. The victim V is core TB_FAULT_CORE of
// cluster 0 (type FB_VICTIM_TYPE); S = (FB_SUB_CORE, cluster 1) is the live
// level-2 slot of its type. The host writes the fence-fallback register, the
// CERF mask (group 0 active) and the degradation entry of the victim's type
// (clear group 0, set group 1) before the first task, as libbingo does.
//   task 1 (V, group 0)      primary, hangs; releases task 2
//   task 2 (cl1 c2, group 1) backup, after task 1; releases task 4
//   task 4 (cl0 c2)          consumer, after task 2
// once the fence is handled:
//   task 5 (V, group 0, exit)  exit of the victim
//   task 7 (S)                 own task of S
//   task 6 (S, group 0, exit)  exit of the possible substitute
// FB_EXPECT_STUCK 1 (the victim's type is in TB_FENCE_FB): the fence finds no
//   substitute at any level, V is stuck and the CERF switches once. Task 1
//   retires as skipped and never runs again, task 2 runs, then task 4. Tasks 5
//   and 6 are in the cleared group: neither is dispatched or absorbed. Task 7
//   runs on S. Nothing is replayed or remapped.
// FB_EXPECT_STUCK 0: task 1 is replayed once on S, nothing is stuck, the CERF
//   keeps its value, task 2 is skipped, task 4 runs. Task 5 is routed to S and
//   absorbed, tasks 7 and 6 run on S.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

localparam int unsigned FB_VICTIM_CORE = `TB_FAULT_CORE;
localparam int unsigned FB_TYPE        = `FB_VICTIM_TYPE;
localparam int unsigned FB_SUB_CORE    = `FB_SUB_CORE;

bingo_hw_manager_task_desc_full_t fb_task [8];
initial begin
    //                         type    id  chip cl core            chk_en chk_code set_en all chip set_cl set_code
    fb_task[1] = pack_normal_task(2'b00, 1, 0, 0, FB_VICTIM_CORE, 1'b0, '0, 1'b1, 1'b0, 0, 1,
                                  bingo_hw_manager_dep_code_t'(3'b100));
    fb_task[2] = pack_normal_task(2'b00, 2, 0, 1, 2, 1'b1, bingo_hw_manager_dep_code_t'(1 << FB_VICTIM_CORE),
                                  1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    fb_task[4] = pack_normal_task(2'b00, 4, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b100),
                                  1'b0, 1'b0, 0, 0, '0);
    fb_task[5] = pack_normal_task(2'b00, 5, 0, 0, FB_VICTIM_CORE, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    fb_task[6] = pack_normal_task(2'b00, 6, 0, 1, FB_SUB_CORE, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    fb_task[7] = pack_normal_task(2'b00, 7, 0, 1, FB_SUB_CORE, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    for (int i = 1; i <= 6; i++) begin
        if (i == 1 || i == 2 || i == 5 || i == 6) begin
            fb_task[i].cond_exec_en       = 1'b1;
            fb_task[i].cond_exec_group_id = (i == 2) ? 5'd1 : 5'd0;
        end
    end
    fb_task[5].is_exit = 1'b1;
    fb_task[6].is_exit = 1'b1;
end

// Entries pushed into a ready queue per task (first dispatch and replay), and
// absorbed exits
int unsigned fb_ready_pushes [8];
int unsigned fb_exit_absorbs = 0;
initial for (int i = 0; i < 8; i++) fb_ready_pushes[i] = 0;
always @(posedge clk_i) begin
    if (rst_ni) begin
        for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                if (gen_dut[0].i_dut.ready_queue_push[c][cl])
                    fb_ready_pushes[gen_dut[0].i_dut.ready_queue_data_in[c][cl].task_id[2:0]]++;
                if (gen_dut[0].i_dut.exit_absorb[c][cl]) fb_exit_absorbs++;
            end
        end
    end
end

task automatic fb_wait_done(input int id, input int max_cycles);
    fork : wait_done
        wait (task_completed_bitmap[id] === 1'b1);
        begin
            repeat (max_cycles) @(posedge clk_i);
            $fatal(1, "[FENCE_FB] task %0d did not run", id);
        end
    join_any
    disable wait_done;
endtask

task automatic fb_wait_empty(input int core, input int cluster);
    fork : wait_empty
        wait (gen_dut[0].i_dut.checkout_queue_empty[core][cluster] === 1'b1);
        begin
            repeat (200) @(posedge clk_i);
            $fatal(1, "[FENCE_FB] core %0d cluster %0d still holds task %0d", core, cluster,
                   gen_dut[0].i_dut.checkout_queue_data_out[core][cluster].task_id);
        end
    join_any
    disable wait_empty;
endtask

initial begin : fence_fb_test
    automatic axi_pkg::resp_t resp;

    // Reset value of the host register
    fence_fb[0] = '0;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    if (gen_dut[0].i_dut.CoreTypeId[FB_VICTIM_CORE][0] !== FB_TYPE ||
        gen_dut[0].i_dut.CoreTypeId[FB_SUB_CORE][1] !== FB_TYPE)
        $fatal(1, "[FENCE_FB] victim type %0d, slot S type %0d, expected %0d",
               gen_dut[0].i_dut.CoreTypeId[FB_VICTIM_CORE][0],
               gen_dut[0].i_dut.CoreTypeId[FB_SUB_CORE][1], FB_TYPE);

    @(negedge clk_i);
    fence_fb[0]               = 16'(`TB_FENCE_FB);
    cerf_fb_clear[0][FB_TYPE] = 5'd0;
    cerf_fb_set[0][FB_TYPE]   = 5'd1;
    cerf_fb_en[0][FB_TYPE]    = 1'b1;
    cerf_write_bitmask(0, 32'h1);
    // Live slots keep themselves in the table, with or without the bit
    if (!gen_dut[0].i_dut.smt.found[FB_VICTIM_CORE][0] ||
        gen_dut[0].i_dut.smt.core[FB_VICTIM_CORE][0] != FB_VICTIM_CORE ||
        gen_dut[0].i_dut.smt.cluster[FB_VICTIM_CORE][0] != 0)
        $fatal(1, "[FENCE_FB] live victim entry changed");
    // The AXI-Lite master expects to start on a clock edge
    @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, fb_task[1], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, fb_task[2], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, fb_task[4], '1, resp);

    fork : wait_fence
        wait (gen_dut[0].i_dut.core_fenced[FB_VICTIM_CORE][0] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "[FENCE_FB] victim was not fenced");
        end
    join_any
    disable wait_fence;
    if (task_completed_bitmap[2] || task_completed_bitmap[4] || fb_ready_pushes[2] != 0)
        $fatal(1, "[FENCE_FB] the backup or the consumer ran before the fence");

    if (`FB_EXPECT_STUCK) begin
        fork : wait_stuck
            wait (gen_dut[0].i_dut.replay_stuck_slot[FB_VICTIM_CORE][0] === 1'b1);
            begin
                repeat (50) @(posedge clk_i);
                $fatal(1, "[FENCE_FB] victim with a fallback type did not become stuck");
            end
        join_any
        disable wait_stuck;
        fork : wait_switch
            wait (gen_dut[0].i_dut.cerf_state === 32'h2 && cerf_fb_evt[0][FB_TYPE]);
            begin
                repeat (50) @(posedge clk_i);
                $fatal(1, "[FENCE_FB] CERF did not switch: %h evt %h",
                       gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0]);
            end
        join_any
        disable wait_switch;
        if (gen_dut[0].i_dut.smt.found[FB_VICTIM_CORE][0])
            $fatal(1, "[FENCE_FB] table kept a substitute for the fenced victim");
        fb_wait_done(2, 2000);
        fb_wait_done(4, 2000);
        fb_wait_empty(FB_VICTIM_CORE, 0);
        @(posedge clk_i);
        task_queue_master[0].write(task_queue_base[0], '0, fb_task[5], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, fb_task[7], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, fb_task[6], '1, resp);
        fb_wait_done(7, 2000);
        repeat (50) @(posedge clk_i);
        fb_wait_empty(FB_VICTIM_CORE, 0);
        fb_wait_empty(FB_SUB_CORE, 1);
        if (task_completed_bitmap[1] || fb_ready_pushes[1] != 1)
            $fatal(1, "[FENCE_FB] task 1 done %0b, ready pushes %0d",
                   task_completed_bitmap[1], fb_ready_pushes[1]);
        if (fb_ready_pushes[5] != 0 || fb_ready_pushes[6] != 0 || fb_exit_absorbs != 0 ||
            task_completed_bitmap[5] || task_completed_bitmap[6])
            $fatal(1, "[FENCE_FB] exits in the cleared group: ready pushes %0d / %0d, absorbed %0d",
                   fb_ready_pushes[5], fb_ready_pushes[6], fb_exit_absorbs);
        if (replay_move_count[0] != 0 || remap_count[0] != 0 ||
            gen_dut[0].i_dut.core_retired[FB_VICTIM_CORE][0])
            $fatal(1, "[FENCE_FB] work moved: replay %0d remap %0d retired %0b",
                   replay_move_count[0], remap_count[0],
                   gen_dut[0].i_dut.core_retired[FB_VICTIM_CORE][0]);
        if (gen_dut[0].i_dut.cerf_state !== 32'h2)
            $fatal(1, "[FENCE_FB] CERF changed again: %h", gen_dut[0].i_dut.cerf_state);
        $display("Fence fallback stuck case passed");
    end else begin
        fork : wait_replayed
            wait (task_completed_bitmap[1] === 1'b1 &&
                  gen_dut[0].i_dut.core_retired[FB_VICTIM_CORE][0] === 1'b1);
            begin
                repeat (5000) @(posedge clk_i);
                $fatal(1, "[FENCE_FB] task 1 was not replayed (retired %0b, moves %0d)",
                       gen_dut[0].i_dut.core_retired[FB_VICTIM_CORE][0], replay_move_count[0]);
            end
        join_any
        disable wait_replayed;
        if (!gen_dut[0].i_dut.smt.found[FB_VICTIM_CORE][0] ||
            gen_dut[0].i_dut.smt.core[FB_VICTIM_CORE][0] != FB_SUB_CORE ||
            gen_dut[0].i_dut.smt.cluster[FB_VICTIM_CORE][0] != 1)
            $fatal(1, "[FENCE_FB] substitute is core %0d cluster %0d",
                   gen_dut[0].i_dut.smt.core[FB_VICTIM_CORE][0],
                   gen_dut[0].i_dut.smt.cluster[FB_VICTIM_CORE][0]);
        fb_wait_done(4, 2000);
        @(posedge clk_i);
        task_queue_master[0].write(task_queue_base[0], '0, fb_task[5], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, fb_task[7], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, fb_task[6], '1, resp);
        fb_wait_done(7, 2000);
        fb_wait_done(6, 2000);
        repeat (50) @(posedge clk_i);
        fb_wait_empty(FB_SUB_CORE, 1);
        if (gen_dut[0].i_dut.replay_stuck || replay_move_count[0] != 1 || fb_ready_pushes[1] != 2)
            $fatal(1, "[FENCE_FB] replay case: stuck %0b moves %0d ready pushes %0d",
                   gen_dut[0].i_dut.replay_stuck, replay_move_count[0], fb_ready_pushes[1]);
        if (gen_dut[0].i_dut.cerf_state !== 32'h1 || cerf_fb_evt[0] !== '0)
            $fatal(1, "[FENCE_FB] replay case changed CERF %h evt %h",
                   gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0]);
        if (task_completed_bitmap[2] || fb_ready_pushes[2] != 0)
            $fatal(1, "[FENCE_FB] the backup ran without a degradation");
        if (fb_exit_absorbs != 1 || fb_ready_pushes[5] != 0 || task_completed_bitmap[5] ||
            fb_ready_pushes[6] != 1)
            $fatal(1, "[FENCE_FB] exits: absorbed %0d, ready pushes %0d / %0d",
                   fb_exit_absorbs, fb_ready_pushes[5], fb_ready_pushes[6]);
        $display("Fence fallback replay case passed: substitute core %0d cluster %0d",
                 gen_dut[0].i_dut.smt.core[FB_VICTIM_CORE][0],
                 gen_dut[0].i_dut.smt.cluster[FB_VICTIM_CORE][0]);
    end
    $finish;
end
