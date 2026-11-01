localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 1000000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
task automatic servo_level(input int level);
    repeat (30) @(negedge clk_i);
    if (gen_dut[0].i_dut.pm_domain_level[1] != level)
        $fatal(1, "[ACCESS_LEVEL] domain 1 level %0d expected %0d",
               gen_dut[0].i_dut.pm_domain_level[1], level);
    if (gen_dut[0].i_dut.pm_domain_level[2] != 25)
        $fatal(1, "[ACCESS_LEVEL] woke unrelated domain");
endtask
initial begin
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    for (int cl = 0; cl < 2; cl++)
        for (int c = 0; c < 3; c++)
            fork
                automatic int fcl = cl, fc = c;
                begin
                    automatic device_axi_lite_data_t id;
                    csr_read(0, fcl, fc, CSR_READY, id);
                    // A dispatched slot remains genuinely busy.
                end
            join_none
    servo_level(25);
    pm_access_level[0] = 12; cluster_access[0][0] = 1;
    servo_level(12);
    // Invalid values must fall back to normal, including high bits with low
    // byte 12 (a truncate-before-validation mutation).
    for (int k = 0; k < 6; k++) begin : foreach_invalid
        case (k)
            0: pm_access_level[0] = 0;
            1: pm_access_level[0] = 6;
            2: pm_access_level[0] = 5;
            3: pm_access_level[0] = 25;
            4: pm_access_level[0] = 26;
            5: pm_access_level[0] = 32'h1000000c;
        endcase
        servo_level(6);
    end
    pm_access_level[0] = 12; servo_level(12);
    // Derate is max(servo, derate): test both sides of S.
    risk_policy[0] = (1 << 5) | (18 << 8) | 1;
    force gen_dut[0].i_dut.i_ctrl.i_risk.risk_q[1][0] = 1'b1;
    servo_level(18);
    risk_policy[0] = (1 << 5) | (8 << 8) | 1; servo_level(12);
    release gen_dut[0].i_dut.i_ctrl.i_risk.risk_q[1][0];
    risk_policy[0] = 0;
    task_queue_master[0].write(task_queue_base[0], '0,
        pack_normal_task(2'b00, 1, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    servo_level(6);
    if (gen_dut[0].i_dut.ctrl_view.access_only[0][0])
        $fatal(1, "[ACCESS_LEVEL] genuinely busy slot marked access-only");
    $display("External access servo validation and derate passed");
    $finish;
end
