// =============================================================================
// Replay: the substitute dies too
// =============================================================================
// CoreTypeId: cores 0, 1 and 3 are type 1, core 2 is type 2.
//   task 1 (core 0) hangs on core 0 -> replayed on core 1, hangs there as well
//   task 2 (core 1) runs normally before that
//   task 3 (logical core 0), pushed after core 0 retired -> remapped to core 1
//   task 4 (core 1), sets core 2 col 1
//   task 5 (core 2) checks col 0 (task 1) and col 1 (task 4)
// When core 1 is fenced, its checkout holds task 1 (logical 0), task 3
// (logical 0) and task 4 (logical 1): all of them must move to core 3, not to
// the lower-indexed live core 2 of another type.
// EXPECTED: tasks 1-5 complete, 4 replayed entries.

localparam int unsigned EXPECTED_TASK_COUNT     = 5;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t c_t1 = pack_normal_task(2'b00, 16'd1, 0, 0, 0,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0100));
bingo_hw_manager_task_desc_full_t c_t2 = pack_normal_task(2'b00, 16'd2, 0, 0, 1,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t c_t3 = pack_normal_task(2'b00, 16'd3, 0, 0, 0,
    1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t c_t4 = pack_normal_task(2'b00, 16'd4, 0, 0, 1,
    1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0100));
bingo_hw_manager_task_desc_full_t c_t5 = pack_normal_task(2'b00, 16'd5, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(4'b0011), 1'b0, 1'b0, 0, 0, '0);

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, c_t1, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, c_t2, '1, resp);
    wait_retired(0, 0, 0, 5000);
    task_queue_master[0].write(task_queue_base[0], '0, c_t3, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, c_t4, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, c_t5, '1, resp);
end

// Destinations of the second migration (off core 1)
always @(posedge clk_i) begin
    if (rst_ni && gen_dut[0].i_dut.replay_step.fire && (gen_dut[0].i_dut.replay_src_core == 1)) begin
        automatic int logical = gen_dut[0].i_dut.replay_data.assigned_core_id;
        automatic int dst     = gen_dut[0].i_dut.replay_step.dst_core;
        if (dst != 3) begin
            $error("[CHAIN] task %0d of logical core %0d moved to core %0d",
                   gen_dut[0].i_dut.replay_data.task_id, logical, dst);
        end
    end
end

final begin
    if (retired_export[0][0][0] !== 1'b1 || retired_export[0][1][0] !== 1'b1) begin
        $error("[CHAIN] cores 0 and 1 must be retired");
    end
    if (replay_move_count[0] != 4) $error("[CHAIN] expected 4 replayed entries, got %0d", replay_move_count[0]);
end
