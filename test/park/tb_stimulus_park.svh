// =============================================================================
// Park a live core that still has a task in flight
// =============================================================================
// Two cores, one cluster, same type. Core 0 has taken task 1 when the host
// requests a park. Task 1 still completes on core 0. Task 2, pushed while the
// slot is in HOLD, and task 3, pushed after PARKED, both run on core 1, and
// the three retire in order. Core 0 is not fenced.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t park_task_1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t park_task_2 = pack_normal_task(
    2'b00, 16'd2, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
bingo_hw_manager_task_desc_full_t park_task_3 = pack_normal_task(
    2'b00, 16'd3, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);

initial begin : park_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    automatic bit core1_got;
    automatic device_axi_lite_data_t core1_id;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    task_queue_master[0].write(task_queue_base[0], '0, park_task_1, '1, resp);
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
    fork : wait_hold
        wait (gen_dut[0].i_dut.park.hold[0][0] === 1'b1);
        begin
            repeat (50) @(posedge clk_i);
            $fatal(1, "core 0 did not enter HOLD");
        end
    join_any
    disable wait_hold;
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $fatal(1, "PARKED before the in-flight task drained");

    task_queue_master[0].write(task_queue_base[0], '0, park_task_2, '1, resp);
    busy_with_heartbeat(0, 0, 0, 80, 20);
    if (core1_got) $fatal(1, "task %0d reached core 1 while core 0 still held task 1", core1_id);
    if (gen_dut[0].i_dut.core_fenced[0][0] !== 1'b0) $fatal(1, "core 0 was fenced during the park");
    if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0) $fatal(1, "PARKED while task 1 was still in flight");

    csr_done(0, 0, 0, 1);
    fork : wait_parked
        wait (gen_dut[0].i_dut.park.parked[0][0] === 1'b1);
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "core 0 did not become PARKED (hold %0b fail %0b)",
                   gen_dut[0].i_dut.park.hold[0][0], gen_dut[0].i_dut.park.fail[0][0]);
        end
    join_any
    disable wait_parked;
    if (park_fail[0][0] !== 1'b0) $fatal(1, "park failed with a live substitute");
    if (gen_dut[0].i_dut.smt.core[0][0] !== 1) $fatal(1, "SMT sent core 0 to core %0d", gen_dut[0].i_dut.smt.core[0][0]);

    fork : wait_task2
        wait (core1_got);
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "core 1 did not receive task 2");
        end
    join_any
    disable wait_task2;
    if (core1_id[TaskIdWidth-1:0] !== 2) $fatal(1, "core 1 read task %0d, expected 2", core1_id);
    if (checkout_empty_export[0][0][0] !== 1'b1) $fatal(1, "core 0 checkout was not empty after the park");
    if (ready_empty_export[0][0][0] !== 1'b1) $fatal(1, "core 0 ready queue was not empty after the park");

    csr_done(0, 0, 1, 2);
    task_queue_master[0].write(task_queue_base[0], '0, park_task_3, '1, resp);
    csr_read(0, 0, 1, CSR_READY, id);
    if (id[TaskIdWidth-1:0] !== 3) $fatal(1, "core 1 read task %0d, expected 3", id);
    if (checkout_empty_export[0][0][0] !== 1'b1 || ready_empty_export[0][0][0] !== 1'b1) begin
        $fatal(1, "task 3 entered core 0 after it was parked");
    end
    csr_done(0, 0, 1, 3);

    if (gen_dut[0].i_dut.core_fenced[0][0] !== 1'b0) $fatal(1, "parked core 0 was fenced");
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] !== 1'b0) $fatal(1, "parked core 0 was dead_suspect");
    if (remap_count[0] < 2) $fatal(1, "expected two remapped tasks, got %0d", remap_count[0]);
    $display("Core parking test passed");
    $finish;
end
