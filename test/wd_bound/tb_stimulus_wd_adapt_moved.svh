// =============================================================================
// Executions away from their own logical slot (BINGO_WD_LATE[6], [8:7])
// =============================================================================
// Two cores of type 1. Whether a task runs away from its own logical slot
// travels with it through the ready queue and is latched at dispatch
// (wd_moved_q). Core 0 learns class 3, then hangs on task 3: it is fenced,
// task 3 is replayed onto core 1, and task 4 of logical core 0 is remapped
// there. With BINGO_WD_LATE = 0x1c0 (bit 6 and a shift of 3) neither moved
// execution is learned and their thresholds come from 8 M; with 0
// (TB_WD_ADAPT_MOVED_OFF or +MOVED_OFF=1) both are learned as before. Task 5
// of core 1's own logical slot is learned either way.

localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
`ifndef TB_WD_ADAPT_MOVED_OFF
  `define TB_WD_ADAPT_MOVED_OFF 0
`endif
int moved_off, learned, m, h, c;

task automatic wait_drained(input int core);
    fork : drain_or_timeout
        begin
            wait (gen_dut[0].i_dut.checkout_queue_empty[core][0] &&
                  !gen_dut[0].i_dut.wd_status.busy[core][0]);
        end
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "[ADAPT_MOVED] checkout did not drain");
        end
    join_any
    disable drain_or_timeout;
endtask

task automatic expect_samples(input int n, input string what);
    if (gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples != n)
        $fatal(1, "[ADAPT_MOVED] %s: class 3 has %0d samples, expected %0d", what,
               gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].samples, n);
endtask

task automatic expect_moved(input int core, input bit moved, input int task_id, input device_axi_lite_data_t got);
    #1;
    if (got != task_id || gen_dut[0].i_dut.wd_moved_q[core][0] !== moved ||
        gen_dut[0].i_dut.wd_class_q[core][0] != 3)
        $fatal(1, "[ADAPT_MOVED] core %0d task %0d (expected %0d): moved %b class %0d, expected moved %b",
               core, got, task_id, gen_dut[0].i_dut.wd_moved_q[core][0],
               gen_dut[0].i_dut.wd_class_q[core][0], moved);
endtask

initial begin
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t got;
    automatic bingo_hw_manager_task_desc_full_t descriptor;
    wait (rst_ni);
    moved_off = `TB_WD_ADAPT_MOVED_OFF;
    void'($value$plusargs("MOVED_OFF=%d", moved_off));
    force gen_dut[0].i_dut.bingo_hw_manager_wd_late_i = moved_off ? 32'h0 : 32'h1c0;
    wd_type_h[0][1] = 200; wd_type_c[0][1] = 600;
    // EN, SH_H 1, SH_C 2, WARMUP 1, FLOOR 1: the learned term sets the thresholds
    wd_adapt[0] = (1 << 12) | (1 << 8) | (2 << 5) | (1 << 2) | 1;
    repeat (20) @(posedge clk_i);
    // 1. core 0 learns class 3 on its own slot
    descriptor = pack_normal_task(2'b00, 0, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    descriptor.reserved_bits[2:0] = 3;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    expect_moved(0, 1'b0, 0, got);
    repeat (8) @(posedge clk_i);
    csr_done(0, 0, 0, 0);
    wait_drained(0);
    expect_samples(1, "own task");
    learned = 1;
    m = gen_dut[0].i_dut.i_wd_adapt.table_q[1][3].maximum;
    if (m < 1 || m > 20) $fatal(1, "[ADAPT_MOVED] training fixture learned %0d", m);
    // 2. task 3 hangs on core 0 (fenced at 4 M) and is replayed onto core 1
    descriptor.task_id = 3;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 0, CSR_READY, got);
    expect_moved(0, 1'b0, 3, got);
    wait (gen_dut[0].i_dut.core_fenced[0][0]);
    csr_read(0, 0, 1, CSR_READY, got);
    expect_moved(1, 1'b1, 3, got);
    h = moved_off ? 2 * m : 16 * m;
    c = moved_off ? 4 * m : 32 * m;
    if (h > 200) h = 200;
    if (c > 600) c = 600;
    if (gen_dut[0].i_dut.wd_learned.h[1][0] != h || gen_dut[0].i_dut.wd_learned.c[1][0] != c ||
        !gen_dut[0].i_dut.wd_learned.h_valid[1][0] || !gen_dut[0].i_dut.wd_learned.c_valid[1][0])
        $fatal(1, "[ADAPT_MOVED] replayed task: H_ad/C_ad %0d/%0d, expected %0d/%0d (M %0d)",
               gen_dut[0].i_dut.wd_learned.h[1][0], gen_dut[0].i_dut.wd_learned.c[1][0], h, c, m);
    csr_write(0, 0, 1, CSR_HEARTBEAT, device_axi_lite_data_t'(1));
    csr_done(0, 0, 1, 3);
    wait_drained(1);
    learned += moved_off;
    expect_samples(learned, "replayed task");
    // 3. task 4 of the retired logical core 0 is remapped onto core 1
    descriptor.task_id = 4;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 1, CSR_READY, got);
    expect_moved(1, 1'b1, 4, got);
    csr_done(0, 0, 1, 4);
    wait_drained(1);
    learned += moved_off;
    expect_samples(learned, "remapped task");
    // 4. task 5 of core 1's own logical slot
    descriptor = pack_normal_task(2'b00, 5, 0, 0, 1, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    descriptor.reserved_bits[2:0] = 3;
    task_queue_master[0].write(task_queue_base[0], '0, descriptor, '1, resp);
    csr_read(0, 0, 1, CSR_READY, got);
    expect_moved(1, 1'b0, 5, got);
    if (gen_dut[0].i_dut.wd_learned.h[1][0] != ((2 * m > 200) ? 200 : 2 * m))
        $fatal(1, "[ADAPT_MOVED] own task on core 1: H_ad %0d", gen_dut[0].i_dut.wd_learned.h[1][0]);
    csr_done(0, 0, 1, 5);
    wait_drained(1);
    learned += 1;
    expect_samples(learned, "own task on core 1");
    repeat (20) @(posedge clk_i);
    if (gen_dut[0].i_dut.replay_stuck_o)
        $fatal(1, "[ADAPT_MOVED] recovery stuck");
    release gen_dut[0].i_dut.bingo_hw_manager_wd_late_i;
    $display("Moved execution tests passed off=%0d M=%0d samples=%0d", moved_off, m, learned);
    $finish;
end
