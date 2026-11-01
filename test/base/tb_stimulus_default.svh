// =============================================================================
// Default Stimulus: 27-task multi-chiplet DFG
// =============================================================================
// This is the original test case from the bingo_hw_manager testbench.
// 4 chiplets, 2 clusters each, 3 cores each.
// Tests intra-chiplet and inter-chiplet dependencies with dummy set/check nodes.
//
// Per-edge identity tags: three dep-matrix cells carry TWO concurrently-live
// edges each, so the second edge on each cell uses tag 1 (as the mini-compiler
// would allocate); all other edges keep tag 0:
//   * chip2 (cl0,r0,c1): 10->25 (tag0), 9->11  (tag1)
//   * chip3 (cl0,r0,c0): 20->26 (tag0), 22->12 (tag1)
//   * chip3 (cl0,r0,c1): 13->27 (tag0), 14->16 (tag1)
// =============================================================================

// 16 normal tasks (IDs 1-16) + 12 dummy tasks (IDs 17-28)
// Only normal tasks go through dispatch/done and are counted
localparam int unsigned EXPECTED_TASK_COUNT    = 16;
localparam int unsigned DEADLOCK_THRESHOLD     = 2000;  // cycles
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 500;  // cycles (0 = disabled)

// ---------------------------------------------------------------------------
// Task Descriptor Declarations
// ---------------------------------------------------------------------------

// === Chiplet 0 tasks ===
bingo_hw_manager_task_desc_full_t chip0_cluster0_core0_gemm = pack_normal_task(
    1'b0, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b1, 1'b0, 0, 1, bingo_hw_manager_dep_code_t'(8'b00000010)
);

bingo_hw_manager_task_desc_full_t chip0_cluster1_core1_dma = pack_normal_task(
    1'b0, 16'd2, 0, 1, 1,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000100)
);

bingo_hw_manager_task_desc_full_t chip0_cluster0_core2_simd = pack_normal_task(
    1'b0, 16'd3, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),
    1'b0, 1'b0, 0, 0, '0
);

// === Chiplet 1 tasks ===
bingo_hw_manager_task_desc_full_t chip1_cluster0_core2_simd = pack_normal_task(
    1'b0, 16'd4, 1, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000100),
    1'b1, 1'b0, 1, 1, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t chip1_cluster0_core1_dma = pack_normal_task(
    1'b0, 16'd5, 1, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000100),
    1'b1, 1'b0, 1, 0, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t chip1_cluster1_core0_gemm = pack_normal_task(
    1'b0, 16'd6, 1, 1, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000100),
    1'b1, 1'b0, 1, 0, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t chip1_cluster0_core0_gemm = pack_normal_task(
    1'b0, 16'd7, 1, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000011),
    1'b0, 1'b0, 0, 0, '0
);

// === Chiplet 2 tasks ===
bingo_hw_manager_task_desc_full_t chip2_cluster0_core0_gemm = pack_normal_task(
    1'b0, 16'd8, 2, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000100),
    1'b1, 1'b0, 2, 1, bingo_hw_manager_dep_code_t'(8'b00000010)
);

bingo_hw_manager_task_desc_full_t chip2_cluster0_core1_dma = pack_normal_task(
    1'b0, 16'd9, 2, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
    1'b1, 1'b0, 2, 0, bingo_hw_manager_dep_code_t'(8'b00000001),
    '0, 4'd1                                                 // set tag1: cell (r0,c1) shared with 10->25
);

bingo_hw_manager_task_desc_full_t chip2_cluster1_core1_dma = pack_normal_task(
    1'b0, 16'd10, 2, 1, 1,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
    1'b1, 1'b0, 2, 0, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t chip2_cluster0_core0_gemm_2 = pack_normal_task(
    1'b0, 16'd11, 2, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),
    1'b0, 1'b0, 0, 0, '0,
    4'd1                                                     // check tag1: drains task 9's set only
);

