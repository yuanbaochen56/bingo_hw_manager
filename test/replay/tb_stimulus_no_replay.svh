// A4 directed fixtures. Expected stuck cases finish explicitly, not by timeout.
localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

int nr_type = 3;
int nr_cerf = 1;
int nr_first_marked = 0;
int nr_exports = 0;
bit nr_replayed [8];
int nr_replay_count [8];
bit nr_retired_before_done;
bit nr_done_seen;
bit nr_dispatch_after_done;
bingo_hw_manager_task_desc_full_t nr_first, nr_second, nr_join;

always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[0].i_dut.export_push) nr_exports++;
        if (gen_dut[0].i_dut.replay_step.fire) begin
            nr_replayed[gen_dut[0].i_dut.replay_data.task_id] = 1'b1;
            nr_replay_count[gen_dut[0].i_dut.replay_data.task_id]++;
        end
        if (gen_dut[0].i_dut.done_q_push[0][0]) nr_done_seen = 1'b1;
        if (NR_CASE == 0 && gen_dut[0].i_dut.checkout_queue_pop[0][0] &&
            !gen_dut[0].i_dut.replay_pop[0][0] &&
            !nr_done_seen && !gen_dut[0].i_dut.done_q_push[0][0])
            nr_retired_before_done = 1'b1;
        if (NR_CASE == 0 && gen_dut[0].i_dut.ready_queue_pop[2][0])
            nr_dispatch_after_done = nr_done_seen;
    end
end

