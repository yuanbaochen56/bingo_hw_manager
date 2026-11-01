// =============================================================================
// Tagged stimulus: identity-aware deps end-to-end through bingo_hw_manager_top
// =============================================================================
// Two producer->consumer edges that map to the SAME dep-matrix cell [row0][col1]
// (consumers on core0/GEMM, producers on core1/DMA) but carry DISTINCT tags:
//   P1 --(tag 0)--> C1      P2 --(tag 1)--> C2
//
// With the per-edge tags correctly plumbed, C1 drains only
// P1's tag-0 token and C2 only P2's tag-1 token, so all four tasks complete. If
// the tag datapath were broken (tags collapsed to 0), the presence-bit scoreboard
// would saturate on slot 0 and the second consumer would never pass its check ->
// deadlock. So "all 4 complete" proves tags travel descriptor->arbiter->demux->
// matrix and descriptor->FSM->check.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 4;
localparam int unsigned DEADLOCK_THRESHOLD      = 2000;  // cycles
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;     // disabled

// P1 (core1/DMA) -> C1 (core0/GEMM), tag 0
bingo_hw_manager_task_desc_full_t p1 = pack_normal_task(
    1'b0, 16'd1, 0, 0, 1,
    1'b0, '0,                                                 // no dep_check
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000001), // set row0 (consumer core0)
    '0, 3'd0                                                  // dep_check_tag, dep_set_tag=0
);

// P2 (core1/DMA) -> C2 (core0/GEMM), tag 1
bingo_hw_manager_task_desc_full_t p2 = pack_normal_task(
    1'b0, 16'd2, 0, 0, 1,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000001),
    '0, 3'd1
);

// C1 (core0/GEMM) waits on core1 with tag 0
bingo_hw_manager_task_desc_full_t c1 = pack_normal_task(
    1'b0, 16'd3, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),          // check col1 (producer core1)
    1'b0, 1'b0, 0, 0, '0,
    3'd0, '0                                                  // dep_check_tag=0
);

// C2 (core0/GEMM) waits on core1 with tag 1
bingo_hw_manager_task_desc_full_t c2 = pack_normal_task(
    1'b0, 16'd4, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),
    1'b0, 1'b0, 0, 0, '0,
    3'd1, '0                                                  // dep_check_tag=1
);

// ---------------------------------------------------------------------------
// Push sequence (single chiplet). core1 queue: [P1,P2]; core0 queue: [C1,C2].
// ---------------------------------------------------------------------------
initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p1, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,2", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p2, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,3", $time);
    task_queue_master[0].write(task_queue_base[0], '0, c1, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,4", $time);
    task_queue_master[0].write(task_queue_base[0], '0, c2, '1, resp);
    #50;
end
