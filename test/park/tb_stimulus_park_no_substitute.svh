// =============================================================================
// Park request with no substitute
// =============================================================================
// Core 0 (type 1) is busy on task 1. Core 1 is type 2, so it cannot take over.
// After task 1 drains, HOLD drops, park_fail is set, and task 2 runs on core 0.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t park_ns_task_1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t park_ns_task_2 = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

initial begin : park_no_substitute_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    automatic device_axi_lite_data_t core1_id;
    automatic bit core1_got;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    task_queue_master[0].write(task_queue_base[0], '0, park_ns_task_1, '1, resp);
    csr_read(0, 0, 0, CSR_READY, id);
    if (id[TaskIdWidth-1:0] !== 1) $fatal(1, "core 0 read task %0d, expected 1", id);

    core1_got = 1'b0;
    fork
        begin
            csr_read(0, 0, 1, CSR_READY, core1_id);
            core1_got = 1'b1;
        end
    join_none

    @(negedge clk_i);
    park_req[0] = 32'd1;
    fork : wait_hold_ns
        wait (gen_dut[0].i_dut.park.hold[0][0] === 1'b1);
        begin
            repeat (50) @(posedge clk_i);
            $fatal(1, "core 0 did not enter HOLD");
        end
    join_any
    disable wait_hold_ns;

    task_queue_master[0].write(task_queue_base[0], '0, park_ns_task_2, '1, resp);
    busy_with_heartbeat(0, 0, 0, 40, 20);
    csr_done(0, 0, 0, 1);

    fork : wait_fail_ns
        wait (park_fail[0][0] === 1'b1);
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "park did not fail (hold %0b parked %0b internal %0b)",
                   gen_dut[0].i_dut.park.hold[0][0], gen_dut[0].i_dut.park.parked[0][0],
                   gen_dut[0].i_dut.park.fail[0][0]);
        end
    join_any
    disable wait_fail_ns;
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $fatal(1, "PARKED with no substitute");
    if (gen_dut[0].i_dut.park.hold[0][0] !== 1'b0) $fatal(1, "HOLD stayed set after the failure");

    csr_read(0, 0, 0, CSR_READY, id);
    if (id[TaskIdWidth-1:0] !== 2) $fatal(1, "core 0 read task %0d after the failed park, expected 2", id);
    if (core1_got) $fatal(1, "core 1 took a task of a different type");
    if (remap_count[0] != 0) $fatal(1, "a task left its logical core, remap_count %0d", remap_count[0]);
    csr_done(0, 0, 0, 2);
    $display("Core parking no-substitute test passed");
    $finish;
end
