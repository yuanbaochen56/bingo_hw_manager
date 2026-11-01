// =============================================================================
// External access wake
// =============================================================================
// One chiplet, 2 clusters x 3 cores, the slots of cluster c in power domain
// 1 + c (idle 25, normal 6), access hold AW_HOLD cycles, idle entry delay
// AW_DELAY (0, or 1000 in the _delay variant). Cores driven by the stimulus;
// core k has type k + 1 in both clusters, substitutes on levels 1 and 2.
//   1. All cores poll: both domains reach the idle level (after the delay).
//   2. Accesses into cluster 0, one every 100 cycles for 20 accesses: domain 1
//      is back at the normal level a few cycles after the first one and stays
//      there until the last; domain 2 stays idle.
//   3. After the last access domain 1 drops again: not before AW_HOLD cycles,
//      and with an idle entry delay not later either (the cores have been
//      polling far longer than the delay).
//   4. Every core of cluster 0 takes a task (1..3) and dies (no heartbeat):
//      they are fenced and the tasks replayed on the cores of cluster 1 (which
//      keep sending heartbeats). Cluster 0, all of it fenced, drops to idle; an
//      access still wakes it (its memory may hold data the substitutes read).

localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int unsigned AW_HOLD  = `TB_PM_ACCESS_HOLD;
localparam int unsigned AW_DELAY = `TB_PM_IDLE_DELAY;
localparam int unsigned AW_PM_WRITE = 20;     // > cycles of one level change (PM bus writes)

logic [7:0]            aw_level [2];
int unsigned           aw_taken = 0;    // tasks taken by the cores of cluster 0
assign aw_level[0] = gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[1];
assign aw_level[1] = gen_dut[0].i_dut.i_bingo_hw_manager_pm.current_power_level_q[2];

// Cycles until domain (cluster) cl reaches level lvl, at most limit
task automatic aw_cycles_to(input int cl, input int unsigned lvl, input int unsigned limit,
                            output int unsigned n);
    n = 0;
    while ((aw_level[cl] != lvl) && (n < limit)) begin
        @(posedge clk_i);
        n++;
    end
    if (aw_level[cl] != lvl) $error("[ACCESS_WAKE] domain of cluster %0d not at level %0d after %0d cycles", cl, lvl, limit);
endtask

// One-cycle access into cluster cl
task automatic aw_access(input int cl);
    @(negedge clk_i);
    cluster_access[0][cl] = 1'b1;
    @(negedge clk_i);
    cluster_access[0][cl] = 1'b0;
endtask

initial begin : pm_access_wake_test
    automatic axi_pkg::resp_t resp;
    automatic int unsigned n;
    wait (rst_ni);
    for (int cl = 0; cl < 2; cl++) begin   // every core polls
        for (int c = 0; c < 3; c++) begin
            fork
                automatic int fcl = cl, fc = c;
                automatic device_axi_lite_data_t fid;
                begin
                    csr_read(0, fcl, fc, CSR_READY, fid);
                    if (fcl == 0) aw_taken++;                                  // and dies
                    else forever busy_with_heartbeat(0, fcl, fc, 1000, 50);  // a replayed task
                end
            join_none
        end
    end

    // 1. both domains idle
    aw_cycles_to(0, PM_IDLE_LEVEL, AW_DELAY + 1000, n);
    if (n < AW_DELAY) $error("[ACCESS_WAKE] idle after %0d cycles, delay is %0d", n, AW_DELAY);
    aw_cycles_to(1, PM_IDLE_LEVEL, 1000, n);

    // 2. accesses into cluster 0 keep domain 1 at the normal level
    fork
        for (int k = 0; k < 20; k++) begin
            aw_access(0);
            repeat (99) @(posedge clk_i);
        end
        begin
            aw_cycles_to(0, PM_NORMAL_LEVEL, AW_PM_WRITE, n);
            for (int t = 0; t < 1800; t++) begin
                @(posedge clk_i);
                if (aw_level[0] != PM_NORMAL_LEVEL) $error("[ACCESS_WAKE] domain 1 at level %0d while accessed", aw_level[0]);
            end
        end
        for (int t = 0; t < 2000; t++) begin
            @(posedge clk_i);
            if (aw_level[1] != PM_IDLE_LEVEL) $error("[ACCESS_WAKE] domain 2 woken by an access to cluster 0");
        end
    join
    // 3. idle again only after the hold (about 100 cycles of it have passed)
    aw_cycles_to(0, PM_IDLE_LEVEL, AW_HOLD + AW_PM_WRITE, n);
    if (n + 100 < AW_HOLD) $error("[ACCESS_WAKE] idle %0d cycles after the last access, hold is %0d", n + 100, AW_HOLD);
    $display("[ACCESS_WAKE] %0t idle again %0d cycles after the last access", $time, n + 100);

    // 4. a fully fenced cluster still wakes up when it is accessed
    for (int c = 0; c < 3; c++) begin
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, 1 + c, 0, 0, c, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    end
    wait (aw_taken == 3);
    fork : aw_wait_fence
        wait (gen_dut[0].i_dut.core_fenced[0][0] && gen_dut[0].i_dut.core_fenced[1][0] &&
              gen_dut[0].i_dut.core_fenced[2][0]);
        begin
            repeat (20000) @(posedge clk_i);
            $error("[ACCESS_WAKE] the cores of cluster 0 were not all fenced");
        end
    join_any
    disable aw_wait_fence;
    aw_cycles_to(0, PM_IDLE_LEVEL, AW_DELAY + 1000, n);
    aw_access(0);
    aw_cycles_to(0, PM_NORMAL_LEVEL, AW_PM_WRITE, n);
    aw_cycles_to(0, PM_IDLE_LEVEL, AW_HOLD + AW_PM_WRITE + 10, n);
    if (n < AW_HOLD - AW_PM_WRITE) $error("[ACCESS_WAKE] fenced cluster idle %0d cycles after its access, hold is %0d", n, AW_HOLD);
    $display("External access wake test passed");
    $finish;
end
