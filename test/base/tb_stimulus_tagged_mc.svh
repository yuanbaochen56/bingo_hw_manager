// =============================================================================
// Multi-cluster tagged stimulus: cross-cluster column-aliasing, disambiguated
// by per-edge tags (the core purpose of the tagged dep matrix; hazard 2a in
// COUNTER_SHARING_BUG.md). Single chiplet, TWO clusters, 3 cores.
//
// Both producers sit on the DMA core (core1) and BOTH set cluster-0's cell
// [row0][col1] -- one locally, one from cluster 1 via a CROSS-cluster dep_set --
// but with DISTINCT tags:
//
//   PA @ (cl0,core1) --set cl0 cell[0][1] tag 0--> CA @ (cl0,core0) checks tag 0
//   PB @ (cl1,core1) --set cl0 cell[0][1] tag 1--> CB @ (cl0,core0) checks tag 1
//                       (PB's dep_set targets cluster 0: dep_set_cluster_id=0)
//
// The bare-core column (col1) cannot tell PA from PB; only the tag separates
// them. With tags correctly routed through the SET arbiter -> cluster demux
// (dep_matrix_id = dep_set_cluster_id) -> core demux -> matrix, CA drains PA's
// tag-0 slot and CB drains PB's tag-1 slot, so all 4 tasks complete. If the
// cross-cluster set dropped/aliased its tag (tags collapsed to 0), the presence
// bit would saturate on slot 0, CA would drain it, and CB would wait forever ->
// deadlock. So "all 4 complete" proves the MULTI-CLUSTER tagged datapath works.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 4;
localparam int unsigned DEADLOCK_THRESHOLD      = 2000;  // cycles
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;     // disabled

// PA @ (chiplet0, cluster0, core1/DMA): set cluster0 row0 (core0), tag 0
bingo_hw_manager_task_desc_full_t pa = pack_normal_task(
    1'b0, 16'd1, 0, 0, 1,
    1'b0, '0,                                                 // no dep_check (root)
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b001),   // dep_set -> cluster0, row0
    '0, 4'd0                                                  // dep_check_tag n/a, dep_set_tag=0
);

// PB @ (chiplet0, cluster1, core1/DMA): CROSS-cluster set into cluster0 row0, tag 1
bingo_hw_manager_task_desc_full_t pb = pack_normal_task(
    1'b0, 16'd2, 0, 1, 1,
    1'b0, '0,                                                 // no dep_check (root)
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b001),   // dep_set_cluster_id=0 -> cluster0
    '0, 4'd1                                                  // dep_set_tag=1
);

// CA @ (chiplet0, cluster0, core0/GEMM): check col1 (core1) with tag 0 -> drains PA
bingo_hw_manager_task_desc_full_t ca = pack_normal_task(
    1'b0, 16'd3, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(3'b010),               // dep_check col1
    1'b0, 1'b0, 0, 0, '0,
    4'd0, '0                                                  // dep_check_tag=0
);

// CB @ (chiplet0, cluster0, core0/GEMM): check col1 (core1) with tag 1 -> drains PB
bingo_hw_manager_task_desc_full_t cb = pack_normal_task(
    1'b0, 16'd4, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(3'b010),
    1'b0, 1'b0, 0, 0, '0,
    4'd1, '0                                                  // dep_check_tag=1
);

// ---------------------------------------------------------------------------
// Push (single chiplet, HW routes by assigned cluster/core).
//   cl0.core1: [PA]   cl1.core1: [PB]   cl0.core0: [CA, CB]
// ---------------------------------------------------------------------------
initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, pa, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,1,1,2", $time);
    task_queue_master[0].write(task_queue_base[0], '0, pb, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,3", $time);
    task_queue_master[0].write(task_queue_base[0], '0, ca, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,4", $time);
    task_queue_master[0].write(task_queue_base[0], '0, cb, '1, resp);
    #50;
end
