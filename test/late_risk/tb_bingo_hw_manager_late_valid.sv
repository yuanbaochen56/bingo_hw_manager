`timescale 1ns/1ps
module tb_bingo_hw_manager_late_valid;
    `include "tb_bingo_hw_manager_late_unit.svh"
    initial begin
        reset();
        sample(10);
        late_ctrl = 3;
        expect_late(1, 20);
        ctrl[0] = 0;
        expect_late(1, 20); // Prediction does not require detection EN.
        ctrl[11:8] = 2;
        expect_late(0);
        ctrl[11:8] = 0;
        expect_late(1, 20); // Warmup zero means one.
        classes[0][0] = 0;
        force dut.table_q[1][0].maximum = 32'd10;
        force dut.table_q[1][0].samples = 4'd1;
        expect_late(0); // Isolate the class guard even with populated history.
        release dut.table_q[1][0].maximum;
        release dut.table_q[1][0].samples;
        classes[0][0] = 1;
        classes[2][0] = 1;
        #1;
        if (lv[2][0]) $fatal(1, "[P9_UNIT] out-of-table type valid");
        ctrl[1] = 1;
        start(1, 2);
        expect_late(0);
        complete(5); // Invalid Late_ad cannot exclude learning.
        expect_entry(10, 2, 2);
        start(1, 1);
        expect_late(1, 20);
        complete(5);
        ctrl[1] = 0; ctrl[0] = 1;
        late_ctrl = (100 << 12) | 3;
        expect_late(0); // Equality with current H_ad is not valid.
        late_ctrl = (101 << 12) | 3;
        expect_late(0);
        late_ctrl = (99 << 12) | 3;
        expect_late(1, 99);
        ctrl[0] = 0;
        late_ctrl = (100 << 12) | 3;
        expect_late(1, 100); // Compare H_eff when adaptive detection is off.
        late_ctrl = 0;
        expect_late(0);
        sample(0, 2);
        late_ctrl = (5 << 12) | 3;
        expect_late(0); // M=0 stays invalid despite a positive late floor.
        late_ctrl = 0;
        sample(32'h80000000, 3);
        h_eff = '1;
        late_ctrl = 15;
        expect_late(0); // Wide shift must not wrap to a short threshold.
        $display("Predictive late validity tests passed");
        $finish;
    end
endmodule
