localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
initial begin
    automatic bingo_hw_manager_task_desc_full_t probe;
    automatic logic [63:0] expected;
    automatic int expected_width = NUM_CLUSTERS_PER_CHIPLET == 2 ? 59 : 61;
    wait (rst_ni);
    #1;
    if (!gen_dut[0].i_dut.WdClassAvail ||
        gen_dut[0].i_dut.TaskDescWidth != expected_width ||
        gen_dut[0].i_dut.ReservedBitsForTaskDesc != 64 - expected_width ||
        gen_dut[0].i_dut.WdTaskDescWidth != expected_width + 3 ||
        $bits(gen_dut[0].i_dut.cur_task_desc_full) != 64)
        $fatal(1, "[ADAPT_LAYOUT] hemaia_ci/4cluster/C1g descriptor width");
    probe = '0;
    probe.is_exit = 1;
    probe.reserved_bits[2:0] = 7;
    expected = (64'd7 << expected_width) | (64'd1 << (expected_width - 1));
    if (64'(probe) != expected)
        $fatal(1, "[ADAPT_LAYOUT] class must occupy reserved bits above is_exit");
    $display("Adaptive descriptor layout tests passed clusters=%0d width=%0d reserved=%0d available=1",
             NUM_CLUSTERS_PER_CHIPLET, expected_width, 64 - expected_width);
    $finish;
end
