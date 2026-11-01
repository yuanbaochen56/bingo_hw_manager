// =============================================================================
// Waiting queues of depth 2 (WaitingQueueDepth)
// =============================================================================
// Two cores, one cluster. Eight independent tasks of core 0, then two of
// core 1, written back to back into the task queue.
// EXPECTED: the waiting queues are built with depth 2; the queue of core 0
// fills (the task queue then waits, and core 1's tasks wait behind it); all
// ten tasks complete.

localparam int unsigned EXPECTED_TASK_COUNT     = 10;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

int unsigned wd_full_cycles = 0;
always @(negedge clk_i) begin : waiting_full_monitor
    if (rst_ni && gen_dut[0].i_dut.i_dep_unit.waiting_dep_check_queue_full[0]) wd_full_cycles++;
end

initial begin : stimulus
    automatic axi_pkg::resp_t resp;
    if (gen_dut[0].i_dut.i_dep_unit.gen_waiting_dep_check_queue[0].i_waiting_dep_check_queue.DEPTH != 2)
        $error("[WAITING_DEPTH] waiting queue depth %0d, expected 2",
               gen_dut[0].i_dut.i_dep_unit.gen_waiting_dep_check_queue[0].i_waiting_dep_check_queue.DEPTH);
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 8; i++)
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, i, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    for (int i = 9; i <= 10; i++)
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, i, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
end

final begin
    if (wd_full_cycles == 0) $error("[WAITING_DEPTH] the waiting queue of core 0 never filled");
    else $display("[WAITING_DEPTH] the waiting queue of core 0 was full for %0d cycles", wd_full_cycles);
end
