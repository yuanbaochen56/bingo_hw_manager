`timescale 1ns/1ps
`include "bingo_hw_manager/typedef.svh"

// Unit test of bingo_hw_manager_slot_table: a slot in HOLD drains in the cycle
// its table entry is recomputed (the stale substitute in its entry is fenced).
// The recompute wins the table write, so the park must not commit in that
// cycle; it is decided again one cycle later, on the new table.
//   Cores 0..2 of one type in two clusters, levels 1 and 2, lowest index.
//   Core 1 of cluster 0 is parked; its checkout queue empties in the cycle
//   the core in its entry is fenced.
//   fail  No spare: the entry holds core 0 of cluster 0. Once that core is
//         fenced, core 1 becomes its substitute, so the park fails.
//   late  Cluster 1 is spare: the entry holds core 0 of cluster 1. Once that
//         core is fenced, its substitute is core 1 of cluster 1, and core 1
//         parks on it one cycle late.
module tb_bingo_hw_manager_park_commit;

    localparam int unsigned NumCores = 3;
    localparam int unsigned NumClusters = 2;
    localparam int unsigned CoreIdWidth = 2;
    localparam int unsigned ClusterIdWidth = 1;
    localparam int unsigned LoadWidth = 4;

    `BINGO_HW_MANAGER_TYPEDEF_SLOT_STATE_T(slot_state_t, NumCores, NumClusters)
    `BINGO_HW_MANAGER_TYPEDEF_CTRL_QUEUE_T(ctrl_queue_t, NumCores, NumClusters, LoadWidth)
    `BINGO_HW_MANAGER_TYPEDEF_TYPE_CFG_T(type_cfg_t, 16)
    `BINGO_HW_MANAGER_TYPEDEF_SMT_T(smt_t, NumCores, NumClusters, CoreIdWidth, ClusterIdWidth)
    `BINGO_HW_MANAGER_TYPEDEF_PARK_T(park_t, NumCores, NumClusters)

    logic                                 clk, rst_n;
    slot_state_t                          slot;
    ctrl_queue_t                          queue;
    type_cfg_t                            type_cfg;
    bingo_hw_manager_pkg::sub_cfg_t       sub_cfg;
    logic [NumCores-1:0][NumClusters-1:0] park_req;
    smt_t                                 smt;
    logic                                 smt_update;
    logic [NumCores-1:0][NumClusters-1:0] smt_recompute;
    park_t                                park;

    bingo_hw_manager_slot_table #(
        .NumCores(NumCores),
        .NumClusters(NumClusters),
        .CoreIdWidth(CoreIdWidth),
        .ClusterIdWidth(ClusterIdWidth),
        .SubstituteLevelMask(3'b011),
        .LoadWidth(LoadWidth),
        .slot_state_t(slot_state_t),
        .ctrl_queue_t(ctrl_queue_t),
        .type_cfg_t(type_cfg_t),
        .smt_t(smt_t),
        .park_t(park_t)
    ) i_dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .slot_i(slot),
        .queue_i(queue),
        .type_cfg_i(type_cfg),
        .sub_cfg_i(sub_cfg),
        .park_req_i(park_req),
        .smt_o(smt),
        .smt_update_o(smt_update),
        .smt_recompute_o(smt_recompute),
        .park_o(park)
    );

    initial clk = 1'b0;
    always #5 clk = !clk;

    int unsigned errors = 0;

    function automatic void check(input bit ok, input string msg);
        if (!ok) begin
            errors++;
            $error("%s", msg);
        end
    endfunction

    // The table entry of (c, cl) holds (sub_c, sub_cl)
    function automatic bit entry_is(input int unsigned c, input int unsigned cl,
                                    input int unsigned sub_c, input int unsigned sub_cl);
        return smt.found[c][cl] && (smt.core[c][cl] == CoreIdWidth'(sub_c)) &&
               (smt.cluster[c][cl] == ClusterIdWidth'(sub_cl));
    endfunction

    // Inputs change on the falling edge and outputs are checked on the next one,
    // after the rising edge in between.

    // Reset with the given spare clusters. Every queue is empty except the
    // checkout queue of core 1 of cluster 0, the core that is parked.
    task automatic reset_dut(input logic [NumClusters-1:0] spare);
        rst_n          = 1'b0;
        slot           = '0;
        queue          = '0;
        type_cfg       = '0;
        sub_cfg        = bingo_hw_manager_pkg::SubCfgDefault;
        sub_cfg.spare  = 32'(spare);
        park_req       = '0;
        queue.checkout_empty       = '1;
        queue.ready_empty          = '1;
        queue.checkout_empty[1][0] = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    // Ask to park core 1 of cluster 0. It enters HOLD and stays there: its
    // checkout queue is not empty.
    task automatic hold_core1();
        park_req[1][0] = 1'b1;
        @(negedge clk);
        check(park.hold[1][0], "core 1 did not enter HOLD");
        repeat (3) @(negedge clk);
        check(park.hold[1][0], "core 1 left HOLD before it drained");
    endtask

    // In one cycle: core 1 drains, and (c, cl), the core in its entry, is fenced
    task automatic drain_and_fence(input int unsigned c, input int unsigned cl);
        queue.checkout_empty[1][0] = 1'b1;
        slot.fenced[c][cl]         = 1'b1;
        @(negedge clk);
    endtask

    initial begin
        // fail: core 1 becomes the substitute of the fenced core 0
        reset_dut('0);
        check(entry_is(1, 0, 0, 0), "fail: the entry of core 1 is not core 0");
        hold_core1();
        drain_and_fence(0, 0);
        check(!(park.parked[1][0] && entry_is(1, 0, 1, 0)), "fail: core 1 is PARKED with its entry on itself");
        check(park.hold[1][0], "fail: core 1 left HOLD in the recompute cycle");
        check(entry_is(0, 0, 1, 0), "fail: the substitute of core 0 is not core 1");
        @(negedge clk);
        check(park.fail[1][0] && !park.parked[1][0], "fail: the park of core 1 did not fail");

        // late: core 1 parks one cycle later, on core 1 of cluster 1
        reset_dut(2'b10);
        check(entry_is(1, 0, 0, 1), "late: the entry of core 1 is not core 0 of cluster 1");
        hold_core1();
        drain_and_fence(0, 1);
        check(park.hold[1][0], "late: core 1 left HOLD in the recompute cycle");
        check(entry_is(0, 1, 1, 1), "late: the substitute of core 0 of cluster 1 is not core 1 of cluster 1");
        @(negedge clk);
        check(park.parked[1][0] && entry_is(1, 0, 1, 1), "late: core 1 is not parked on core 1 of cluster 1");

        repeat (3) @(negedge clk);
        if (errors == 0) $display("Park commit test passed");
        else             $display("Park commit test FAILED: %0d checks", errors);
        $finish;
    end

endmodule
