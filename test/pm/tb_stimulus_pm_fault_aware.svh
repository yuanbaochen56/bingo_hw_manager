// =============================================================================
// Fault-aware power management
// =============================================================================
// One cluster, all slots in power domain 1, idle PM on (idle level 25, normal
// level 6). Task 1 hangs core 0; tasks 2, 3 (cores 1, 2) complete, after which
// cores 1 and 2 poll again.
// EXPECTED:
// - while core 0 is only dead_suspect, the domain stays at the normal level (a
//   slow core may still be working) and it counts one pending task;
// - once core 0 is fenced, the domain drops to the idle level (a dead core does
//   not keep it awake) and its pending count is cleared.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t pt [4];
initial begin
    for (int i = 1; i <= 3; i++) begin
        pt[i] = pack_normal_task(2'b00, i, 0, 0, i - 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
end

function automatic int unsigned pm_level();
    return gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1];
endfunction

initial begin : pm_fault_aware_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 3; i++) task_queue_master[0].write(task_queue_base[0], '0, pt[i], '1, resp);
    wait (task_completed_bitmap[2] && task_completed_bitmap[3]);
    // dead_suspect, not fenced yet
    wait (gen_dut[0].i_dut.core_dead_suspect[0][0] === 1'b1);
    repeat (50) @(posedge clk_i);
    if (fenced_export[0] !== 3'b000) $error("[PM_FAULT] core 0 fenced too early");
    if (pm_level() != PM_NORMAL_LEVEL) $error("[PM_FAULT] suspect core: domain level %0d, expected %0d", pm_level(), PM_NORMAL_LEVEL);
    if (gen_dut[0].i_dut.load_total_pending_o != 1) $error("[PM_FAULT] suspect core: pending %0d, expected 1", gen_dut[0].i_dut.load_total_pending_o);
    // fenced
    wait (fenced_export[0] === 3'b001);
    repeat (50) @(posedge clk_i);
    if (pm_level() != PM_IDLE_LEVEL) $error("[PM_FAULT] fenced core: domain level %0d, expected %0d", pm_level(), PM_IDLE_LEVEL);
    if (gen_dut[0].i_dut.load_total_pending_o != 0) $error("[PM_FAULT] fenced core: pending %0d, expected 0", gen_dut[0].i_dut.load_total_pending_o);
    if (gen_dut[0].i_dut.replay_stuck !== 1'b1) $error("[PM_FAULT] core 0 must be stuck (no substitute)");
    $display("Fault-aware PM test passed");
    $finish;
end
