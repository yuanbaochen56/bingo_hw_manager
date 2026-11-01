// =============================================================================
// The substitute of a parked core dies
// =============================================================================
// Core workers on, all cores of one type. Core 0 is parked before any task
// (its substitute: core 1). Logical core 0 then gets tasks 1..10: tasks 1..8
// fill core 1's checkout queue, 9 and 10 wait in front of it. Core 1 hangs on
// task 1 and is fenced. With a third core, the entry of the parked core 0 is
// recomputed to core 2 and it stays PARKED; with two cores nothing is left, the
// park fails and the entry points back at core 0. Either way core 1's entries
// (tasks 1..8 of logical core 0) are replayed onto the new target, and tasks 9
// and 10 must wait for that replay instead of overtaking it: the harness checks
// that logical core 0 retires 1..10 in order.

localparam int unsigned EXPECTED_TASK_COUNT     = 10;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;
localparam int unsigned PSF_TARGET              = (NUM_CORES_PER_CLUSTER > 2) ? 2 : 0;

initial begin : park_sub_fence_test
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    park_req[0] = 32'd1;
    fork : wait_parked
        wait (gen_dut[0].i_dut.park.parked[0][0] === 1'b1);
        begin
            repeat (200) @(posedge clk_i);
            $fatal(1, "core 0 did not become PARKED");
        end
    join_any
    disable wait_parked;
    if (gen_dut[0].i_dut.smt.core[0][0] !== 1) $fatal(1, "core 0 parked onto core %0d, expected 1", gen_dut[0].i_dut.smt.core[0][0]);
    for (int i = 1; i <= 10; i++) begin
        task_queue_master[0].write(task_queue_base[0], '0,
            pack_normal_task(2'b00, i, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0), '1, resp);
    end
end

// With nothing left, the slot leaves PARKED and fails on the same edge (not
// through NONE, HOLD or a later fail at once)
logic psf_parked_q = 1'b0;
always @(posedge clk_i) begin : park_sub_fence_fail_edge
    psf_parked_q <= $sampled(gen_dut[0].i_dut.park.parked[0][0]);
    if (PSF_TARGET == 0 && psf_parked_q === 1'b1 && $sampled(gen_dut[0].i_dut.park.parked[0][0]) === 1'b0 &&
        $sampled(gen_dut[0].i_dut.park.fail[0][0]) !== 1'b1)
        $error("[PARK_SUB] no substitute left: core 0 left PARKED without failing on that edge");
end

initial begin : park_sub_fence_check
    wait (rst_ni);
    wait (gen_dut[0].i_dut.core_fenced[1][0] === 1'b1);
    repeat (5) @(posedge clk_i);
    if (gen_dut[0].i_dut.smt.core[0][0] !== PSF_TARGET)
        $error("[PARK_SUB] logical core 0 now goes to core %0d, expected %0d", gen_dut[0].i_dut.smt.core[0][0], PSF_TARGET);
    if (PSF_TARGET == 0) begin
        if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b0 || park_fail[0][0] !== 1'b1)
            $error("[PARK_SUB] no substitute left: expected the park to fail (parked %0b fail %0b)",
                   gen_dut[0].i_dut.park.parked[0][0], park_fail[0][0]);
    end else if (gen_dut[0].i_dut.park.parked[0][0] !== 1'b1) begin
        $error("[PARK_SUB] core 0 left PARKED although core 2 is live");
    end
    $display("[PARK_SUB] %0t core 1 fenced; logical core 0 -> core %0d, parked %0b fail %0b", $time,
             gen_dut[0].i_dut.smt.core[0][0], gen_dut[0].i_dut.park.parked[0][0], park_fail[0][0]);
end
