// P9 integration checks use the real top's min selection and P6a/P4 path.
localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
int late_count = 0;
int last_late_interval, last_late_threshold;

always @(posedge clk_i) begin
    if (rst_ni && gen_dut[0].i_dut.wd_late[0][0]) begin
        late_count++;
        last_late_interval = gen_dut[0].i_dut.wd_status.interval[0][0];
        last_late_threshold = gen_dut[0].i_dut.wd_bound.late[0][0];
    end
end

function automatic bingo_hw_manager_task_desc_full_t late_task(input int id);
    automatic bingo_hw_manager_task_desc_full_t f;
    f = pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, 0, 0,
                         1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    f.reserved_bits = 1;
    return f;
endfunction

task automatic late_start(input int id, core = 0);
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t got;
    task_queue_master[0].write(task_queue_base[0], '0, late_task(id), '1, resp);
    csr_read(0, 0, core, CSR_READY, got);
    #1;
    if (got != id || gen_dut[0].i_dut.wd_class_q[core][0] != 1)
        $fatal(1, "[P9_TB] ready task/class lost");
endtask

task automatic late_drain(input int core = 0);
    fork : drain_timeout
        wait (gen_dut[0].i_dut.checkout_queue_empty[core][0] &&
              !gen_dut[0].i_dut.wd_status.busy[core][0]);
        begin
            repeat (500) @(posedge clk_i);
            $fatal(1, "[P9_TB] did not drain");
        end
    join_any
    disable drain_timeout;
endtask

task automatic late_beat(input int id, target, expected_pulses);
    automatic int count_before = late_count;
    late_start(id);
    wait (gen_dut[0].i_dut.i_watchdog.timer_q[0][0] >= target);
    csr_write(0, 0, 0, CSR_HEARTBEAT, device_axi_lite_data_t'(1));
    csr_done(0, 0, 0, id);
    late_drain();
    repeat (3) @(posedge clk_i);
    if (late_count != count_before + expected_pulses)
        $fatal(1, "[P9_TB] late pulses %0d, expected %0d",
               late_count - count_before, expected_pulses);
    if (gen_dut[0].i_dut.core_dead_suspect[0][0] ||
        gen_dut[0].i_dut.core_fenced[0][0])
        $fatal(1, "[P9_TB] progress below H suspected/fenced");
endtask

initial begin
    automatic int bound;
    automatic int count_before;
    wait (rst_ni);
    wd_adapt[0] = (200 << 12) | (1 << 8) | (2 << 5) | (1 << 2) | 1;
    repeat (20) @(posedge clk_i);
    late_start(1);
    repeat (8) @(posedge clk_i);
    csr_done(0, 0, 0, 1);
    late_drain();
    if (gen_dut[0].i_dut.i_wd_adapt.table_q[1][1].samples != 1 ||
        gen_dut[0].i_dut.i_wd_adapt.table_q[1][1].maximum > 20)
        $fatal(1, "[P9_TB] invalid healthy training fixture");
    wd_late[0] = (80 << 12) | (1 << 1) | 1;
    #1;
    if (!gen_dut[0].i_dut.wd_learned.late_valid[0][0] ||
        gen_dut[0].i_dut.wd_bound.late[0][0] != 80)
        $fatal(1, "[P9_TB] learned late floor not selected");

    if (`TB_LATE_CASE == 0) begin
        late_beat(2, 50, 0);
        bound = gen_dut[0].i_dut.wd_bound.late[0][0];
        late_beat(3, bound + 10, 1);
        if (last_late_interval < last_late_threshold || last_late_interval >= 200)
            $fatal(1, "[P9_TB] late window is not [Late,H)");
        wd_late[0] = 0;
        late_beat(4, bound + 10, 0);
        $display("Predictive late window tests passed");
    end else if (`TB_LATE_CASE == 1) begin
        risk_late[0] = 40;
        #1;
        if (gen_dut[0].i_dut.wd_bound.late[0][0] != 40)
            $fatal(1, "[P9_TB] smaller static threshold not selected");
        late_beat(2, 50, 1);
        risk_late[0] = 180;
        bound = gen_dut[0].i_dut.wd_learned.late[0][0];
        #1;
        if (gen_dut[0].i_dut.wd_bound.late[0][0] != bound || bound >= 180)
            $fatal(1, "[P9_TB] smaller adaptive threshold not selected");
        late_beat(3, bound + 10, 1);
        risk_late[0] = 0;
        #1;
        if (gen_dut[0].i_dut.wd_bound.late[0][0] != bound)
            $fatal(1, "[P9_TB] zero static threshold did not use adaptive");
        late_beat(4, bound + 10, 1);
        wd_late[0] = 0;
        #1;
        if (gen_dut[0].i_dut.wd_bound.late[0][0] != 0)
            $fatal(1, "[P9_TB] both disabled still select a threshold");
        $display("Predictive late min tests passed");
    end else begin
        risk_policy[0] = 32'h12;
        late_beat(2, 90, 1);
        if (gen_dut[0].i_dut.i_ctrl.risk_cnt_q[0][0] != 1 || risk[0][0])
            $fatal(1, "[P9_TB] first late beat did not leave exactly one risk count");
        late_beat(3, 90, 1);
        fork : park_timeout
            wait (gen_dut[0].i_dut.park.parked[0][0]);
            begin
                repeat (200) @(posedge clk_i);
                $fatal(1, "[P9_TB] two late beats did not PARK");
            end
        join_any
        disable park_timeout;
        if (!risk[0][0] || park_fail[0][0] ||
            gen_dut[0].i_dut.i_ctrl.risk_cnt_q[0][0] != 2)
            $fatal(1, "[P9_TB] wrong at-risk parking state");
        count_before = late_count;
        late_start(4, 1);
        csr_done(0, 0, 1, 4);
        late_drain(1);
        late_start(5, 1);
        csr_done(0, 0, 1, 5);
        late_drain(1);
        repeat (500) @(posedge clk_i);
        if (gen_dut[0].i_dut.core_fenced[0][0] ||
            gen_dut[0].i_dut.wd_status.busy[0][0] || late_count != count_before)
            $fatal(1, "[P9_TB] parked victim dispatched/fenced or emitted late");
        $display("Predictive late risk tests passed");
    end
    $finish;
end
