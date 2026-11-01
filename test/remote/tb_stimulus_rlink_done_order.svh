// =============================================================================
// Level 3 over the real transport: done order with two proxy slots
// =============================================================================
// Chiplet 0: core 0 hangs on task 1 (tasks 1..6), core 1 hangs on task 11
// (tasks 11..16); both are exported to chiplet 1 and run there in parallel on
// its cores 0 and 1. Task 6 sets core 2 (task 21 checks it), task 16 sets
// core 2 (task 22 checks it). Chiplet 1 has local tasks 31..33.
// TB_REMOTE_CREDITS 8: all exports may be in flight at once. (The import
// mailbox on chiplet 1 is in order: the tasks of slot 1 wait behind those of
// slot 0 until core 0 of chiplet 1 has room, so the dones do not interleave.)
// The harness checks that each proxy slot gets its dones in export order.
// EXPECTED: all 17 tasks complete; 12 exports, 12 dones back on chiplet 0.

localparam int unsigned EXPECTED_TASK_COUNT     = 17;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t dor [34];
initial begin
    for (int i = 1; i <= 5; i++) dor[i] = pack_normal_task(2'b00, i, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    dor[6] = pack_normal_task(2'b00, 6, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    for (int i = 11; i <= 15; i++) dor[i] = pack_normal_task(2'b00, i, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    dor[16] = pack_normal_task(2'b00, 16, 0, 0, 1, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    dor[21] = pack_normal_task(2'b00, 21, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    dor[22] = pack_normal_task(2'b00, 22, 0, 0, 2, 1'b1, bingo_hw_manager_dep_code_t'(3'b010), 1'b0, 1'b0, 0, 0, '0);
    for (int i = 31; i <= 33; i++) dor[i] = pack_normal_task(2'b00, i, 1, 0, i - 31, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 6; i++) begin
        task_queue_master[0].write(task_queue_base[0], '0, dor[i], '1, resp);
        task_queue_master[0].write(task_queue_base[0], '0, dor[i + 10], '1, resp);
    end
    task_queue_master[0].write(task_queue_base[0], '0, dor[21], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, dor[22], '1, resp);
end

initial begin : chip1_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 31; i <= 33; i++) task_queue_master[1].write(task_queue_base[1], '0, dor[i], '1, resp);
end

int unsigned dor_slot_seq [$];
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (rdn_in_valid[0] && rdn_ready[0]) dor_slot_seq.push_back(rdn_in_proxy_slot[0]);
        if (task_completed_bitmap[21] && !task_completed_bitmap[6])  $error("[DONE_ORDER] task 21 before task 6");
        if (task_completed_bitmap[22] && !task_completed_bitmap[16]) $error("[DONE_ORDER] task 22 before task 16");
    end
end

final begin
    if (remote_export_count[0] != 12) $error("[DONE_ORDER] %0d exports, expected 12", remote_export_count[0]);
    if (remote_done_in_count[0] != 12) $error("[DONE_ORDER] %0d dones back, expected 12", remote_done_in_count[0]);
    if (remote_import_count[1] != 12) $error("[DONE_ORDER] %0d imports on chiplet 1, expected 12", remote_import_count[1]);
    if (retired_export[0] !== 3'b011) $error("[DONE_ORDER] retired %b, expected 011", retired_export[0]);
    if (!gen_dut[0].i_dut.checkout_queue_empty[0][0] || !gen_dut[0].i_dut.checkout_queue_empty[1][0]) begin
        $error("[DONE_ORDER] proxy checkout queues not drained");
    end
    $display("[DONE_ORDER] done slot sequence on chiplet 0: %p", dor_slot_seq);
end
