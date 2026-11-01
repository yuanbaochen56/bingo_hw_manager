// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// bingo_hw_manager_pm_counters on its own, against a model of its definition:
// random domain levels (DFS) or a chip-wide level (DVFS), configured levels
// that are sometimes equal (class order idle, normal, boost, other), a boost
// level of 0, level 0 (never set), slots in counted, uncounted and no domains.
// Domains 2 .. 4 are counted (an offset first domain). A second instance with
// 4-bit counters checks the wrap-around. The model is compared in the middle
// of every cycle, before the inputs change.
module tb_bingo_hw_manager_pm_counters_unit;
    import bingo_hw_manager_pkg::*;
    localparam int unsigned NumCores = 3;
    localparam int unsigned NumClusters = 2;
    localparam int unsigned First = 2;
    localparam int unsigned Domains = 3;
    localparam int unsigned Cycles = 20000;

    logic clk_i = 1'b0, rst_ni = 1'b0;
    always #5ns clk_i = ~clk_i;

    logic                                      dvfs;
    logic [7:0]                                dvfs_level, idle_level, normal_level, boost_level;
    logic [31:0][7:0]                          domain_level;
    logic [NumCores-1:0][NumClusters-1:0][5:0] slot_domain;
    logic [NumCores-1:0][NumClusters-1:0]      slot_active;
    logic [Domains-1:0][PmCounters-1:0][31:0]  count;
    logic [Domains-1:0][PmCounters-1:0][3:0]   count_narrow;

    bingo_hw_manager_pm_counters #(
        .NumCores(NumCores), .NumClusters(NumClusters), .FirstDomain(First), .NumDomains(Domains)
    ) i_dut (
        .clk_i, .rst_ni, .pm_i('{enable: 1'b1, dvfs: dvfs, dvfs_level: dvfs_level, domain_level: domain_level,
                                idle_level: idle_level, normal_level: normal_level, boost_level: boost_level}),
        .slot_domain_i(slot_domain), .slot_active_i(slot_active), .count_o(count)
    );
    bingo_hw_manager_pm_counters #(
        .NumCores(NumCores), .NumClusters(NumClusters), .FirstDomain(First), .NumDomains(Domains),
        .CounterWidth(4)
    ) i_dut_narrow (
        .clk_i, .rst_ni, .pm_i('{enable: 1'b1, dvfs: dvfs, dvfs_level: dvfs_level, domain_level: domain_level,
                                idle_level: idle_level, normal_level: normal_level, boost_level: boost_level}),
        .slot_domain_i(slot_domain), .slot_active_i(slot_active), .count_o(count_narrow)
    );

    longint unsigned expect_count [Domains][PmCounters];
    longint unsigned seen_class [PmCounters];
    int unsigned     equal_levels, dvfs_cycles, zero_boost;

    // One of a few levels, so that equal levels and the configured ones are common
    function automatic logic [7:0] pick_level();
        case ($urandom % 7)
            0: return 8'd0;
            1: return 8'd3;
            2: return 8'd6;
            3: return 8'd12;
            4: return 8'd18;
            default: return 8'd25;
        endcase
    endfunction

    task automatic randomize_inputs(input bit config_change);
        if (config_change) begin
            idle_level   = ($urandom % 8 == 0) ? pick_level() : 8'd25;
            normal_level = ($urandom % 8 == 0) ? pick_level() : 8'd6;
            boost_level  = ($urandom % 4 == 0) ? 8'd0 : (($urandom % 8 == 0) ? pick_level() : 8'd3);
            dvfs         = ($urandom % 6 == 0);
        end
        dvfs_level = pick_level();
        for (int d = 0; d < 32; d++) domain_level[d] = pick_level();
        for (int c = 0; c < NumCores; c++)
            for (int cl = 0; cl < NumClusters; cl++) begin
                case ($urandom % 6)
                    0: slot_domain[c][cl] = 6'd32 + 6'($urandom % 32);   // no domain
                    1: slot_domain[c][cl] = 6'($urandom % 2);            // uncounted (below First)
                    2: slot_domain[c][cl] = 6'd5 + 6'($urandom % 27);    // uncounted (above)
                    default: slot_domain[c][cl] = 6'(First + $urandom % Domains);
                endcase
                slot_active[c][cl] = $urandom % 2;
            end
    endtask

    // Expected increments of this cycle (the counted domains)
    task automatic model();
        for (int unsigned d = 0; d < Domains; d++) begin
            automatic logic [7:0] level = dvfs ? dvfs_level : domain_level[First + d];
            automatic int k = -1;
            automatic bit active = 0;
            if (level != 0) begin
                if (level == idle_level)                         k = PmcIdle;
                else if (level == normal_level)                  k = PmcNormal;
                else if (boost_level != 0 && level == boost_level) k = PmcBoost;
                else                                             k = PmcOther;
            end
            if (k >= 0) begin
                expect_count[d][k]++;
                seen_class[k]++;
            end
            for (int c = 0; c < NumCores; c++)
                for (int cl = 0; cl < NumClusters; cl++)
                    if (slot_active[c][cl] && slot_domain[c][cl] == First + d) active = 1;
            if (active) begin
                expect_count[d][PmcActive]++;
                seen_class[PmcActive]++;
            end
        end
        if (idle_level == normal_level || normal_level == boost_level || idle_level == boost_level)
            equal_levels++;
        if (dvfs) dvfs_cycles++;
        if (boost_level == 0) zero_boost++;
    endtask

    task automatic compare(input int unsigned cycle);
        for (int unsigned d = 0; d < Domains; d++)
            for (int unsigned k = 0; k < PmCounters; k++) begin
                if (count[d][k] != 32'(expect_count[d][k]))
                    $fatal(1, "[PMC] cycle %0d domain %0d counter %0d: %0d, expected %0d",
                           cycle, First + d, k, count[d][k], expect_count[d][k]);
                if (count_narrow[d][k] != 4'(expect_count[d][k]))
                    $fatal(1, "[PMC] cycle %0d domain %0d counter %0d (4 bits): %0d, expected %0d",
                           cycle, First + d, k, count_narrow[d][k], 4'(expect_count[d][k]));
            end
    endtask

    initial begin
        foreach (expect_count[d, k]) expect_count[d][k] = 0;
        foreach (seen_class[k]) seen_class[k] = 0;
        equal_levels = 0; dvfs_cycles = 0; zero_boost = 0;
        randomize_inputs(1'b1);
        repeat (3) @(negedge clk_i);
        // Nothing counts in reset
        compare(0);
        rst_ni = 1'b1;
        for (int unsigned cycle = 1; cycle <= Cycles; cycle++) begin
            model();                      // what the next edge counts
            @(negedge clk_i);
            compare(cycle);
            randomize_inputs(cycle % 50 == 0);
        end
        foreach (seen_class[k])
            if (seen_class[k] < 100) $fatal(1, "[PMC] class %0d too rare (%0d)", k, seen_class[k]);
        if (equal_levels < 100 || dvfs_cycles < 100 || zero_boost < 100)
            $fatal(1, "[PMC] coverage: equal %0d dvfs %0d zero boost %0d", equal_levels, dvfs_cycles, zero_boost);
        $display("[PMC] %0d cycles, per class %0d %0d %0d %0d %0d, equal levels %0d, dvfs %0d, boost 0 %0d",
                 Cycles, seen_class[0], seen_class[1], seen_class[2], seen_class[3], seen_class[4],
                 equal_levels, dvfs_cycles, zero_boost);
        $display("Power-domain counters unit test passed");
        $finish;
    end
endmodule
