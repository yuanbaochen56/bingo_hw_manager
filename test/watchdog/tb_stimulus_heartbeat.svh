// =============================================================================
// Top-level CSR heartbeat path test
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

initial begin : heartbeat_path_test
    automatic bit heartbeat_seen;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    heartbeat_seen = 1'b0;

    fork
        begin
            wait (gen_dut[0].i_dut.heartbeat_valid[0][0] === 1'b1);
            heartbeat_seen = 1'b1;
        end
    join_none

    // Send heartbeat CSR write from chip 0, cluster 0, core 0. Keep this in
    // the main thread so the task can complete and deassert csr_req_valid.
    csr_write(0, 0, 0, CSR_HEARTBEAT, device_axi_lite_data_t'(32'h0000_1234));
    repeat (2) @(posedge clk_i);
    disable fork;

    if (!heartbeat_seen) begin
        $fatal(1, "heartbeat_valid[0][0] did not assert during CSR heartbeat write");
    end

    #1;

    if (gen_dut[0].i_dut.heartbeat_valid[0][0] !== 1'b0) begin
        $fatal(1, "heartbeat_valid[0][0] should deassert after CSR heartbeat write completes");
    end

    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "core 0 should not be dead_suspect after heartbeat");
    end

    $display("Top-level CSR heartbeat path test passed");
    $finish;
end
