// =============================================================================
// Move a parked core back (UNPARK)
// =============================================================================
// Two cores of one type, driven by the stimulus. Core 0 is parked onto core 1,
// then gets tasks 1 and 2, which run on core 1 (core 1 is busy with task 1).
// The host clears the request: UNPARK. Task 3 of logical core 0 is then held,
// on neither core, while tasks 1 and 2 are still on core 1. Core 1's own task
// 11, pushed meanwhile, enters core 1's queue at once (the substitute is not
// held). Once 1 and 2 retired, core 0 is no longer parked and task 3 runs on
// core 0; core 1 runs task 11. The harness checks the per-core retire order.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

device_axi_lite_data_t up_core0_id = '0;
bit                    up_core0_got = 1'b0;

initial begin : unpark_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    park_req[0] = 32'd1;
    repeat (10) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b1 || gen_dut[0].i_dut.smt.core[0][0] !== 1)
        $fatal(1, "core 0 not parked onto core 1");
    for (int i = 1; i <= 2; i++) begin
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, i, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    end
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 1) $fatal(1, "core 1 read task %0d, expected 1", id);
    fork
        begin
            csr_read(0, 0, 0, CSR_READY, up_core0_id);
            up_core0_got = 1'b1;
        end
    join_none
    // move back while tasks 1 and 2 are both on core 1
    fork : wait_both
        wait (gen_dut[0].i_dut.checkout_queue_usage[1][0] == 2);
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "task 2 did not reach core 1");
        end
    join_any
    disable wait_both;
    @(negedge clk_i);
    park_req[0] = 32'd0;
    repeat (3) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.unpark[0][0] !== 1'b1 || gen_dut[0].i_dut.park.parked[0][0] !== 1'b1)
        $error("[UNPARK] expected UNPARK (unpark %0b parked %0b)",
               gen_dut[0].i_dut.park.unpark[0][0], gen_dut[0].i_dut.park.parked[0][0]);
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 3, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 11, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    repeat (50) @(posedge clk_i);
    if (up_core0_got) $error("[UNPARK] core 0 got task %0d before its tasks on core 1 retired", up_core0_id);
    if (gen_dut[0].i_dut.checkout_queue_usage[1][0] != 3)
        $error("[UNPARK] core 1 holds %0d entries, expected 3 (tasks 1, 2 and its own 11)",
               gen_dut[0].i_dut.checkout_queue_usage[1][0]);
    busy_with_heartbeat(0, 0, 1, 100, 50);
    csr_done(0, 0, 1, 1);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 2) $error("[UNPARK] core 1 read task %0d, expected 2", id);
    repeat (20) @(posedge clk_i);
    if (up_core0_got) $error("[UNPARK] core 0 got task %0d while task 2 was still on core 1", up_core0_id);
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b1) $error("[UNPARK] left PARKED with a task still on core 1");
    csr_done(0, 0, 1, 2);
    fork : wait_core0
        wait (up_core0_got);
        begin
            repeat (200) @(posedge clk_i);
            $error("[UNPARK] core 0 did not get task 3 after the move back");
        end
    join_any
    disable wait_core0;
    if (up_core0_id[TaskIdWidth-1:0] != 3) $error("[UNPARK] core 0 read task %0d, expected 3", up_core0_id);
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0 || gen_dut[0].i_dut.park.unpark[0][0] !== 1'b0)
        $error("[UNPARK] still parked after the move back");
    csr_done(0, 0, 0, 3);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 11) $error("[UNPARK] core 1 read task %0d, expected its own 11", id);
    csr_done(0, 0, 1, 11);
    $display("Unpark test passed");
    $finish;
end
