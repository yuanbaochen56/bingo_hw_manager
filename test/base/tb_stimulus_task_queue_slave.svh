// =============================================================================
// Task queue slave mode (TASK_QUEUE_TYPE 0): the start reset outputs belong to
// the master mode (bingo_hw_manager_task_queue_master) and stay driven to 0
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT      = 999;
localparam int unsigned DEADLOCK_THRESHOLD       = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL  = 0;

initial begin : task_queue_slave_outputs
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    // One task through the slave queue, so the check covers a running manager
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    for (int unsigned cycle = 0; cycle < 200; cycle++) begin
        @(negedge clk_i);
        if ((gen_dut[0].i_dut.bingo_hw_manager_reset_start_o !== '0) ||
            (gen_dut[0].i_dut.bingo_hw_manager_reset_start_en_o !== 1'b0)) begin
            $fatal(1, "[TQ_SLAVE] start reset outputs %h / %b in slave mode, expected 0",
                   gen_dut[0].i_dut.bingo_hw_manager_reset_start_o,
                   gen_dut[0].i_dut.bingo_hw_manager_reset_start_en_o);
        end
    end
    $display("Task queue slave mode start reset outputs test passed");
    $finish;
end
