localparam int unsigned EXPECTED_TASK_COUNT     = 999;
localparam int unsigned DEADLOCK_THRESHOLD      = 100000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

typedef logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] rp_slots_t;

function automatic bingo_hw_manager_task_desc_full_t rp_task(input int id, input int cl, input int core);
    return pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id), 0, cl, core, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
endfunction

task automatic rp_expect(input string step, input rp_slots_t expected);
    if (gen_dut[0].i_dut.ready_queue_pending_o !== expected)
        $fatal(1, "[READY_PENDING] %s: pending=%b expected=%b", step,
               gen_dut[0].i_dut.ready_queue_pending_o, expected);
    if (gen_dut[0].i_dut.ready_queue_pending_o !== ~gen_dut[0].i_dut.ready_queue_empty)
        $fatal(1, "[READY_PENDING] %s: output differs from the queue state", step);
endtask

initial begin : ready_pending_test
    automatic axi_pkg::resp_t resp;
    automatic device_axi_lite_data_t id, other;
    automatic rp_slots_t want;

    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    rp_expect("after reset", '0);
    // Two tasks for the future victim (cluster 0 core 0), one for cluster 1 core 2.
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(1, 0, 0), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(2, 0, 0), '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, rp_task(3, 1, 2), '1, resp);
    repeat (50) @(posedge clk_i);
    want = '0;
    want[0][0] = 1'b1;
    want[2][1] = 1'b1;
    rp_expect("queued", want);
    // A read pops one entry; the victim keeps task 2 queued and never beats.
    csr_read(0, 0, 0, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 1) $fatal(1, "[READY_PENDING] expected task 1, got %0d", id[TaskIdWidth-1:0]);
    repeat (5) @(posedge clk_i);
    rp_expect("one popped", want);
    csr_read(0, 1, 2, CSR_READY, id);
    if (id[TaskIdWidth-1:0] != 3) $fatal(1, "[READY_PENDING] expected task 3, got %0d", id[TaskIdWidth-1:0]);
    csr_done(0, 1, 2, 3);
    repeat (5) @(posedge clk_i);
    want[2][1] = 1'b0;
    rp_expect("drained by a read", want);
    // Fence: tasks 1 and 2 move to the same-type substitute (cluster 0 core 1).
    wait (fenced_export[0][0][0]);
    repeat (50) @(posedge clk_i);
    want = '0;
    want[1][0] = 1'b1;
    rp_expect("replayed to the substitute", want);
    csr_read(0, 0, 1, CSR_READY, id);
    csr_done(0, 0, 1, id[TaskIdWidth-1:0]);
    csr_read(0, 0, 1, CSR_READY, other);
    csr_done(0, 0, 1, other[TaskIdWidth-1:0]);
    if ({id[TaskIdWidth-1:0], other[TaskIdWidth-1:0]} != {TaskIdWidth'(1), TaskIdWidth'(2)})
        $fatal(1, "[READY_PENDING] substitute ran %0d, %0d", id[TaskIdWidth-1:0], other[TaskIdWidth-1:0]);
    repeat (5) @(posedge clk_i);
    rp_expect("all drained", '0);
    $display("Ready pending test passed");
    $finish;
end