// === Chiplet 3 tasks ===
bingo_hw_manager_task_desc_full_t chip3_cluster0_core0_gemm_1 = pack_normal_task(
    1'b0, 16'd12, 3, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
    1'b1, 1'b0, 3, 0, bingo_hw_manager_dep_code_t'(8'b00000100),
    4'd1, '0                                                 // check tag1: drains task 22's set only
);

bingo_hw_manager_task_desc_full_t chip3_cluster0_core1_dma = pack_normal_task(
    1'b0, 16'd13, 3, 0, 1,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
    1'b1, 1'b0, 3, 0, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t chip3_cluster1_core1_dma = pack_normal_task(
    1'b0, 16'd14, 3, 1, 1,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
    1'b1, 1'b0, 3, 0, bingo_hw_manager_dep_code_t'(8'b00000001),
    '0, 4'd1                                                 // set tag1: cell (r0,c1) shared with 13->27
);

bingo_hw_manager_task_desc_full_t chip3_cluster0_core2_simd = pack_normal_task(
    1'b0, 16'd15, 3, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
    1'b1, 1'b0, 3, 0, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t chip3_cluster0_core0_gemm_2 = pack_normal_task(
    1'b0, 16'd16, 3, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),
    1'b0, 1'b0, 0, 0, '0,
    4'd1                                                     // check tag1: drains task 14's set only
);

// === Dummy Set Nodes ===
bingo_hw_manager_task_desc_full_t dummy_set_chip0_to_chip1 = pack_dummy_set_task(
    1'b1, 16'd17, 0, 0, 2,
    1'b1, 1'b0, 1, 0, bingo_hw_manager_dep_code_t'(8'b00000100)
);

bingo_hw_manager_task_desc_full_t dummy_set_chip0_to_chip2 = pack_dummy_set_task(
    1'b1, 16'd18, 0, 0, 2,
    1'b1, 1'b0, 2, 0, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t dummy_set_chip1_local_0 = pack_dummy_set_task(
    1'b1, 16'd19, 1, 0, 2,
    1'b1, 1'b0, 1, 0, bingo_hw_manager_dep_code_t'(8'b00000010)
);

bingo_hw_manager_task_desc_full_t dummy_set_chip1_to_chip3 = pack_dummy_set_task(
    1'b1, 16'd20, 1, 0, 0,
    1'b1, 1'b0, 3, 0, bingo_hw_manager_dep_code_t'(8'b00000001)
);

bingo_hw_manager_task_desc_full_t dummy_set_chip2_local_0 = pack_dummy_set_task(
    1'b1, 16'd21, 2, 0, 0,
    1'b1, 1'b0, 2, 0, bingo_hw_manager_dep_code_t'(8'b00000010)
);

bingo_hw_manager_task_desc_full_t dummy_set_chip2_to_chip3 = pack_dummy_set_task(
    1'b1, 16'd22, 2, 0, 0,
    1'b1, 1'b0, 3, 0, bingo_hw_manager_dep_code_t'(8'b00000001),
    4'd1                                                     // set tag1: cell (r0,c0) shared with 20->26
);

bingo_hw_manager_task_desc_full_t dummy_set_chip3_local_0 = pack_dummy_set_task(
    1'b1, 16'd23, 3, 0, 0,
    1'b1, 1'b0, 3, 0, bingo_hw_manager_dep_code_t'(8'b00000010)
);

bingo_hw_manager_task_desc_full_t dummy_set_chip3_local_1 = pack_dummy_set_task(
    1'b1, 16'd24, 3, 0, 0,
    1'b1, 1'b0, 3, 1, bingo_hw_manager_dep_code_t'(8'b00000010)
);

// === Dummy Check Nodes ===
bingo_hw_manager_task_desc_full_t dummy_check_chip2_0 = pack_dummy_check_task(
    1'b1, 16'd25, 2, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010)
);

bingo_hw_manager_task_desc_full_t dummy_check_chip3_0 = pack_dummy_check_task(
    1'b1, 16'd26, 3, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000001)
);

