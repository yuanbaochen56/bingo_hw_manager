// =============================================================================
// Chiplet dep-set write: the write data is the whole descriptor of the task
// that sets the dependency (class bits cleared), with no unknown bit
// =============================================================================
// Two chiplets, 1 cluster, 3 cores. Dummy set 21 on chiplet 1 (core 1), with
// conditional-execution fields that are not 0, sets row 0 / column 1 of
// chiplet 0; task 1 on chiplet 0 (core 0) waits for it.
// EXPECTED: chiplet 1 sends exactly one dep-set write; its data equals task 21
// bit by bit (before the fix, is_exit and cond_exec_* were undriven), and
// task 1 runs.

localparam int unsigned EXPECTED_TASK_COUNT     = 1;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t chip0_consumer = pack_normal_task(
    1'b0, 16'd1, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(3'b010),               // column 1 (core 1)
    1'b0, 1'b0, 0, 0, '0
);
function automatic bingo_hw_manager_task_desc_full_t chip1_setter();
    bingo_hw_manager_task_desc_full_t t;
    t = pack_dummy_set_task(
        1'b1, 16'd21, 1, 0, 1,
        1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b001) // chiplet 0, row 0
    );
    t.cond_exec_group_id = 5'd21;
    return t;
endfunction
bingo_hw_manager_task_desc_full_t chip1_set_chip0 = chip1_setter();

int unsigned dep_set_writes = 0;
always @(negedge clk_i) begin : check_dep_set_data
    if (rst_ni && gen_dut[1].i_dut.to_remote_chiplet_axi_lite_req_o.w_valid) begin
        if ($isunknown(gen_dut[1].i_dut.to_remote_chiplet_axi_lite_req_o.w.data))
            $error("[DEP_SET_DATA] %0t write data %h has unknown bits", $time,
                   gen_dut[1].i_dut.to_remote_chiplet_axi_lite_req_o.w.data);
        else if (gen_dut[1].i_dut.to_remote_chiplet_axi_lite_req_o.w.data !== host_axi_lite_data_t'(chip1_set_chip0))
            $error("[DEP_SET_DATA] %0t write data %h, expected the descriptor %h", $time,
                   gen_dut[1].i_dut.to_remote_chiplet_axi_lite_req_o.w.data, host_axi_lite_data_t'(chip1_set_chip0));
        if (gen_dut[1].i_dut.to_remote_chiplet_axi_lite_resp_i.w_ready) dep_set_writes++;
    end
end

initial begin : stimulus
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].write(task_queue_base[0], '0, chip0_consumer, '1, resp);
    task_queue_master[1].write(task_queue_base[1], '0, chip1_set_chip0, '1, resp);
end

final begin
    if (dep_set_writes != 1) $error("[DEP_SET_DATA] %0d dep-set writes of chiplet 1, expected 1", dep_set_writes);
    else $display("[DEP_SET_DATA] one dep-set write, data = descriptor %h", host_axi_lite_data_t'(chip1_set_chip0));
end
