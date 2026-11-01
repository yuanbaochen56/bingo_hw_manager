// Reuse the original five-slot race without changing its stimulus or checks.
`include "tb_stimulus_replay_done_race.svh"

initial begin
    wait (rst_ni);
    wd_adapt[0] = $test$plusargs("ADAPT_UNAVAILABLE_ON") ?
        ((1 << 8) | (2 << 5) | (1 << 2) | 3) : 0;
    #1;
    if (gen_dut[0].i_dut.WdClassAvail ||
        gen_dut[0].i_dut.TaskDescWidth != 64 ||
        gen_dut[0].i_dut.ReservedBitsForTaskDesc != 0)
        $fatal(1, "[ADAPT_UNAVAILABLE] wrong five-slot descriptor layout");
end

// Compare every sampled cycle between CSR on/off, including both AXI paths,
// device ready words, watchdog timers, queue actions and recovery state.
always @(negedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.wd_class_q !== '0 ||
            gen_dut[0].i_dut.wd_learned.h_valid !== '0 ||
            gen_dut[0].i_dut.wd_learned.c_valid !== '0 ||
            gen_dut[0].i_dut.i_wd_adapt.table_q !== '0)
            $fatal(1, "[ADAPT_UNAVAILABLE] unavailable class learned or changed thresholds");
        $display("[TRACE] unavailable %0t host_in=%h/%h host_out=%h/%h pm=%h/%h ready=%h/%h data=%h pop=%h done=%h busy=%h suspect=%h fence=%h replay=%h/%h",
                 $time, gen_dut[0].i_dut.task_queue_axi_lite_req_i,
                 gen_dut[0].i_dut.task_queue_axi_lite_resp_o,
                 gen_dut[0].i_dut.task_queue_axi_lite_req_o,
                 gen_dut[0].i_dut.task_queue_axi_lite_resp_i,
                 gen_dut[0].i_dut.pm_axi_lite_req_o,
                 gen_dut[0].i_dut.pm_axi_lite_resp_i,
                 local_ready_queue_req[0], local_ready_queue_resp[0],
                 gen_dut[0].i_dut.ready_queue_data_out,
                 gen_dut[0].i_dut.ready_queue_pop, gen_dut[0].i_dut.done_q_push,
                 gen_dut[0].i_dut.wd_status.busy, gen_dut[0].i_dut.core_dead_suspect,
                 gen_dut[0].i_dut.core_fenced, replay_move_count[0], fence_drop_count[0]);
        for (int c = 0; c < 5; c++)
            $display("[TRACE] unavailable %0t core=%0d timer=%0d",
                     $time, c, gen_dut[0].i_dut.i_watchdog.timer_q[c][0]);
    end
end
