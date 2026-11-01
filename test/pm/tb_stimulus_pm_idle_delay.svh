// =============================================================================
// Idle entry delay
// =============================================================================
// One cluster, all slots in power domain 1 (idle 25, normal 6), idle entry
// delay 500 cycles, cores driven by the stimulus (they poll when not working).
//   1. All cores poll: the domain reaches the idle level, but only after 500
//      cycles of polling.
//   2. Core 0 runs task 1, then polls for 200 cycles (shorter than the delay)
//      before task 2 arrives: the domain stays at the normal level.
//   3. After task 2 every core polls: the idle level comes back only after
//      another 500 cycles.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

logic [7:0] id_level;
assign id_level = gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1];

function automatic bingo_hw_manager_task_desc_full_t id_task(input int unsigned tid);
    return pack_normal_task(2'b00, tid, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
endfunction

// Cycles until the domain reaches the idle level
task automatic id_cycles_to_idle(output int unsigned n);
    n = 0;
    while (id_level != PM_IDLE_LEVEL) begin
        @(posedge clk_i);
        n++;
    end
endtask

initial begin : pm_idle_delay_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id, id_other;
    automatic int unsigned n;
    wait (rst_ni);
    fork   // cores 1 and 2 poll for good
        csr_read(0, 0, 1, CSR_READY, id_other);
        csr_read(0, 0, 2, CSR_READY, id_other);
    join_none
    // 1. idle level only after the delay
    fork
        csr_read(0, 0, 0, CSR_READY, id);                      // returns task 1
        begin
            id_cycles_to_idle(n);
            if (n < 500) $error("[IDLE_DELAY] idle level after %0d polling cycles, delay is 500", n);
            task_queue_master[0].write(task_queue_base[0], '0, id_task(1), '1, resp);
        end
    join
    if (id[TaskIdWidth-1:0] != 1) $error("[IDLE_DELAY] core 0 got task %0d, expected 1", id[TaskIdWidth-1:0]);
    wait (id_level == PM_NORMAL_LEVEL);
    repeat (100) @(posedge clk_i);
    csr_done(0, 0, 0, 1);
    // 2. a 200-cycle polling gap keeps the normal level
    fork
        csr_read(0, 0, 0, CSR_READY, id);                      // returns task 2
        begin
            for (int unsigned i = 0; i < 200; i++) begin
                @(posedge clk_i);
                if (id_level != PM_NORMAL_LEVEL) $error("[IDLE_DELAY] level %0d during a short gap", id_level);
            end
            task_queue_master[0].write(task_queue_base[0], '0, id_task(2), '1, resp);
        end
    join
    if (id[TaskIdWidth-1:0] != 2) $error("[IDLE_DELAY] core 0 got task %0d, expected 2", id[TaskIdWidth-1:0]);
    repeat (100) @(posedge clk_i);
    csr_done(0, 0, 0, 2);
    // 3. idle again only after the delay
    fork
        csr_read(0, 0, 0, CSR_READY, id);                      // never returns
    join_none
    id_cycles_to_idle(n);
    if (n < 500) $error("[IDLE_DELAY] idle level %0d cycles after the last task, delay is 500", n);
    $display("Idle entry delay test passed");
    $finish;
end
