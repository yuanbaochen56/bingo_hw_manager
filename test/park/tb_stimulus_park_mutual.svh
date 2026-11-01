// =============================================================================
// Two parks at once
// =============================================================================
// Three cores of one type, cores driven by the stimulus, no task yet. The host
// asks to park cores 0 and 1 in the same cycle. Neither may become the other's
// substitute (a slot in HOLD or PARKED is no candidate): both park onto core 2.
// Parking core 2 as well then fails at once (it runs both). Tasks of logical
// cores 0 and 1 run on core 2, in push order.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

initial begin : park_mutual_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    @(negedge clk_i);
    park_req[0] = 32'b011;
    repeat (10) @(posedge clk_i);
    for (int c = 0; c < 2; c++) begin
        if (gen_dut[0].i_dut.park.parked[c][0] !== 1'b1 || gen_dut[0].i_dut.smt.core[c][0] !== 2)
            $error("[PARK_MUTUAL] core %0d: parked %0b onto core %0d, expected core 2", c,
                   gen_dut[0].i_dut.park.parked[c][0], gen_dut[0].i_dut.smt.core[c][0]);
    end
    @(negedge clk_i);
    park_req[0] = 32'b111;
    repeat (5) @(posedge clk_i);
    if (park_fail[0][2] !== 1'b1 || gen_dut[0].i_dut.park.hold[2][0] !== 1'b0)
        $error("[PARK_MUTUAL] parking core 2, which runs both parked cores, did not fail at once");
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 2, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    for (int k = 1; k <= 2; k++) begin
        csr_read(0, 0, 2, CSR_READY, id);
        if (id[TaskIdWidth-1:0] != k) $error("[PARK_MUTUAL] core 2 read task %0d, expected %0d", id, k);
        csr_done(0, 0, 2, k);
    end
    $display("Park mutual test passed");
    $finish;
end
