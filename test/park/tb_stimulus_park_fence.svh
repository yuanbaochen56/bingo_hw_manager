// =============================================================================
// Fence during a park drain
// =============================================================================
// Core 0 takes task 1 and hangs. The host requests a park while that task is
// still outstanding, and pushes task 2, which must not leave the logical core
// yet. The watchdog then fences core 0. The park is dropped, task 1 is
// replayed onto core 1, and task 2 follows after the retire. Each task
// completes once.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t park_f_task_1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t park_f_task_2 = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

initial begin : park_fence_test
    automatic axi_pkg::resp_t resp;

    wait (rst_ni);
    repeat (30) @(posedge clk_i);

    task_queue_master[0].write(task_queue_base[0], '0, park_f_task_1, '1, resp);
    fork : wait_inflight
        wait (checkout_empty_export[0][0][0] === 1'b0);
        begin
            repeat (2000) @(posedge clk_i);
            $fatal(1, "task 1 did not enter core 0's checkout");
        end
    join_any
    disable wait_inflight;

    @(negedge clk_i);
    park_req[0] = 32'd1;
    fork : wait_hold_f
        wait (gen_dut[0].i_dut.park.hold[0][0] === 1'b1);
        begin
            repeat (50) @(posedge clk_i);
            $fatal(1, "core 0 did not enter HOLD (fenced %0b)", fenced_export[0][0][0]);
        end
    join_any
    disable wait_hold_f;
    if (fenced_export[0][0][0] !== 1'b0) $fatal(1, "core 0 was already fenced when HOLD started");

    task_queue_master[0].write(task_queue_base[0], '0, park_f_task_2, '1, resp);
    repeat (30) @(posedge clk_i);
    if (remap_count[0] != 0) $fatal(1, "task 2 left logical core 0 during HOLD");
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $fatal(1, "PARKED while task 1 was still outstanding");

    fork : wait_fence_f
        wait (fenced_export[0][0][0] === 1'b1);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "core 0 was not fenced");
        end
    join_any
    disable wait_fence_f;
    repeat (4) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.hold[0][0] !== 1'b0) $fatal(1, "HOLD survived the fence");
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $fatal(1, "PARKED after the fence");

    fork : wait_done_f
        wait (task_completed_bitmap[1] && task_completed_bitmap[2]);
        begin
            repeat (20000) @(posedge clk_i);
            $fatal(1, "tasks did not both complete (1=%0b 2=%0b replay %0d remap %0d)",
                   task_completed_bitmap[1], task_completed_bitmap[2],
                   replay_move_count[0], remap_count[0]);
        end
    join_any
    disable wait_done_f;
    if (replay_move_count[0] == 0) $fatal(1, "the outstanding task was not replayed");
    if (remap_count[0] == 0) $fatal(1, "task 2 did not follow the substitute after the retire");
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $fatal(1, "core 0 stayed PARKED");
    repeat (20) @(posedge clk_i);
    $display("Core parking fence-during-drain test passed");
    $finish;
end
