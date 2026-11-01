// =============================================================================
// Chiplet done-queue mailbox: other chiplets may only write MBOXW
// =============================================================================
// Two chiplets, 1 cluster, 3 cores. Dummy set 21 on chiplet 1 (core 1) sets
// row 0 / column 1 of chiplet 0 through chiplet 0's chiplet done queue; task 1
// on chiplet 0 (core 0) waits for it.
// The queue is held (pop forced low) until that dep set sits in it; then the
// h2h probe writes WIRQT .. CTRL of the mailbox (CTRL = 3 would flush it).
// EXPECTED: every write answers SLVERR, the held dep set survives, task 1 runs
// (with writable registers the flush loses it and task 1 never runs).

localparam int unsigned EXPECTED_TASK_COUNT     = 1;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t chip0_consumer = pack_normal_task(
    1'b0, 16'd1, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(3'b010),               // column 1 (core 1)
    1'b0, 1'b0, 0, 0, '0
);
bingo_hw_manager_task_desc_full_t chip1_set_chip0 = pack_dummy_set_task(
    1'b1, 16'd21, 1, 0, 1,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b001)    // chiplet 0, row 0
);

initial begin : probe
    automatic axi_pkg::resp_t resp;
    automatic host_axi_lite_addr_t base;
    force gen_dut[0].i_dut.i_chiplet_link.chiplet_done_queue_mbox_pop = 1'b0;
    wait (rst_ni);
    @(posedge clk_i);
    base = {chip_id[0], H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]};
    task_queue_master[0].write(task_queue_base[0], '0, chip0_consumer, '1, resp);
    task_queue_master[1].write(task_queue_base[1], '0, chip1_set_chip0, '1, resp);
    fork : wait_dep_set
        wait (!gen_dut[0].i_dut.i_chiplet_link.chiplet_done_queue_mbox_empty);
        begin
            repeat (2000) @(posedge clk_i);
            $error("[MBOX_RO] the dep set of chiplet 1 never reached chiplet 0's done queue");
        end
    join_any
    disable wait_dep_set;
    repeat (20) @(posedge clk_i);                             // its B is back at chiplet 1
    h2h_probe_en = 1'b1;
    for (int r = 4; r <= 9; r++) begin                        // WIRQT .. CTRL
        h2h_probe_master.write(base + host_axi_lite_addr_t'(r * HOST_DW / 8), '0, host_axi_lite_data_t'(3), '1, resp);
        if (resp != axi_pkg::RESP_SLVERR) $error("[MBOX_RO] register %0d write answered %0d", r, resp);
    end
    h2h_probe_en = 1'b0;
    if (gen_dut[0].i_dut.i_chiplet_link.chiplet_done_queue_mbox_empty) $error("[MBOX_RO] the held dep set was flushed");
    release gen_dut[0].i_dut.i_chiplet_link.chiplet_done_queue_mbox_pop;
    $display("[MBOX_RO] %0t probe writes done", $time);
end
