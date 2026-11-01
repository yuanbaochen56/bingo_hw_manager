`timescale 1ns/1ps
// BINGO_WD_LATE[6]: only executions on their own slot at no level faster than
// normal are learned. BINGO_WD_LATE[8:7]: an execution away from its own slot
// gets its learned thresholds from the maximum shifted left by that many bits.
module tb_bingo_hw_manager_wd_adapt_comparable;
    `include "tb_bingo_hw_manager_rules_unit.svh"
    initial begin
        reset();
        // Bit 6 clear: moved and faster-than-normal executions are learned
        moved[0][0] = 1;
        sample(10);
        expect_entry(1, 10, 1, 1);
        moved[0][0] = 0;
        start(3'b001); fast_cycle(0); complete(3'b001, 12);
        expect_entry(1, 12, 2, 1);
        // Bit 6 set: neither is learned (M, N and L stay)
        late_ctrl = 32'h40;
        moved[0][0] = 1;
        sample(50);
        moved[0][0] = 0;
        expect_entry(1, 12, 2, 1);
        start(3'b001); fast_cycle(0); complete(3'b001, 60);
        expect_entry(1, 12, 2, 1);               // fast in a middle cycle
        start(3'b001, 1, 1); complete(3'b001, 61);
        expect_entry(1, 12, 2, 1);               // fast only in the dispatch cycle
        start(3'b001); complete(3'b001, 62, 0, 1);
        expect_entry(1, 12, 2, 1);               // fast only in the done cycle
        fast_cycle(0);                           // fast while idle: does not count
        sample(14);
        expect_entry(1, 14, 3, 1);
        // Completions in the same cycle: the excluded one is skipped, the
        // other one learned, whichever slot comes first
        start(3'b011); moved[0][0] = 1;
        complete(3'b011, 70, 16);
        moved[0][0] = 0;
        expect_entry(1, 16, 4, 2);
        start(3'b011); moved[1][0] = 1;
        complete(3'b011, 18, 80);
        moved[1][0] = 0;
        expect_entry(1, 18, 5, 2);
        start(3'b011); fast[1][0] = 1;
        complete(3'b011, 19, 90);
        fast[1][0] = 0;
        expect_entry(1, 19, 6, 2);
        // Thresholds, M = 19: H_ad = 2M, C_ad = 4M on the own slot
        late_ctrl = 0;
        classes[0][0] = 1; classes[1][0] = 1;
        expect_bounds(0, 38, 76);
        moved[0][0] = 1;
        expect_bounds(0, 38, 76);                // shift 0: unchanged
        late_ctrl = 1 << 7;
        expect_bounds(0, 76, 152);               // one more bit
        expect_bounds(1, 38, 76);                // the slot on its own slot keeps 2M / 4M
        late_ctrl = 3 << 7;
        expect_bounds(0, 304, 608);
        h_eff[0][0] = 200;
        expect_bounds(0, 200, 608);              // the caps still apply
        c_eff[0][0] = 500;
        expect_bounds(0, 200, 500);
        h_eff[0][0] = 1000; c_eff[0][0] = 2000;
        late_ctrl = (1 << 7) | 1;                // late on, SH_L 0, LFLOOR 0
        expect_late(0, 1, 38);
        expect_late(1, 1, 19);
        moved[0][0] = 0;
        expect_late(0, 1, 19);
        // The late exclusion uses the shifted bound of the moved slot: 30 is
        // late for an execution on its own slot (>= 19) but not for a moved
        // one (< 38), and bit 6 is clear, so the moved one is learned
        start(3'b001); moved[0][0] = 1;
        complete(3'b001, 30);
        moved[0][0] = 0;
        expect_entry(1, 30, 7, 2);
        start(3'b001);
        complete(3'b001, 40);
        expect_entry(1, 30, 7, 2);
        $display("Comparable learning tests passed");
        $finish;
    end
endmodule
