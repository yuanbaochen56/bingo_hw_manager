// =============================================================================
// Level 3: export from a full checkout queue, order across replay and remap
// =============================================================================
// Same system as remote_dispatch. Core 0 of chiplet 0 gets tasks 1..12 at
// once and hangs on task 1: its checkout queue fills up (8 entries) and tasks
// 9..12 wait in its waiting queue. The replay rotates the 8 outstanding
// entries of the full queue (pop + push in one cycle), then 9..12 are routed
// to the proxy as new tasks. Task 12 sets core 1 (task 20 checks it).
// EXPECTED: all 13 tasks complete; chiplet 1 imports 1..12 in order and runs
// them on its core 0; task 20 only starts after task 12.

localparam int unsigned EXPECTED_TASK_COUNT     = 13;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t fq [21];
initial begin
    for (int i = 1; i <= 11; i++) begin
        fq[i] = pack_normal_task(2'b00, i, 0, 0, 0, 1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
    fq[12] = pack_normal_task(2'b00, 12, 0, 0, 0, 1'b0, '0, 1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(3'b010));
    fq[20] = pack_normal_task(2'b00, 20, 0, 0, 1, 1'b1, bingo_hw_manager_dep_code_t'(3'b001), 1'b0, 1'b0, 0, 0, '0);
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int i = 1; i <= 12; i++) task_queue_master[0].write(task_queue_base[0], '0, fq[i], '1, resp);
    task_queue_master[0].write(task_queue_base[0], '0, fq[20], '1, resp);
end

int unsigned fq_imports [$];
bit          fq_rotate_full = 1'b0;
always @(posedge clk_i) begin
    if (rst_ni) begin
        if (gen_dut[1].i_dut.imported.fire) begin
            fq_imports.push_back(gen_dut[1].i_dut.imported.desc.task_id);
            if (gen_dut[1].i_dut.imported.core != 0) begin
                $error("[REMOTE_FULL] task %0d imported to core %0d", gen_dut[1].i_dut.imported.desc.task_id,
                       gen_dut[1].i_dut.imported.core);
            end
        end
        if (gen_dut[0].i_dut.replay_rotate && gen_dut[0].i_dut.checkout_queue_full[0][0]) fq_rotate_full = 1'b1;
        if (task_completed_bitmap[20] && !task_completed_bitmap[12]) $error("[REMOTE_FULL] task 20 before task 12");
    end
end

final begin
    automatic int unsigned exp [$];
    for (int i = 1; i <= 12; i++) exp.push_back(i);
    if (fq_imports != exp) $error("[REMOTE_FULL] imports %p, expected 1..12 in order", fq_imports);
    if (!fq_rotate_full) $error("[REMOTE_FULL] no rotation on a full checkout queue");
    if (gen_dut[0].i_dut.replay_stuck !== 1'b0) $error("[REMOTE_FULL] chiplet 0 must not be stuck");
    if (retired_export[0] !== 3'b001) $error("[REMOTE_FULL] core 0 of chiplet 0 not retired");
end
