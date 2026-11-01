// Power-domain counters of the top (pm_count_o, harness domains 1 ..
// NUM_CLUSTERS_PER_CHIPLET, DFS) against a model of their definition, compared
// in the middle of every cycle: per domain, the cycles at the idle, normal,
// boost and any other level the PM applied, and the cycles in which a slot of
// the domain is neither waiting for a task, nor exited, nor fenced. Included
// after the harness by the tb_bingo_hw_manager_pm_counters_* TBs; at the end
// every class the stimulus is expected to reach (pmc_expect_nonzero) must
// have counted.
longint unsigned pmc_model [NUM_CLUSTERS_PER_CHIPLET][bingo_hw_manager_pkg::PmCounters];
bit pmc_started = 1'b0;
always @(negedge clk_i) begin : pm_counters_model
    if (rst_ni) begin
        // Reset ends on a clock edge, which may or may not count (process
        // order): start from the counters, at most that one edge
        if (!pmc_started) begin
            pmc_started = 1'b1;
            for (int unsigned d = 0; d < NUM_CLUSTERS_PER_CHIPLET; d++)
                for (int unsigned k = 0; k < bingo_hw_manager_pkg::PmCounters; k++) begin
                    pmc_model[d][k] = gen_dut[0].i_dut.pm_count_o[d][k];
                    if (pmc_model[d][k] > 1)
                        $fatal(1, "[PM_COUNT] domain %0d counter %0d at %0d after reset", 1 + d, k, pmc_model[d][k]);
                end
        end
        for (int unsigned d = 0; d < NUM_CLUSTERS_PER_CHIPLET; d++)
            for (int unsigned k = 0; k < bingo_hw_manager_pkg::PmCounters; k++)
                if (gen_dut[0].i_dut.pm_count_o[d][k] != 32'(pmc_model[d][k]))
                    $fatal(1, "[PM_COUNT] domain %0d counter %0d: %0d, model %0d",
                           1 + d, k, gen_dut[0].i_dut.pm_count_o[d][k], pmc_model[d][k]);
        // what the next edge counts
        for (int unsigned d = 0; d < NUM_CLUSTERS_PER_CHIPLET; d++) begin
            automatic int unsigned level = gen_dut[0].i_dut.pm_domain_level[1 + d];
            automatic bit active = 1'b0;
            if (level != 0) begin
                if (level == PM_IDLE_LEVEL)                                 pmc_model[d][0]++;
                else if (level == PM_NORMAL_LEVEL)                          pmc_model[d][1]++;
                else if (PM_BOOST_LEVEL != 0 && level == PM_BOOST_LEVEL)    pmc_model[d][2]++;
                else                                                        pmc_model[d][3]++;
            end
            for (int unsigned c = 0; c < NUM_CORES_PER_CLUSTER; c++)
                for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++)
                    if (pm_core_domain[c][cl] == 1 + d &&
                        !(gen_dut[0].i_dut.core_status_waiting_task[c][cl] ||
                          gen_dut[0].i_dut.exited_q[c][cl] || gen_dut[0].i_dut.core_fenced[c][cl]))
                        active = 1'b1;
            if (active) pmc_model[d][4]++;
        end
    end
end
final begin : pm_counters_report
    for (int unsigned d = 0; d < NUM_CLUSTERS_PER_CHIPLET; d++) begin
        $display("[PM_COUNT] domain %0d idle=%0d normal=%0d boost=%0d other=%0d active=%0d", 1 + d,
                 pmc_model[d][0], pmc_model[d][1], pmc_model[d][2], pmc_model[d][3], pmc_model[d][4]);
        for (int unsigned k = 0; k < bingo_hw_manager_pkg::PmCounters; k++)
            if (pmc_expect_nonzero[d][k] && pmc_model[d][k] == 0)
                $error("[PM_COUNT] domain %0d counter %0d never counted", 1 + d, k);
    end
end
