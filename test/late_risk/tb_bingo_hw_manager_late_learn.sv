`timescale 1ns/1ps
module tb_bingo_hw_manager_late_learn;
    `include "tb_bingo_hw_manager_late_unit.svh"
    initial begin
        reset();
        sample(10);
        expect_entry(10, 1, 1);
        late_ctrl = 3;
        start(1, 2);
        @(negedge clk); interval[0][0] = 30; progress[0][0] = 1;
        step();
        @(negedge clk); progress = '0;
        complete(1); // Maximum earlier segment, not just the final segment.
        expect_entry(10, 1, 1);
        sample(20);
        expect_entry(10, 1, 1); // Equality excludes maximum, samples and load.
        sample(19);
        expect_entry(19, 2, 1);
        expect_late(1, 38);
        sample(40);
        expect_entry(19, 2, 1);
        late_ctrl = 0;
        sample(50, 1, 2);
        expect_entry(50, 3, 2); // P9 off is exactly A7's learning.
        late_ctrl = 3;
        sample(200, 1, 2);
        expect_entry(200, 4, 2); // Late_ad=H_ad: invalid, so do not exclude.
        fenced[0][0] = 1;
        sample(300);
        expect_entry(200, 4, 2);
        $display("Predictive late learning tests passed");
        $finish;
    end
endmodule
