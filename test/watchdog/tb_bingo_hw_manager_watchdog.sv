`timescale 1ns/1ps
`include "bingo_hw_manager/typedef.svh"

module tb_bingo_hw_manager_watchdog;

    localparam int unsigned NUM_CORES     = 2;
    localparam int unsigned NUM_CLUSTERS  = 1;
    localparam int unsigned COUNTER_WIDTH = 8;
    localparam int unsigned TIMEOUT       = 4;
    localparam int unsigned CONFIRM       = 8;

    logic clk_i;
    logic rst_ni;

    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] task_dispatched_i;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] task_done_i;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] heartbeat_i;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] waiting_task_i;

    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_busy_o;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_available_o;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_dead_suspect_o;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_fenced_o;

    // Port structs of the watchdog: every slot ticks, no threshold but the parameters
    `BINGO_HW_MANAGER_TYPEDEF_WD_EVENT_T(wd_event_t, NUM_CORES, NUM_CLUSTERS)
    `BINGO_HW_MANAGER_TYPEDEF_WD_BOUND_T(wd_bound_t, NUM_CORES, NUM_CLUSTERS, COUNTER_WIDTH, 3)
    `BINGO_HW_MANAGER_TYPEDEF_WD_STATUS_T(wd_status_t, NUM_CORES, NUM_CLUSTERS, COUNTER_WIDTH)
    wd_event_t  wd_event;
    wd_status_t wd_status, wd_status_masked, wd_status_f;
    // The thresholds bingo_hw_manager_wd_bounds gives without any CSR: the parameters
    wd_bound_t  wd_bound_params;
    assign wd_bound_params = '{suspect_eff: {(NUM_CORES * NUM_CLUSTERS){COUNTER_WIDTH'(TIMEOUT)}},
                               confirm_eff: {(NUM_CORES * NUM_CLUSTERS){COUNTER_WIDTH'(CONFIRM)}},
                               default: '0};
    assign wd_event = '{dispatch: task_dispatched_i, done: task_done_i, heartbeat: heartbeat_i,
                        waiting: waiting_task_i, tick: '1};
    assign core_busy_o         = wd_status.busy;
    assign core_available_o    = wd_status.available;
    assign core_dead_suspect_o = wd_status.dead_suspect;
    assign core_fenced_o       = wd_status.fenced;

    bingo_hw_manager_watchdog #(
        .NumCores(NUM_CORES),
        .NumClusters(NUM_CLUSTERS),
        .CounterWidth(COUNTER_WIDTH),
        .HeartbeatTimeoutCycles(TIMEOUT),
        .wd_event_t(wd_event_t),
        .wd_bound_t(wd_bound_t),
        .wd_status_t(wd_status_t)
    ) dut (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .event_i(wd_event),
        .bound_i(wd_bound_params),
        .status_o(wd_status)
    );

    // Same stimulus, but core 0 excluded from monitoring (CoreMask[core][cluster]).
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_busy_masked;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_dead_suspect_masked;

    assign core_busy_masked         = wd_status_masked.busy;
    assign core_dead_suspect_masked = wd_status_masked.dead_suspect;

    bingo_hw_manager_watchdog #(
        .NumCores(NUM_CORES),
        .NumClusters(NUM_CLUSTERS),
        .CounterWidth(COUNTER_WIDTH),
        .HeartbeatTimeoutCycles(TIMEOUT),
        .CoreMask(2'b10),
        .wd_event_t(wd_event_t),
        .wd_bound_t(wd_bound_t),
        .wd_status_t(wd_status_t)
    ) dut_masked (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .event_i(wd_event),
        .bound_i(wd_bound_params),
        .status_o(wd_status_masked)
    );

    // Same stimulus, with the confirm timeout enabled (fencing).
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_busy_f;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_available_f;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_dead_suspect_f;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_fenced_f;

    assign core_busy_f         = wd_status_f.busy;
    assign core_available_f    = wd_status_f.available;
    assign core_dead_suspect_f = wd_status_f.dead_suspect;
    assign core_fenced_f       = wd_status_f.fenced;

    bingo_hw_manager_watchdog #(
        .NumCores(NUM_CORES),
        .NumClusters(NUM_CLUSTERS),
        .CounterWidth(COUNTER_WIDTH),
        .HeartbeatTimeoutCycles(TIMEOUT),
        .ConfirmTimeoutCycles(CONFIRM),
        .wd_event_t(wd_event_t),
        .wd_bound_t(wd_bound_t),
        .wd_status_t(wd_status_t)
    ) dut_fence (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .event_i(wd_event),
        .bound_i(wd_bound_params),
        .status_o(wd_status_f)
    );

    initial clk_i = 1'b0;
    always #5 clk_i = ~clk_i;

    task automatic clear_inputs;
    begin
        task_dispatched_i = '0;
        task_done_i       = '0;
        heartbeat_i       = '0;
        waiting_task_i    = '0;
    end
    endtask

    task automatic tick(input int unsigned cycles = 1);
    begin
        repeat (cycles) @(posedge clk_i);
        #1;
    end
    endtask

    task automatic pulse_dispatch(input int unsigned core);
    begin
        task_dispatched_i = '0;
        task_dispatched_i[core][0] = 1'b1;
        @(posedge clk_i);
        #1;
        task_dispatched_i[core][0] = 1'b0;
    end
    endtask

    task automatic pulse_done(input int unsigned core);
    begin
        task_done_i = '0;
        task_done_i[core][0] = 1'b1;
        @(posedge clk_i);
        #1;
        task_done_i[core][0] = 1'b0;
    end
    endtask

    task automatic pulse_heartbeat(input int unsigned core);
    begin
        heartbeat_i = '0;
        heartbeat_i[core][0] = 1'b1;
        @(posedge clk_i);
        #1;
        heartbeat_i[core][0] = 1'b0;
    end
    endtask

    task automatic expect_core_state(
        input int unsigned core,
        input logic expected_busy,
        input logic expected_available,
        input logic expected_dead
    );
    begin
        if (core_busy_o[core][0] !== expected_busy) begin
            $error("core %0d busy mismatch: expected %0b got %0b",
                   core, expected_busy, core_busy_o[core][0]);
        end
        if (core_available_o[core][0] !== expected_available) begin
            $error("core %0d available mismatch: expected %0b got %0b",
                   core, expected_available, core_available_o[core][0]);
        end
        if (core_dead_suspect_o[core][0] !== expected_dead) begin
            $error("core %0d dead_suspect mismatch: expected %0b got %0b",
                   core, expected_dead, core_dead_suspect_o[core][0]);
        end
    end
    endtask

    // Fencing instance: busy / dead_suspect / fenced of one core.
    task automatic expect_fence_state(
        input int unsigned core,
        input logic expected_busy,
        input logic expected_dead,
        input logic expected_fenced
    );
    begin
        if (core_busy_f[core][0] !== expected_busy) begin
            $error("[fence] core %0d busy mismatch: expected %0b got %0b",
                   core, expected_busy, core_busy_f[core][0]);
        end
        if (core_dead_suspect_f[core][0] !== expected_dead) begin
            $error("[fence] core %0d dead_suspect mismatch: expected %0b got %0b",
                   core, expected_dead, core_dead_suspect_f[core][0]);
        end
        if (core_fenced_f[core][0] !== expected_fenced) begin
            $error("[fence] core %0d fenced mismatch: expected %0b got %0b",
                   core, expected_fenced, core_fenced_f[core][0]);
        end
    end
    endtask

    initial begin
        clear_inputs();

        rst_ni = 1'b0;
        repeat (2) @(posedge clk_i);
        rst_ni = 1'b1;
        tick();

        $display("Checking reset state");
        expect_core_state(0, 1'b0, 1'b0, 1'b0);
        expect_core_state(1, 1'b0, 1'b0, 1'b0);

        $display("Marking both cores as waiting for tasks");
        waiting_task_i[0][0] = 1'b1;
        waiting_task_i[1][0] = 1'b1;
        tick();
        expect_core_state(0, 1'b0, 1'b1, 1'b0);
        expect_core_state(1, 1'b0, 1'b1, 1'b0);

        $display("Dispatching task to core 0");
        pulse_dispatch(0);
        expect_core_state(0, 1'b1, 1'b0, 1'b0);
        expect_core_state(1, 1'b0, 1'b1, 1'b0);

        $display("Heartbeat should keep core 0 alive during a long run");
        tick(TIMEOUT - 1);
        expect_core_state(0, 1'b1, 1'b0, 1'b0);
        pulse_heartbeat(0);
        expect_core_state(0, 1'b1, 1'b0, 1'b0);

        $display("Letting the timeout expire without heartbeat");
        tick(TIMEOUT - 1);
        expect_core_state(0, 1'b1, 1'b0, 1'b0);
        tick(1);
        expect_core_state(0, 1'b1, 1'b0, 1'b1);
        expect_core_state(1, 1'b0, 1'b1, 1'b0);

        $display("Masked core is still tracked as busy but never reported dead");
        if (core_busy_masked[0][0] !== 1'b1) begin
            $error("masked core 0 busy mismatch: expected 1 got %0b", core_busy_masked[0][0]);
        end
        if (core_dead_suspect_masked[0][0] !== 1'b0) begin
            $error("masked core 0 must never be dead_suspect, got %0b", core_dead_suspect_masked[0][0]);
        end

        $display("Fencing instance: suspect but not yet fenced");
        expect_fence_state(0, 1'b1, 1'b1, 1'b0);

        $display("Done should clear busy and dead_suspect");
        pulse_done(0);
        expect_core_state(0, 1'b0, 1'b1, 1'b0);
        expect_core_state(1, 1'b0, 1'b1, 1'b0);
        expect_fence_state(0, 1'b0, 1'b0, 1'b0);

        $display("Heartbeat before the confirm timeout prevents fencing");
        pulse_dispatch(1);
        tick(CONFIRM - 1);
        expect_fence_state(1, 1'b1, 1'b1, 1'b0);
        pulse_heartbeat(1);
        expect_fence_state(1, 1'b1, 1'b0, 1'b0);
        tick(CONFIRM - 1);
        expect_fence_state(1, 1'b1, 1'b1, 1'b0);

        $display("A done in the cycle the confirm timeout is reached wins");
        tick(1);  // timer == CONFIRM: the next edge would fence
        expect_fence_state(1, 1'b1, 1'b1, 1'b0);
        pulse_done(1);
        expect_fence_state(1, 1'b0, 1'b0, 1'b0);

        $display("No heartbeat until the confirm timeout: fenced, sticky");
        pulse_dispatch(0);
        tick(CONFIRM);
        expect_fence_state(0, 1'b1, 1'b1, 1'b0);
        tick(1);
        expect_fence_state(0, 1'b0, 1'b1, 1'b1);
        if (core_available_f[0][0] !== 1'b0) begin
            $error("[fence] fenced core 0 must never be available");
        end
        if (core_fenced_o[0][0] !== 1'b0) begin
            $error("confirm timeout 0 must never fence, got %0b", core_fenced_o[0][0]);
        end
        pulse_done(0);
        expect_fence_state(0, 1'b0, 1'b1, 1'b1);
        pulse_heartbeat(0);
        pulse_dispatch(0);
        tick(2 * CONFIRM);
        expect_fence_state(0, 1'b0, 1'b1, 1'b1);
        expect_fence_state(1, 1'b0, 1'b0, 1'b0);

        $display("All watchdog tests passed");
        #10;
        $finish;
    end

    initial begin
        #10000;
        $fatal("TIMEOUT");
    end

endmodule
