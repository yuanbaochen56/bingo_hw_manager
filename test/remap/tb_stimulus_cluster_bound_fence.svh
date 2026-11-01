localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t bound_task;
initial begin
    bound_task = pack_normal_task(2'b00, 1, 0, 0, 0,
        1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
end

initial begin : cluster_bound_fence_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    cerf_fb_clear[0][1] = 0;
    cerf_fb_set[0][1] = 1;
    cerf_write_bitmask(0, 32'h1);
    task_queue_master[0].write(task_queue_base[0], '0, bound_task, '1, resp);
    fork : wait_bound_stuck
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][0] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "B2: cluster-bound victim did not become stuck");
        end
    join_any
    disable wait_bound_stuck;
    repeat (20) @(posedge clk_i);
    if (!gen_dut[0].i_dut.replay_stuck || replay_move_count[0] != 0 || remap_count[0] != 0)
        $fatal(1, "B2: cluster-bound victim moved instead of becoming stuck");
    if (gen_dut[0].i_dut.cerf_state != 1 || cerf_fb_evt[0] != 0)
        $fatal(1, "B2: disabled degradation changed CERF");
    @(negedge clk_i);
    cerf_fb_en[0][1] = 1;
    fork : wait_bound_fallback
        wait (gen_dut[0].i_dut.cerf_state === 32'h2 && cerf_fb_evt[0][1]);
        begin
            repeat (50) @(posedge clk_i);
            $fatal(1, "B2: enabled cluster-bound degradation did not fire");
        end
    join_any
    disable wait_bound_fallback;
    if (replay_move_count[0] != 0 || remap_count[0] != 0)
        $fatal(1, "B2: cluster-bound victim moved after degradation");
    $display("Cluster-bound fence B2 passed");
    $finish;
end
