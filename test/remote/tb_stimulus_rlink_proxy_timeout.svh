// =============================================================================
// Level 3 over the real transport: origin-side proxy timeout
// =============================================================================
// Two chiplets, 1 cluster x 3 cores, core k of type k + 1, proxy timeout
// PT_TIMEOUT. Core 0 of chiplet 0 gets tasks 1..8 and hangs on task 1: it is
// fenced and its tasks exported to chiplet 1, which holds its imports
// (rl_import_hold) for PT_HOLD cycles after the fence (-1: for good). Core 1 of
// chiplet 0 runs task 20 locally.
//   PT_HOLD = -1: the remote done of task 1 never comes. EXPECTED: the proxy
//   gives up PT_TIMEOUT cycles after it started waiting, not earlier: the slot
//   is stuck (replay_stuck_o), remote_timeout_o is set, task 20 completes.
//   PT_HOLD < PT_TIMEOUT: every done arrives within the timeout, though all
//   eight together take longer. EXPECTED: no timeout, all 9 tasks complete.

localparam int          PT_HOLD    = `TB_PT_HOLD;
localparam int unsigned PT_TIMEOUT = `TB_REMOTE_PROXY_TIMEOUT;
localparam int unsigned EXPECTED_TASK_COUNT     = (PT_HOLD < 0) ? 999 : 9;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

int unsigned pt_wait_start = 0;   // cycle the proxy started waiting (first export at its head)
int unsigned pt_cycle      = 0;
always @(posedge clk_i) begin
    pt_cycle++;
    if ((pt_wait_start == 0) && gen_dut[0].i_dut.proxy.waiting[0][0]) pt_wait_start = pt_cycle;
end

initial begin : pt_hold_chip1
    rl_import_hold[1] = 1'b1;
    if (PT_HOLD >= 0) begin
        wait (gen_dut[0].i_dut.core_fenced[0][0]);
        repeat (PT_HOLD) @(posedge clk_i);
        rl_import_hold[1] = 1'b0;
    end
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 8; i++) begin
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, i, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    end
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 20, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
end

if (PT_HOLD < 0) begin : gen_pt_lost
    initial begin
        automatic int unsigned gap;
        wait (remote_timeout[0]);
        gap = pt_cycle - pt_wait_start;
        if (pt_wait_start == 0) $error("[PT] timeout without a waiting proxy");
        else if ((gap < PT_TIMEOUT) || (gap > PT_TIMEOUT + 5))
            $error("[PT] timeout %0d cycles after the proxy started waiting, timeout is %0d", gap, PT_TIMEOUT);
        repeat (5) @(posedge clk_i);
        if (!gen_dut[0].i_dut.remote_rejected_q[0][0]) $error("[PT] proxy slot 0 not stopped");
        if (!gen_dut[0].i_dut.replay_stuck) $error("[PT] replay_stuck_o not set");
        wait (task_completed_bitmap[20]);
        repeat (100) @(posedge clk_i);
        if (remote_done_in_count[0] != 0) $error("[PT] %0d remote dones arrived", remote_done_in_count[0]);
        $display("[PT] proxy gave up %0d cycles after it started waiting", gap);
        $display("Proxy timeout test passed");
        $finish;
    end
end else begin : gen_pt_slow
    final begin
        if (remote_timeout[0]) $error("[PT] the proxy timed out although every done came within the timeout");
        if (remote_done_in_count[0] != 8) $error("[PT] %0d remote dones, expected 8", remote_done_in_count[0]);
        $display("[PT] the dones took %0d cycles after the proxy started waiting, timeout %0d",
                 pt_cycle - pt_wait_start, PT_TIMEOUT);
    end
end
