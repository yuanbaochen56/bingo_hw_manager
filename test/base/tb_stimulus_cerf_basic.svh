// =============================================================================
// DARTS Tier 1 Basic CERF Test
// =============================================================================
// Simplest CERF test: 3 tasks on a serial chain (core 0 → core 1 → core 2).
// Task on core 1 is conditional (CERF group 0).
// CERF group 0 is activated at start → task executes normally.
// EXPECTED: all 3 normal tasks complete.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT    = 3;
localparam int unsigned DEADLOCK_THRESHOLD     = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

// Task 1: core 0, no deps, sets core 1
bingo_hw_manager_task_desc_full_t t1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000010)
);

// Task 2: core 1, checks core 0, sets core 2 — CONDITIONAL (group 0)
bingo_hw_manager_task_desc_full_t t2;
initial begin
    t2 = pack_normal_task(
        2'b00, 16'd2, 0, 0, 1,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),
        1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(8'b00000100)
    );
    t2.cond_exec_en = 1'b1;
    t2.cond_exec_group_id = 5'd0;
    t2.cond_exec_invert = 1'b0;  // execute when group 0 is ACTIVE
end

// Task 3: core 2, checks core 1, no dep_set
bingo_hw_manager_task_desc_full_t t3 = pack_normal_task(
    2'b00, 16'd3, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),
    1'b0, 1'b0, 0, 0, '0
);

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    // Activate CERF group 0 BEFORE pushing tasks
    cerf_write_bitmask(0, 32'h0000_0001);
    $display("[CERF] %0t Group 0 activated", $time);

    task_queue_master[0].write(task_queue_base[0], '0, t1, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t3, '1, resp);
    #50;
end
