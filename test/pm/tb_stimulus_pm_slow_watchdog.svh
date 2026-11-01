// =============================================================================
// Frequency-aware watchdog
// =============================================================================
// One cluster, all slots in power domain 1 (idle level 25, normal level 6),
// heartbeat timeout 200 cycles, cores driven by the stimulus.
//   1. All cores poll: the domain goes to the idle level 25.
//   2. The PM bus is stalled, then core 0 takes task 1: the domain should go
//      back to level 6 but stays at 25, so core 0 runs 25/6 times slower. It
//      beats every 300 cycles, which is 72 cycles of the normal clock: no
//      dead_suspect (the timer advances 6/25 of the cycles).
//   3. The PM bus is released: the domain goes to level 6 and the same
//      300-cycle gaps now exceed the timeout: dead_suspect.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

function automatic int unsigned sw_level();
    return gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1];
endfunction

logic sw_suspect_seen = 1'b0;
always @(posedge clk_i) if (gen_dut[0].i_dut.core_dead_suspect[0][0] === 1'b1) sw_suspect_seen <= 1'b1;

initial begin : pm_slow_watchdog_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id;
    automatic bingo_hw_manager_task_desc_full_t t1 = pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    wait (rst_ni);
    // 1. every core polls
    fork
        csr_read(0, 0, 1, CSR_READY, id);
        csr_read(0, 0, 2, CSR_READY, id);
    join_none
    fork : read0
        csr_read(0, 0, 0, CSR_READY, id);
        begin
            wait (gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1] == PM_IDLE_LEVEL);
            // 2. freeze the level, then give core 0 its task
            repeat (10) @(posedge clk_i);
            pm_bus_stall = 1'b1;
            task_queue_master[0].write(task_queue_base[0], '0, t1, '1, resp);
            wait (0);
        end
    join_any
    disable read0;
    if (id[TaskIdWidth-1:0] != 1) $fatal(1, "[SLOW_WD] core 0 got task %0d", id[TaskIdWidth-1:0]);
    busy_with_heartbeat(0, 0, 0, 3000, 300);
    if (sw_level() != PM_IDLE_LEVEL) $error("[SLOW_WD] level %0d, expected the frozen idle level", sw_level());
    if (sw_suspect_seen) $error("[SLOW_WD] core 0 suspected while its domain runs at the idle level");
    // 3. the level goes back to normal: the same gaps are too long now
    pm_bus_stall = 1'b0;
    wait (gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1] == PM_NORMAL_LEVEL);
    busy_with_heartbeat(0, 0, 0, 1500, 300);
    if (!sw_suspect_seen) $error("[SLOW_WD] core 0 not suspected at the normal level with 300-cycle gaps");
    csr_done(0, 0, 0, 1);
    repeat (50) @(posedge clk_i);
    $display("Frequency-aware watchdog test passed");
    $finish;
end