// Split: was single dummy_check with 0b110 (core1+core2 merged).
// Merging different cores into one check causes deadlock via dep_matrix
// overlap + done queue HOL blocking. Each checks one core column only.
bingo_hw_manager_task_desc_full_t dummy_check_chip3_1a = pack_dummy_check_task(
    1'b1, 16'd27, 3, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010)  // core 1 only
);

bingo_hw_manager_task_desc_full_t dummy_check_chip3_1b = pack_dummy_check_task(
    1'b1, 16'd28, 3, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000100)  // core 2 only
);

// ---------------------------------------------------------------------------
// Per-Chiplet Push Sequences
// ---------------------------------------------------------------------------

// Chiplet 0: 5 tasks
initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, chip0_cluster0_core0_gemm, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,1,1,2", $time);
    task_queue_master[0].write(task_queue_base[0], '0, chip0_cluster1_core1_dma, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,2,3", $time);
    task_queue_master[0].write(task_queue_base[0], '0, chip0_cluster0_core2_simd, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,2,17", $time);
    task_queue_master[0].write(task_queue_base[0], '0, dummy_set_chip0_to_chip1, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,2,18", $time);
    task_queue_master[0].write(task_queue_base[0], '0, dummy_set_chip0_to_chip2, '1, resp);
    #50;
end

// Chiplet 1: 6 tasks
initial begin : chip1_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[1].reset();
    done_queue_master[1].reset();

    $display("[TRACE] %0t,TASK_PUSHED,1,0,2,4", $time);
    task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster0_core2_simd, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,1,1,0,6", $time);
    task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster1_core0_gemm, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,1,0,2,19", $time);
    task_queue_master[1].write(task_queue_base[1], '0, dummy_set_chip1_local_0, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,1,0,1,5", $time);
    task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster0_core1_dma, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,1,0,0,7", $time);
    task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster0_core0_gemm, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,1,0,0,20", $time);
    task_queue_master[1].write(task_queue_base[1], '0, dummy_set_chip1_to_chip3, '1, resp);
    #50;
end

// Chiplet 2: 7 tasks
initial begin : chip2_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[2].reset();
    done_queue_master[2].reset();

    $display("[TRACE] %0t,TASK_PUSHED,2,0,0,8", $time);
    task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster0_core0_gemm, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,2,1,1,10", $time);
    task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster1_core1_dma, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,2,0,0,21", $time);
    task_queue_master[2].write(task_queue_base[2], '0, dummy_set_chip2_local_0, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,2,0,1,9", $time);
    task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster0_core1_dma, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,2,0,0,25", $time);
    task_queue_master[2].write(task_queue_base[2], '0, dummy_check_chip2_0, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,2,0,0,11", $time);
    task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster0_core0_gemm_2, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,2,0,0,22", $time);
    task_queue_master[2].write(task_queue_base[2], '0, dummy_set_chip2_to_chip3, '1, resp);
    #50;
end

// Chiplet 3: 9 tasks
initial begin : chip3_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[3].reset();
    done_queue_master[3].reset();

    $display("[TRACE] %0t,TASK_PUSHED,3,0,0,26", $time);
    task_queue_master[3].write(task_queue_base[3], '0, dummy_check_chip3_0, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,0,12", $time);
    task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core0_gemm_1, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,2,15", $time);
    task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core2_simd, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,0,23", $time);
    task_queue_master[3].write(task_queue_base[3], '0, dummy_set_chip3_local_0, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,0,24", $time);
    task_queue_master[3].write(task_queue_base[3], '0, dummy_set_chip3_local_1, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,1,13", $time);
    task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core1_dma, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,1,1,14", $time);
    task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster1_core1_dma, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,0,27", $time);
    task_queue_master[3].write(task_queue_base[3], '0, dummy_check_chip3_1a, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,0,28", $time);
    task_queue_master[3].write(task_queue_base[3], '0, dummy_check_chip3_1b, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,3,0,0,16", $time);
    task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core0_gemm_2, '1, resp);
    #50;
end
