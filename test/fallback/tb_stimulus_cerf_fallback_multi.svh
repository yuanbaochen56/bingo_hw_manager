// =============================================================================
// CERF degradation: two types fire in the same cycle; clear == set
// =============================================================================
// Core 0 (only type 4) hangs on task 1, core 1 (only type 5) on task 2; both
// stick. Type 4 clears group 0 and sets group 1, type 5 clears group 1 and
// sets group 2. Both enables rise in one cycle: one update per cycle, lowest
// type first, so CERF goes 0x1 -> 0x2 -> 0x4 (type 5 first would end at 0x6).
// Then type 4 is re-armed with clear == set == group 3: that group ends set.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t cfm_t1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t cfm_t2 = pack_normal_task(
    2'b00, 16'd2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

task automatic cfm_expect(input logic [31:0] cerf, input logic [15:0] evt, input string what);
    if (gen_dut[0].i_dut.cerf_state !== cerf || cerf_fb_evt[0] !== evt) begin
        $fatal(1, "[CERF_FBM] %s: CERF %h evt %h, expected %h %h",
               what, gen_dut[0].i_dut.cerf_state, cerf_fb_evt[0], cerf, evt);
    end
endtask

initial begin : cerf_fallback_multi_test
    automatic axi_pkg::resp_t resp;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    cerf_fb_en[0] = '0;
    cerf_fb_clear[0] = '0;
    cerf_fb_set[0] = '0;
    cerf_fb_clear[0][4] = 5'd0;
    cerf_fb_set[0][4]   = 5'd1;
    cerf_fb_clear[0][5] = 5'd1;
    cerf_fb_set[0][5]   = 5'd2;
    cerf_write_bitmask(0, 32'h1);

    task_queue_master[0].write(task_queue_base[0], '0, cfm_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, cfm_t2, '1, resp);
    fork : wait_stuck
        wait (gen_dut[0].i_dut.replay_stuck_slot[0][0] === 1'b1 &&
              gen_dut[0].i_dut.replay_stuck_slot[1][0] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "[CERF_FBM] cores 0/1 not both stuck (%b)", gen_dut[0].i_dut.replay_stuck_slot);
        end
    join_any
    disable wait_stuck;
    repeat (5) @(posedge clk_i);
    #1;
    cfm_expect(32'h1, 16'h0000, "disabled table");

    @(negedge clk_i);
    cerf_fb_en[0][4] <= 1'b1;
    cerf_fb_en[0][5] <= 1'b1;
    @(posedge clk_i);
    #1;
    cfm_expect(32'h2, 16'h0010, "first cycle (type 4)");
    @(posedge clk_i);
    #1;
    cfm_expect(32'h4, 16'h0030, "second cycle (type 5)");
    repeat (5) @(posedge clk_i);
    #1;
    cfm_expect(32'h4, 16'h0030, "after both fired");

    // Re-arm type 4 with clear == set
    @(negedge clk_i);
    cerf_fb_en[0][4]    <= 1'b0;
    @(negedge clk_i);
    #1;
    cfm_expect(32'h4, 16'h0020, "type 4 disabled");
    cerf_fb_clear[0][4] <= 5'd3;
    cerf_fb_set[0][4]   <= 5'd3;
    cerf_fb_en[0][4]    <= 1'b1;
    @(posedge clk_i);
    #1;
    cfm_expect(32'hC, 16'h0030, "clear == set");
    repeat (5) @(posedge clk_i);
    #1;
    cfm_expect(32'hC, 16'h0030, "no second write");

    $display("CERF fallback multi test passed");
    $finish;
end
