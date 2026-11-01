// =============================================================================
// Level 3: stray remote dones / rejects
// =============================================================================
// Two chiplets, 1 cluster, 3 cores of distinct types, SubstituteLevelMask =
// 3'b111, no fault: no slot is fenced, so no slot of chiplet 0 is a proxy.
// Before any task, chiplet 0's remote done input sees (forced, one cycle each):
//   a done of task 77 for live slot 1, a reject of task 78 for live slot 2,
//   a done of task 79 for slot 3 (out of range: 3 cores)
// EXPECTED: each is accepted in its cycle (the link is not blocked), none
// enters a done FIFO or marks a slot rejected, remote_done_mismatch_o is set;
// then tasks 1..3 on chiplet 0 (one per core) and 11 on chiplet 1 complete.

localparam int unsigned EXPECTED_TASK_COUNT     = 4;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t st [12];
initial begin
    st[1]  = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    st[2]  = pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    st[3]  = pack_normal_task(2'b00, 3, 0, 0, 2, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    st[11] = pack_normal_task(2'b00, 11, 1, 0, 0, 1'b0, '0, 1'b0, 1'b0, 1, 0, '0);
end

// (static: a force needs static operands)
logic [REMOTE_SLOT_W-1:0] stray_slot;
logic [TaskIdWidth-1:0]   stray_tid;
logic                     stray_reject;
task automatic stray_done(input int unsigned slot, input int unsigned tid, input bit reject);
    @(negedge clk_i);
    stray_slot   = REMOTE_SLOT_W'(slot);
    stray_tid    = TaskIdWidth'(tid);
    stray_reject = reject;
    force gen_dut[0].i_dut.remote_done_valid_i      = 1'b1;
    force gen_dut[0].i_dut.remote_done_proxy_slot_i = stray_slot;
    force gen_dut[0].i_dut.remote_done_task_id_i    = stray_tid;
    force gen_dut[0].i_dut.remote_done_reject_i     = stray_reject;
    #1;
    if (gen_dut[0].i_dut.remote_done_ready_o !== 1'b1) begin
        $error("[DONE_STRAY] %s of task %0d for slot %0d not accepted (the link would block)",
               reject ? "reject" : "done", tid, slot);
    end
    @(negedge clk_i);
    release gen_dut[0].i_dut.remote_done_valid_i;
    release gen_dut[0].i_dut.remote_done_proxy_slot_i;
    release gen_dut[0].i_dut.remote_done_task_id_i;
    release gen_dut[0].i_dut.remote_done_reject_i;
endtask

initial begin : chip0_stray_then_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    stray_done(1, 77, 1'b0);
    stray_done(2, 78, 1'b1);
    stray_done(3, 79, 1'b0);
    repeat (5) @(posedge clk_i);
    if (!gen_dut[0].i_dut.done_q_empty[1][0] || !gen_dut[0].i_dut.done_q_empty[2][0]) begin
        $error("[DONE_STRAY] a stray done entered a done FIFO");
    end
    if (gen_dut[0].i_dut.remote_rejected_q !== '0) $error("[DONE_STRAY] a stray reject stopped slot(s) %b",
                                                         gen_dut[0].i_dut.remote_rejected_q);
    if (gen_dut[0].i_dut.remote_done_mismatch_o !== 1'b1) $error("[DONE_STRAY] remote_done_mismatch_o not set");
    for (int i = 1; i <= 3; i++) task_queue_master[0].write(task_queue_base[0], '0, st[i], '1, resp);
end

initial begin : chip1_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[1].write(task_queue_base[1], '0, st[11], '1, resp);
end

final begin
    if (gen_dut[1].i_dut.remote_done_mismatch_o !== 1'b0) $error("[DONE_STRAY] chiplet 1 flagged a mismatch");
    if (gen_dut[0].i_dut.replay_stuck !== 1'b0) $error("[DONE_STRAY] chiplet 0 is stuck");
    for (int c = 0; c < 3; c++) begin
        if (!gen_dut[0].i_dut.checkout_queue_empty[c][0]) $error("[DONE_STRAY] core %0d did not retire its task", c);
    end
end
