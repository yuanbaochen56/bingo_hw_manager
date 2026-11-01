// =============================================================================
// Move back cancelled, and a move back with nothing left elsewhere
// =============================================================================
// Two cores of one type, driven by the stimulus. Core 0 is parked onto core 1
// and gets task 1 (core 1 runs it). The request is cleared (UNPARK) and set
// again before task 1 retires: the slot stays PARKED and task 2 goes to core 1
// as well. After both retired, clearing the request moves core 0 back at once
// (nothing left on core 1), and task 3 runs on core 0.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

initial begin : unpark_cancel_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    park_req[0] = 32'd1;
    repeat (10) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b1) $fatal(1, "core 0 not parked");
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 1) $fatal(1, "core 1 read task %0d, expected 1", id);
    @(negedge clk_i);
    park_req[0] = 32'd0;
    repeat (5) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.unpark[0][0] !== 1'b1) $error("[UNPARK_CANCEL] no UNPARK");
    @(negedge clk_i);
    park_req[0] = 32'd1;
    repeat (3) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.unpark[0][0] !== 1'b0 || gen_dut[0].i_dut.park.parked[0][0] !== 1'b1)
        $error("[UNPARK_CANCEL] asked again: expected PARKED (unpark %0b parked %0b)",
               gen_dut[0].i_dut.park.unpark[0][0], gen_dut[0].i_dut.park.parked[0][0]);
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    csr_done(0, 0, 1, 1);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 2) $error("[UNPARK_CANCEL] core 1 read task %0d, expected 2", id);
    csr_done(0, 0, 1, 2);
    repeat (10) @(posedge clk_i);
    @(negedge clk_i);
    park_req[0] = 32'd0;
    repeat (5) @(posedge clk_i);
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $error("[UNPARK_CANCEL] nothing left on core 1, still parked");
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 3, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    csr_read(0, 0, 0, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 3) $error("[UNPARK_CANCEL] core 0 read task %0d, expected 3", id);
    csr_done(0, 0, 0, 3);
    $display("Unpark cancel test passed");
    $finish;
end
