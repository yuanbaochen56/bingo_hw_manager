// =============================================================================
// Parking a core that runs another core's tasks
// =============================================================================
// Three cores of one type, cores driven by the stimulus. Core 0 runs task 1
// (logical 0, with heartbeats); core 1 takes task 11 (logical 1) and hangs.
// The host asks to park core 0 while task 1 is still running: HOLD. Core 1 is
// fenced and its entry points at core 0 (lowest live core of the type), so
// core 0 now runs logical core 1's tasks: it gives up the park at once
// (park_fail) instead of holding its own tasks behind them. Task 11 is replayed
// onto core 0 and both complete. Asked again, the park fails at once, without
// a HOLD, since core 0 is still the target of the fenced core 1.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

initial begin : park_target_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id0, id1;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 11, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    csr_read(0, 0, 0, CSR_READY, id0);
    csr_read(0, 0, 1, CSR_READY, id1);                    // core 1 now hangs on task 11
    if (id0[TaskIdWidth-1:0] != 1 || id1[TaskIdWidth-1:0] != 11) $fatal(1, "cores read tasks %0d / %0d", id0, id1);
    @(negedge clk_i);
    park_req[0] = 32'd1;
    repeat (5) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.hold[0][0] !== 1'b1) $fatal(1, "core 0 did not enter HOLD");
    // core 0 keeps working on task 1 (heartbeats) until core 1 is fenced
    fork : wait_fence
        wait (gen_dut[0].i_dut.core_fenced[1][0] === 1'b1);
        forever busy_with_heartbeat(0, 0, 0, 100, 50);
        begin
            repeat (5000) @(posedge clk_i);
            $fatal(1, "core 1 was not fenced");
        end
    join_any
    disable wait_fence;
    repeat (5) @(posedge clk_i);
    if (gen_dut[0].i_dut.smt.core[1][0] !== 0) $fatal(1, "fenced core 1 goes to core %0d, expected 0", gen_dut[0].i_dut.smt.core[1][0]);
    if (gen_dut[0].i_dut.park.hold[0][0] !== 1'b0 || park_fail[0][0] !== 1'b1)
        $error("[PARK_TARGET] core 0 runs core 1's tasks but kept its park (hold %0b fail %0b)",
               gen_dut[0].i_dut.park.hold[0][0], park_fail[0][0]);
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $error("[PARK_TARGET] core 0 parked");
    csr_done(0, 0, 0, 1);
    csr_read(0, 0, 0, CSR_READY, id0);                    // the replayed task 11
    if (id0[TaskIdWidth-1:0] != 11) $error("[PARK_TARGET] core 0 read task %0d, expected the replayed 11", id0);
    csr_done(0, 0, 0, 11);
    // asked again: fails at once, no HOLD
    @(negedge clk_i);
    park_req[0] = 32'd0;
    repeat (3) @(posedge clk_i);
    if (park_fail[0][0] !== 1'b0) $error("[PARK_TARGET] park_fail did not clear with the request");
    @(negedge clk_i);
    park_req[0] = 32'd1;
    for (int t = 0; t < 20; t++) begin
        @(posedge clk_i);
        if (gen_dut[0].i_dut.park.hold[0][0] !== 1'b0) $error("[PARK_TARGET] HOLD entered by the target of a fenced core");
    end
    if (park_fail[0][0] !== 1'b1) $error("[PARK_TARGET] second request did not fail");
    $display("Park target test passed");
    $finish;
end
