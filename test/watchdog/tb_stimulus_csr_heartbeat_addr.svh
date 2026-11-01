// =============================================================================
// HeMAiA CSR map: heartbeat = write to the ready CSR, masked watchdog slot
// =============================================================================
// With CsrHeartbeatAddr = 0x5fe, a read of 0x5fe pops the ready queue and a
// write of 0x5fe is a heartbeat (it must not reach the done queue). Core 2 is
// masked in WatchdogCoreMask and must never be reported dead_suspect.

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t hb_core0_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

bingo_hw_manager_task_desc_full_t hb_core2_task = pack_normal_task(
    2'b00, 16'd2, 0, 0, 2,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0
);

initial begin : csr_heartbeat_addr_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t task_id;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    if (CSR_HEARTBEAT !== CSR_READY) begin
        $fatal(1, "test expects the heartbeat on the ready CSR");
    end

    $display("[HB_ADDR] Core 0 reads task 1 through CSR 0x5fe");
    task_queue_master[0].write(task_queue_base[0], '0, hb_core0_task, '1, resp);
    csr_read(0, 0, 0, CSR_READY, task_id);
    if (task_id[TaskIdWidth-1:0] !== bingo_hw_manager_task_id_t'(1)) begin
        $fatal(1, "core 0 read wrong task id: expected 1 got %0d", task_id[TaskIdWidth-1:0]);
    end

    $display("[HB_ADDR] Heartbeats (writes to 0x5fe) keep core 0 alive");
    busy_with_heartbeat(0, 0, 0, 80, 8);
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "core 0 must stay alive while writing heartbeats to 0x5fe");
    end
    if (gen_dut[0].i_dut.done_q_empty[0][0] !== 1'b1) begin
        $fatal(1, "a heartbeat write must not enter the done queue");
    end

    $display("[HB_ADDR] Without heartbeats core 0 times out");
    repeat (30) @(posedge clk_i);
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b1) begin
        $fatal(1, "core 0 should be dead_suspect after the timeout");
    end
    csr_done(0, 0, 0, 1);
    repeat (2) @(posedge clk_i);
    if (gen_dut[0].i_dut.wd_status.busy[0][0] !== 1'b0 ||
        gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "done (0x5ff) should clear busy and dead_suspect");
    end

    $display("[HB_ADDR] Masked core 2 runs a long task without heartbeats");
    task_queue_master[0].write(task_queue_base[0], '0, hb_core2_task, '1, resp);
    csr_read(0, 0, 2, CSR_READY, task_id);
    repeat (100) @(posedge clk_i);
    if (gen_dut[0].i_dut.wd_status.busy[2][0] !== 1'b1) begin
        $fatal(1, "core 2 should be tracked as busy");
    end
    if (gen_dut[0].i_dut.core_dead_suspect[2][0] !== 1'b0) begin
        $fatal(1, "masked core 2 must never be dead_suspect");
    end
    csr_done(0, 0, 2, 2);

    $display("CSR heartbeat-address test passed");
    $finish;
end
