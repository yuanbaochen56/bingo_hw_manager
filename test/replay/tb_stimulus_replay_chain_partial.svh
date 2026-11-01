// =============================================================================
// Replay: the substitute dies while the dead core is only partly moved (P0-3)
// =============================================================================
// All 4 cores are type 1 (CheckoutQueueDepth 8).
//   tasks 1-4  (core 0): 1 hangs on core 0, 2-4 queue behind it
//   tasks 11-17 (core 1): 11 hangs on core 1 (100 cycles after task 1), 12-17
//                         queue behind it, so core 1's checkout holds 7 entries
// Core 0 is fenced first. MOVE pushes task 1 to core 1 (lowest live core),
// which fills core 1's checkout, and stalls. Core 1 is fenced ~100 cycles
// later. The rest of core 0 (tasks 2-4) must not reach core 2 before task 1:
// core 0's migration is aborted, core 1 (11-17, then 1) is moved to core 2
// first, then core 0 resumes (2-4 to core 2).
// EXPECTED: all 11 tasks complete, logical core 0 retires 1,2,3,4 in order
// (RETIRE_CHECK), cores 0 and 1 retired, 12 replayed entries.

localparam int unsigned EXPECTED_TASK_COUNT     = 11;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t cp_d [4];
bingo_hw_manager_task_desc_full_t cp_s [7];
initial begin
    for (int i = 0; i < 4; i++) begin
        cp_d[i] = pack_normal_task(2'b00, 16'(1 + i), 0, 0, 0,
            1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
    for (int i = 0; i < 7; i++) begin
        cp_s[i] = pack_normal_task(2'b00, 16'(11 + i), 0, 0, 1,
            1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, cp_d[0], '1, resp);
    repeat (100) @(posedge clk_i);
    for (int i = 0; i < 7; i++) task_queue_master[0].write(task_queue_base[0], '0, cp_s[i], '1, resp);
    for (int i = 1; i < 4; i++) task_queue_master[0].write(task_queue_base[0], '0, cp_d[i], '1, resp);
end

// Order in which entries reach core 2
int unsigned cp_order [$];
bit          cp_abort_seen = 1'b0;
always @(posedge clk_i) begin
    if (rst_ni && gen_dut[0].i_dut.replay_step.fire && (gen_dut[0].i_dut.replay_step.dst_core == 2)) begin
        cp_order.push_back(gen_dut[0].i_dut.replay_data.task_id);
    end
    // MOVE of core 0 left while core 0 still holds entries
    if (rst_ni && (gen_dut[0].i_dut.i_replay_ctrl.state_q == 2) &&
        (gen_dut[0].i_dut.i_replay_ctrl.state_d == 0) &&
        !gen_dut[0].i_dut.checkout_queue_empty[0][0]) begin
        cp_abort_seen = 1'b1;
    end
end

final begin
    automatic int pos1 = -1;
    automatic int pos2 = -1;
    foreach (cp_order[i]) begin
        if (cp_order[i] == 1) pos1 = i;
        if (cp_order[i] == 2) pos2 = i;
    end
    if (retired_export[0][0][0] !== 1'b1 || retired_export[0][1][0] !== 1'b1) begin
        $error("[CHAIN_PARTIAL] cores 0 and 1 must be retired");
    end
    if (fenced_export[0][2][0] !== 1'b0 || fenced_export[0][3][0] !== 1'b0) begin
        $error("[CHAIN_PARTIAL] only cores 0 and 1 may be fenced");
    end
    if (pos1 < 0 || pos2 < 0 || pos1 > pos2) begin
        $error("[CHAIN_PARTIAL] task 1 must reach core 2 before task 2 (order %p)", cp_order);
    end
    if (!cp_abort_seen) $error("[CHAIN_PARTIAL] core 0's migration was never aborted (scenario not hit)");
    if (replay_move_count[0] != 12) $error("[CHAIN_PARTIAL] expected 12 replayed entries, got %0d", replay_move_count[0]);
end