task automatic nr_wait_blocked(input int core);
    fork : blocked_wait
        wait (gen_dut[0].i_dut.replay_blocked_o[core][0] === 1'b1);
        begin
            repeat (6000) @(posedge clk_i);
            $fatal(1, "[NO_REPLAY] core %0d did not block", core);
        end
    join_any
    disable blocked_wait;
endtask

task automatic nr_wait_done(input int id);
    fork : done_wait
        wait (task_completed_bitmap[id] === 1'b1);
        begin
            repeat (6000) @(posedge clk_i);
            $fatal(1, "[NO_REPLAY] task %0d did not complete", id);
        end
    join_any
    disable done_wait;
endtask

initial begin : no_replay_test
    automatic axi_pkg::resp_t resp;
    void'($value$plusargs("NR_TASK_TYPE=%d", nr_type));
    void'($value$plusargs("NR_CERF=%d", nr_cerf));
    void'($value$plusargs("NR_FIRST_MARKED=%d", nr_first_marked));
    for (int i = 0; i < 8; i++) begin
        nr_replayed[i] = 1'b0;
        nr_replay_count[i] = 0;
    end
    nr_first = pack_normal_task(2'(nr_type), 16'd1, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    nr_second = pack_normal_task(2'b11, 16'd2, 0, 0, 0,
        1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b100));
    nr_join = pack_normal_task(2'b00, 16'd3, 0, 0, 2,
        1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
    if (NR_CASE == 2 || NR_CASE == 5) begin
        nr_first.task_type = 2'b00;
        nr_first.dep_set_info.dep_set_en = 1'b0;
    end
    if (NR_CASE == 2 && nr_first_marked) begin
        nr_first.task_type = 2'b11;
        nr_second.task_type = 2'b00;
    end
    if (NR_CASE == 3) begin
        nr_first.cond_exec_en = 1'b1;
        nr_first.cond_exec_group_id = 0;
    end
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    if (NR_CASE == 3) cerf_write_bitmask(0, 1);
    task_queue_master[0].write(task_queue_base[0], '0, nr_first, '1, resp);
    if (NR_CASE == 2 || NR_CASE == 5)
        task_queue_master[0].write(task_queue_base[0], '0, nr_second, '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, nr_join, '1, resp);
    case (NR_CASE)
        0: begin
            nr_wait_done(3);
            repeat (30) @(posedge clk_i);
            if (!nr_done_seen || nr_retired_before_done || !nr_dispatch_after_done ||
                !gen_dut[0].i_dut.checkout_queue_empty[0][0])
                $fatal(1, "[NO_REPLAY] marked task did not wait for its own done");
            if (|gen_dut[0].i_dut.replay_blocked_o)
                $fatal(1, "[NO_REPLAY] healthy task blocked");
        end
        1: begin
            if (nr_type == 0) begin
                nr_wait_done(3);
                if (!nr_replayed[1] || |gen_dut[0].i_dut.replay_blocked_o)
                    $fatal(1, "[NO_REPLAY] ordinary negative control did not replay");
            end else begin
                nr_wait_blocked(0);
                repeat (300) @(posedge clk_i);
                if (nr_replayed[1] || task_completed_bitmap[1] || task_completed_bitmap[3] ||
                    gen_dut[0].i_dut.checkout_queue_empty[0][0])
                    $fatal(1, "[NO_REPLAY] possibly started task was replayed/released");
            end
        end
        2: begin
            if (nr_first_marked) begin
                nr_wait_blocked(0);
                repeat (200) @(posedge clk_i);
                if (nr_replayed[1] || nr_replayed[2] || task_completed_bitmap[3] ||
                    gen_dut[0].i_dut.checkout_queue_data_out[0][0].task_id != 1)
                    $fatal(1, "[NO_REPLAY] queued task overtook a blocked head");
            end else begin
                nr_wait_done(3);
                if (!nr_replayed[1] || !nr_replayed[2] ||
                    |gen_dut[0].i_dut.replay_blocked_o)
                    $fatal(1, "[NO_REPLAY] never-started marked task did not migrate");
            end
        end
        3: begin
            nr_wait_blocked(0);
            if (nr_cerf) begin
                // Arm after blocking so the blocked head is explicitly observed.
                cerf_fb_clear[0][1] = 0;
                cerf_fb_set[0][1] = 1;
                cerf_fb_en[0][1] = 1'b1;
                nr_second.task_id = 4;
                nr_second.task_type = 2'b00;
                nr_second.assigned_core_id = 1;
                nr_second.dep_set_info.dep_set_en = 1'b0;
                nr_second.cond_exec_en = 1'b1;
                nr_second.cond_exec_group_id = 1;
                task_queue_master[0].write(task_queue_base[0], '0, nr_second, '1, resp);
                nr_wait_done(4);
                nr_wait_done(3);
                if (!cerf_fb_evt[0][1] || nr_replayed[1] ||
                    !gen_dut[0].i_dut.checkout_queue_empty[0][0])
                    $fatal(1, "[NO_REPLAY] CERF did not drain the blocked head");
            end else begin
                repeat (300) @(posedge clk_i);
                if (task_completed_bitmap[3] ||
                    gen_dut[0].i_dut.checkout_queue_empty[0][0])
                    $fatal(1, "[NO_REPLAY] no-table case drained the blocked head");
            end
        end
        4: begin
            nr_wait_blocked(0);
            if (nr_exports != 0) $fatal(1, "[NO_REPLAY] marked head exported");
            // Independently retire an empty logical slot, then test new work.
            force gen_dut[0].i_dut.core_fenced[1][0] = 1'b1;
            wait_retired(0, 0, 1, 5000);
            nr_second.assigned_core_id = 1;
            nr_second.task_type = 2'b00;
            nr_second.dep_set_info.dep_set_en = 1'b0;
            task_queue_master[0].write(task_queue_base[0], '0, nr_second, '1, resp);
            repeat (100) @(posedge clk_i);
            if (nr_exports != 1) $fatal(1, "[NO_REPLAY] ordinary new task was not exported");
            nr_second.task_id = 4;
            nr_second.task_type = 2'b11;
            task_queue_master[0].write(task_queue_base[0], '0, nr_second, '1, resp);
            repeat (200) @(posedge clk_i);
            if (nr_exports != 1 || gen_dut[0].i_dut.waiting_dep_check_queue_empty[1])
                $fatal(1, "[NO_REPLAY] retired slot exported/accepted marked new work");
        end
        5: begin
            nr_wait_blocked(1);
            repeat (200) @(posedge clk_i);
            if (nr_replay_count[2] != 1 || task_completed_bitmap[2] || task_completed_bitmap[3] ||
                gen_dut[0].i_dut.checkout_queue_data_out[1][0].task_id != 2 ||
                gen_dut[0].i_dut.checkout_queue_data_out[1][0].assigned_core_id != 0)
                $fatal(1, "[NO_REPLAY] foreign marked head did not stay blocked on S");
            if (gen_dut[0].i_dut.ready_queue_push[2][0])
                $fatal(1, "[NO_REPLAY] foreign marked task reached another substitute");
        end
    endcase
    $display("No replay case %0d passed", NR_CASE);
    $finish;
end
