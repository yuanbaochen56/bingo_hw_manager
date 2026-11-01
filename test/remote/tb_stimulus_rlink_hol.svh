// =============================================================================
// Level 3 over the real transport: two peers, no head-of-line blocking
// =============================================================================
// Three chiplets, 1 cluster x 3 cores, core k of type k + 1. Chiplet 0 exports
// type 1 to its successor (chiplet 1) and type 2 to its predecessor (chiplet 2),
// 2 credits per peer, no random stalls. Chiplet 1 holds its imports
// (rl_import_hold) until HOL_RELEASE cycles after both faults.
// Chiplet 0: core 0 gets tasks 1..5 and hangs on task 1, core 1 gets tasks
// 11..13 and hangs on task 11. Both are fenced and their tasks exported.
// EXPECTED: two exports reach chiplet 1's mailbox and the credits for it run out;
// while it holds them, chiplet 2 still imports tasks 11..13 (they do not wait
// behind the exports to chiplet 1) and runs them; after the release all 8
// tasks complete.

localparam int unsigned EXPECTED_TASK_COUNT     = 8;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int unsigned HOL_RELEASE             = 3000;

initial begin : hol_hold_chip1
    rl_import_hold[1] = 1'b1;
    wait (gen_dut[0].i_dut.core_fenced[0][0] && gen_dut[0].i_dut.core_fenced[1][0]);
    repeat (HOL_RELEASE) @(posedge clk_i);
    if (remote_import_count[2] != 3) begin
        $error("[HOL] chiplet 2 imported %0d of 3 tasks while chiplet 1 held its imports", remote_import_count[2]);
    end
    // peers of chiplet 0: {successor (1), predecessor (2)}, so chiplet 1 is peer 1
    if (gen_rlink.gen_node[0].credits[1] != 0) $error("[HOL] chiplet 0 still has credits for chiplet 1");
    $display("[HOL] %0t chiplet 2 imported %0d tasks while chiplet 1 was held; releasing",
             $time, remote_import_count[2]);
    rl_import_hold[1] = 1'b0;
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 5; i++) begin
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, i, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    end
    for (int i = 11; i <= 13; i++) begin
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, i, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    end
end

final begin
    if (remote_import_count[1] != 5) $error("[HOL] chiplet 1 imported %0d tasks, expected 5", remote_import_count[1]);
    if (remote_import_count[2] != 3) $error("[HOL] chiplet 2 imported %0d tasks, expected 3", remote_import_count[2]);
    if (remote_done_in_count[0] != 8) $error("[HOL] %0d dones back at chiplet 0, expected 8", remote_done_in_count[0]);
end
