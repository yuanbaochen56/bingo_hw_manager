localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

bingo_hw_manager_task_desc_full_t long_task = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0, //task info
    1'b0, '0,  //check info
    1'b0, 1'b0, 0, 0, '0 // set info
);

initial begin : long_task_heartbeat_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t task_id_data;
    automatic bingo_hw_manager_done_info_full_t done_info;
    automatic device_axi_lite_data_t done_payload;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    task_queue_master[0].write(task_queue_base[0], '0, long_task, '1, resp);

    csr_read(0, 0, 0, CSR_READY, task_id_data);

    repeat (2) @(posedge clk_i);
    if (gen_dut[0].i_dut.wd_status.busy[0][0] !== 1'b1) begin
        $fatal(1, "core 0 should be busy after dispatch");
    end

    // Send heartbeat before timeout; core should stay not-dead.
    repeat (4) @(posedge clk_i);
    csr_write(0, 0, 0, CSR_HEARTBEAT, device_axi_lite_data_t'(32'h1));
    repeat (4) @(posedge clk_i);

    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "core 0 should not be dead_suspect while heartbeat arrives");
    end

    // Stop heartbeat and wait beyond timeout.
    repeat (10) @(posedge clk_i);

    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b1) begin
        $fatal(1, "core 0 should become dead_suspect without heartbeat");
    end

    done_info = '0;
    done_info.task_id = task_id_data[TaskIdWidth-1:0];
    done_info.assigned_cluster_id = bingo_hw_manager_assigned_cluster_id_t'(0);
    done_info.assigned_core_id = bingo_hw_manager_assigned_core_id_t'(0);
    done_payload = device_axi_lite_data_t'(done_info);

    csr_write(0, 0, 0, CSR_DONE, done_payload);

    repeat (2) @(posedge clk_i);

    if (gen_dut[0].i_dut.wd_status.busy[0][0] !== 1'b0) begin
        $fatal(1, "core 0 busy should clear after done");
    end

    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) begin
        $fatal(1, "core 0 dead_suspect should clear after done");
    end

    $display("Long-task heartbeat watchdog behavior test passed");
    $finish;
end