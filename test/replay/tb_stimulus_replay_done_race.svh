// =============================================================================
// Replay: a done that races with the confirm timeout retires the task exactly once
// =============================================================================
// Cores 0-3 each run one task (1-4) without heartbeat and report done relative
// to the cycle their watchdog timer reaches the confirm timeout T2:
//   core 0: done seen in the cycle the timer is T2 -> done wins, not fenced
//   core 1: done seen one cycle earlier            -> not fenced
//   core 2: done one cycle after the fence         -> fenced, done dropped
//   core 3: done 5 cycles after the fence          -> fenced, done dropped
// Tasks 3 and 4 are replayed on core 0 (lowest live core). Every core serves
// its ready queue afterwards; core 4 is a spare.
// EXPECTED: each task retires exactly once; cores 2 and 3 fenced.

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int unsigned RACE_T2                 = WATCHDOG_CONFIRM_TIMEOUT;

// Serve the ready queue: short tasks, well below the heartbeat timeout.
task automatic serve(input int core);
    automatic device_axi_lite_data_t id;
    forever begin
        csr_read(0, 0, core, CSR_READY, id);
        repeat (2) @(posedge clk_i);
        csr_done(0, 0, core, id[TaskIdWidth-1:0]);
    end
endtask

task automatic race(input int core, input int mode);
    automatic device_axi_lite_data_t id;
    csr_read(0, 0, core, CSR_READY, id);
    case (mode)
        0: wait (gen_dut[0].i_dut.i_watchdog.timer_q[core][0] == RACE_T2);
        1: wait (gen_dut[0].i_dut.i_watchdog.timer_q[core][0] == RACE_T2 - 1);
        2: begin
            wait (gen_dut[0].i_dut.i_watchdog.timer_q[core][0] == RACE_T2);
            @(posedge clk_i);
        end
        default: begin
            wait (fenced_export[0][core][0] === 1'b1);
            repeat (5) @(posedge clk_i);
        end
    endcase
    csr_done(0, 0, core, id[TaskIdWidth-1:0]);
    serve(core);
endtask

initial begin : done_race_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);

    fork
        race(0, 0);
        race(1, 1);
        race(2, 2);
        race(3, 3);
        serve(4);
    join_none
    repeat (5) @(posedge clk_i);

    for (int unsigned t = 1; t <= 4; t++) begin
        automatic bingo_hw_manager_task_desc_full_t d = pack_normal_task(
            2'b00, bingo_hw_manager_task_id_t'(t), 0, 0, bingo_hw_manager_assigned_core_id_t'(t - 1),
            1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
        task_queue_master[0].write(task_queue_base[0], '0, d, '1, resp);
    end

    fork : wait_all
        begin
            wait (retire_count[0][1] == 1 && retire_count[0][2] == 1 &&
                  retire_count[0][3] == 1 && retire_count[0][4] == 1);
        end
        begin
            repeat (3000) @(posedge clk_i);
            dump_queue_state();
            $fatal(1, "[RACE] not all tasks retired");
        end
    join_any
    disable wait_all;
    repeat (50) @(posedge clk_i);

    if (fenced_export[0][0][0] !== 1'b0 || fenced_export[0][1][0] !== 1'b0) begin
        $error("[RACE] cores 0/1 reported done in time and must not be fenced");
    end
    if (fenced_export[0][2][0] !== 1'b1 || fenced_export[0][3][0] !== 1'b1) begin
        $error("[RACE] cores 2/3 missed the confirm timeout and must be fenced");
    end
    if (replay_move_count[0] != 2) $error("[RACE] expected 2 replayed entries, got %0d", replay_move_count[0]);
    if (fence_drop_count[0] != 2) $error("[RACE] expected 2 dropped dones, got %0d", fence_drop_count[0]);
    $display("Replay done-race test passed");
    $finish;
end
