`timescale 1ns/1ps
// BINGO_WD_LATE[10:9] FRAC: the late threshold is (M + (M >> 2) * FRAC) << SH_L,
// that is 1, 1.25, 1.5 or 1.75 times the learned maximum before the shift.
// Validity, the floor and the exclusion of late executions use that threshold.
module tb_bingo_hw_manager_late_frac;
    `include "tb_bingo_hw_manager_rules_unit.svh"
    function automatic logic [31:0] late_word(input int frac, input int sh_l = 0, input int lfloor = 0);
        return (32'(lfloor) << 12) | (32'(frac) << 9) | (32'(sh_l) << 1) | 32'd1;
    endfunction
    initial begin
        reset();
        sample(40);
        expect_entry(1, 40, 1, 1);
        classes[0][0] = 1; classes[1][0] = 1;
        // H_ad = 80 (SH_H 1)
        for (int f = 0; f < 4; f++) begin
            late_ctrl = late_word(f);
            expect_late(0, 1, 40 + 10 * f);
        end
        late_ctrl = 32'd1;
        expect_late(0, 1, 40);                   // FRAC 0 is the old threshold
        // SH_L 1: 80 + 20 FRAC is never below H_ad = 80
        for (int f = 0; f < 4; f++) begin
            late_ctrl = late_word(f, 1);
            expect_late(0, 0);
        end
        // SH_H 2 (H_ad 160): the shift applies after the fraction
        ctrl[4:2] = 3'd2;
        for (int f = 0; f < 4; f++) begin
            late_ctrl = late_word(f, 1);
            expect_late(0, 1, 80 + 20 * f);
        end
        late_ctrl = late_word(1, 0, 100);
        expect_late(0, 1, 100);                  // the floor still applies
        ctrl[4:2] = 3'd1;
        late_ctrl = late_word(3, 0, 100);
        expect_late(0, 0);                       // the floor reaches H_ad = 80
        // A moved slot: the fraction applies to the shifted maximum
        late_ctrl = late_word(2) | (32'd1 << 7);
        moved[0][0] = 1;
        ctrl[4:2] = 3'd2;                        // H_ad = 4 * 80 = 320
        expect_late(0, 1, 80 + 20 * 2);
        expect_late(1, 1, 40 + 10 * 2);
        moved[0][0] = 0;
        ctrl[4:2] = 3'd1;
        // Exclusion with FRAC 2 (M = 40: threshold 60)
        late_ctrl = late_word(2);
        sample(59);
        expect_entry(1, 59, 2, 1);               // below 60: learned (threshold now 59 + 14 * 2 = 87)
        expect_late(0, 1, 87);
        sample(87);
        expect_entry(1, 59, 2, 1);               // at the threshold: late, not learned
        sample(86);
        expect_entry(1, 86, 3, 1);
        // M = 86: threshold 86 + 21 * 2 = 128, below H_ad = 172
        expect_late(0, 1, 128);
        // Same cycle, same class: a late completion and a healthy one
        start(3'b011);
        complete(3'b011, 130, 90);
        expect_entry(1, 90, 4, 2);               // slot 0 (130 >= 128) excluded, slot 1 learned
        start(3'b011);
        complete(3'b011, 91, 200);
        expect_entry(1, 91, 5, 2);               // and the other way round
        // Odd maxima: M >> 2 truncates (M = 91: 91 + 22 * FRAC)
        for (int f = 0; f < 4; f++) begin
            late_ctrl = late_word(f);
            expect_late(0, 1, 91 + 22 * f);
        end
        // The fraction comes before SH_L: (91 + 22 FRAC) << 1, not 182 + 45 FRAC
        ctrl[4:2] = 3'd2;                        // H_ad = 364
        for (int f = 0; f < 4; f++) begin
            late_ctrl = late_word(f, 1);
            expect_late(0, 1, (91 + 22 * f) * 2);
        end
        // and after the shift of a moved slot: 182 + 45 FRAC, not (91 + 22 FRAC) << 1
        late_ctrl = late_word(2) | (32'd1 << 7);
        moved[0][0] = 1;
        expect_late(0, 1, 182 + 45 * 2);
        moved[0][0] = 0;
        ctrl[4:2] = 3'd1;
        $display("Fractional late threshold tests passed");
        $finish;
    end
endmodule
