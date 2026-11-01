localparam int unsigned EXPECTED_TASK_COUNT = 999;
localparam int unsigned DEADLOCK_THRESHOLD = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int SubCluster = ExitCase == 3 ? 1 : 0;

int absorb_count = 0;
int absorbed_ready = 0;

function automatic bingo_hw_manager_task_desc_full_t exit_task(
    input int id, input int core, input bit is_exit,
    input bit set_dep = 0, input bit check_dep = 0, input int cluster = 0
);
    bingo_hw_manager_task_desc_full_t d;
    d = pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, cluster, core,
        check_dep, check_dep ? bingo_hw_manager_dep_code_t'(1) : '0,
        set_dep, 1'b0, 0, 0, set_dep ? bingo_hw_manager_dep_code_t'(4) : '0);
    d.is_exit = is_exit;
    return d;
endfunction

always @(posedge clk_i) begin
    if (rst_ni) begin
        for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                if (gen_dut[0].i_dut.exit_absorb[c][cl]) absorb_count++;
                if (gen_dut[0].i_dut.ready_queue_push[c][cl] &&
                    ((ExitCase == 2 || ExitCase == 5) ?
                     gen_dut[0].i_dut.ready_queue_data_in[c][cl].task_id == 1 && (c != 0 || cl != 0) :
                     gen_dut[0].i_dut.ready_queue_data_in[c][cl].task_id == 3))
                    absorbed_ready++;
            end
        end
    end
end

task automatic exit_wait_retired;
    fork : wait_exit_retired
        wait (gen_dut[0].i_dut.core_retired[0][0]);
        begin
            repeat (2000) @(posedge clk_i);
            $fatal(1, "A%0d: victim did not retire", ExitCase);
        end
    join_any
    disable wait_exit_retired;
endtask

task automatic exit_wait_join(input int id);
    fork : wait_exit_join
        begin
            automatic device_axi_lite_data_t data;
            csr_read(0, 0, 2, CSR_READY, data);
            if (data[TaskIdWidth-1:0] != id) $fatal(1, "A%0d: wrong successor", ExitCase);
            csr_done(0, 0, 2, id);
        end
        begin
            repeat (2000) @(posedge clk_i);
            $fatal(1, "A%0d: absorbed exit did not release its successor", ExitCase);
        end
    join_any
    disable wait_exit_join;
endtask

initial begin : exit_absorb_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t data;
    automatic bingo_hw_manager_task_desc_full_t probe;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    if (ExitCase == 6) begin
        probe = '0;
        probe.is_exit = 1;
        if (TaskDescWidth != 59 || gen_dut[0].i_dut.TaskDescWidth != 59 ||
            $bits(probe) != 64 || host_axi_lite_data_t'(probe) != (64'd1 << 58))
            $fatal(1, "A6: is_exit must occupy the former reserved bit 58");
        probe = '0;
        probe.task_type = 3;
        probe.task_id = '1;
        if (host_axi_lite_data_t'(probe) != ((64'd3 << 7) | (64'd4095 << 9)))
            $fatal(1, "A6: existing descriptor offsets changed");
        probe = '0;
        probe.is_exit = 1;
        probe = gen_dut[0].i_dut.desc_to_full(59'(probe));
        if (!probe.is_exit)
            $fatal(1, "A6: desc_to_full lost is_exit");
    end else begin
        task_queue_master[0].write(task_queue_base[0], '0,
            exit_task(1, 0, ExitCase == 2 || ExitCase == 5,
                      ExitCase == 2 || ExitCase == 5), '1, resp);
        csr_read(0, 0, 0, CSR_READY, data);
        if (data[TaskIdWidth-1:0] != 1) $fatal(1, "A%0d: victim did not start", ExitCase);
        exit_wait_retired();
        if (ExitCase == 2 || ExitCase == 5) begin
            task_queue_master[0].write(task_queue_base[0], '0, exit_task(2, 2, 0, 0, 1), '1, resp);
            exit_wait_join(2);
        end else begin
            csr_read(0, SubCluster, 1, CSR_READY, data);
            if (data[TaskIdWidth-1:0] != 1) $fatal(1, "A%0d: ordinary task was not replayed", ExitCase);
            csr_done(0, SubCluster, 1, 1);
            repeat (20) @(posedge clk_i);
            if (ExitCase == 3 || ExitCase == 4) begin
                task_queue_master[0].write(task_queue_base[0], '0,
                    exit_task(2, ExitCase == 3 ? 1 : 0, ExitCase == 3, 0, 0, SubCluster), '1, resp);
                csr_read(0, SubCluster, 1, CSR_READY, data);
                if (data[TaskIdWidth-1:0] != 2) $fatal(1, "A%0d: normal routing changed", ExitCase);
                csr_done(0, SubCluster, 1, 2);
                if (ExitCase == 3) csr_write(0, SubCluster, 1, CSR_HEARTBEAT, 32'h80000000);
            end
            if (ExitCase == 4) begin
                task_queue_master[0].write(task_queue_base[0], '0, exit_task(3, 1, 1), '1, resp);
                csr_read(0, 0, 1, CSR_READY, data);
                if (data[TaskIdWidth-1:0] != 3) $fatal(1, "A4: own exit was not dispatched");
                csr_done(0, 0, 1, 3);
                csr_write(0, 0, 1, CSR_HEARTBEAT, 32'h80000000);
            end else begin
                task_queue_master[0].write(task_queue_base[0], '0, exit_task(3, 0, 1, 1), '1, resp);
                task_queue_master[0].write(task_queue_base[0], '0, exit_task(4, 2, 0, 0, 1), '1, resp);
                exit_wait_join(4);
            end
        end
        if (ExitCase == 5) begin
            task_queue_master[0].write(task_queue_base[0], '0, exit_task(3, 0, 1, 1), '1, resp);
            task_queue_master[0].write(task_queue_base[0], '0, exit_task(4, 2, 0, 0, 1), '1, resp);
            exit_wait_join(4);
        end
        repeat (40) @(posedge clk_i);
        if (absorb_count != (ExitCase == 4 ? 0 : ExitCase == 5 ? 2 : 1))
            $fatal(1, "A%0d: absorbed %0d times", ExitCase, absorb_count);
        if (ExitCase != 4 && absorbed_ready != 0)
            $fatal(1, "A%0d: absorbed exit reached a ready queue", ExitCase);
        if (gen_dut[0].i_dut.remap_outstanding_q[0][0] != 0 ||
            gen_dut[0].i_dut.moved_in_q[1][SubCluster][0][0] != 0)
            $fatal(1, "A%0d: moved-task counters did not drain", ExitCase);
        if ((ExitCase == 3 || ExitCase == 4) && !gen_dut[0].i_dut.exited_q[1][SubCluster])
            $fatal(1, "A%0d: own EXIT was not preserved", ExitCase);
        if (ExitCase == 5 && (remote_export_count[0] != 0 || gen_dut[0].i_dut.export_push))
            $fatal(1, "A5: exit was exported");
    end
    $display("Exit absorption A%0d passed", ExitCase);
    $finish;
end
