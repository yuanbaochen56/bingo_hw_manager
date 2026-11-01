// =============================================================================
// Replay: random task graph with a random fault
// =============================================================================
// N_TASKS normal tasks on random cores, pushed in id order. Each task may
// depend on one earlier task (any core, including its own); each task has at
// most one consumer, and every edge gets a tag that is unique in its dep-matrix
// cell. One random task gets a random fault on its core:
//   HANG / ZOMBIE: the core is fenced, the task (and everything queued behind
//                  it) is replayed, later tasks of that core are remapped
//   SLOW:          silent between the two timeouts, no fence
// The harness checks that every task retires exactly once and in per-core
// order; the DUT assertions check the replay invariants.
// EXPECTED: all N_TASKS tasks complete.

localparam int unsigned N_TASKS                 = 40;
localparam int unsigned EXPECTED_TASK_COUNT     = N_TASKS;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t rnd_tasks [N_TASKS + 1];
int unsigned                      rnd_fault_task;

initial begin : random_graph
    automatic int unsigned core_of   [N_TASKS + 1];
    automatic bit          has_cons  [N_TASKS + 1];
    automatic int unsigned cell_tags [NUM_CORES_PER_CLUSTER][NUM_CORES_PER_CLUSTER];
    automatic int unsigned n_edges = 0;

    for (int r = 0; r < NUM_CORES_PER_CLUSTER; r++)
        for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) cell_tags[r][c] = 0;

    for (int unsigned i = 1; i <= N_TASKS; i++) begin
        core_of[i]  = $urandom_range(0, NUM_CORES_PER_CLUSTER - 1);
        has_cons[i] = 1'b0;
        rnd_tasks[i] = pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(i), 0, 0,
                                        bingo_hw_manager_assigned_core_id_t'(core_of[i]),
                                        1'b0, '0, 1'b0, 1'b0, 0, 0, '0);
    end
    for (int unsigned i = 2; i <= N_TASKS; i++) begin
        if ($urandom_range(0, 99) < 70) begin
            automatic int unsigned j   = $urandom_range(1, i - 1);
            automatic int unsigned row = core_of[i];
            automatic int unsigned col = core_of[j];
            if (!has_cons[j] && (cell_tags[row][col] < (1 << DEP_TAG_WIDTH))) begin
                automatic bingo_hw_manager_dep_tag_t tag = bingo_hw_manager_dep_tag_t'(cell_tags[row][col]);
                cell_tags[row][col]++;
                has_cons[j] = 1'b1;
                n_edges++;
                rnd_tasks[j].dep_set_info.dep_set_en      = 1'b1;
                rnd_tasks[j].dep_set_info.dep_set_code    = bingo_hw_manager_dep_code_t'(1 << row);
                rnd_tasks[j].dep_set_info.dep_set_tag     = tag;
                rnd_tasks[i].dep_check_info.dep_check_en   = 1'b1;
                rnd_tasks[i].dep_check_info.dep_check_code = bingo_hw_manager_dep_code_t'(1 << col);
                rnd_tasks[i].dep_check_info.dep_check_tag  = tag;
            end
        end
    end

    rnd_fault_task = $urandom_range(1, N_TASKS);
    fault_task_id  = rnd_fault_task;
    fault_core     = core_of[rnd_fault_task];
    fault_mode     = $urandom_range(0, 2);
    $display("[RANDOM] %0d tasks, %0d edges; fault mode %0d on task %0d (core %0d)",
             N_TASKS, n_edges, fault_mode, fault_task_id, fault_core);
end

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    repeat (20) @(posedge clk_i);
    for (int unsigned i = 1; i <= N_TASKS; i++) begin
        task_queue_master[0].write(task_queue_base[0], '0, rnd_tasks[i], '1, resp);
    end
end

// TB_RANDOM_PARK: the host sets and clears the park request of a random core
// (never the faulty one, so the fault still hits its own task) every 30..400
// cycles; parking, moving back, fences and replays then interleave freely
`ifndef TB_RANDOM_PARK
  `define TB_RANDOM_PARK 0
`endif
int unsigned rnd_parks = 0, rnd_unparks = 0, rnd_park_toggles = 0;
if (`TB_RANDOM_PARK != 0) begin : gen_random_park
    initial begin
        wait (rst_ni);
        repeat (20) @(posedge clk_i);
        while (completed_task_count < EXPECTED_TASK_COUNT) begin
            automatic int unsigned c;
            repeat ($urandom_range(30, 400)) @(posedge clk_i);
            c = $urandom_range(0, NUM_CORES_PER_CLUSTER - 1);
            if (c != fault_core) begin
                @(negedge clk_i);
                park_req[0][c] = ~park_req[0][c];
                rnd_park_toggles++;
            end
        end
    end
    logic [NUM_CORES_PER_CLUSTER-1:0] rnd_parked_q = '0, rnd_unpark_q = '0;
    always @(posedge clk_i) begin
        for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
            if (gen_dut[0].i_dut.park.parked[c][0] && !rnd_parked_q[c]) rnd_parks++;
            if (rnd_unpark_q[c] && !gen_dut[0].i_dut.park.parked[c][0] && !gen_dut[0].i_dut.core_fenced[c][0]) rnd_unparks++;
            rnd_parked_q[c] = gen_dut[0].i_dut.park.parked[c][0];
            rnd_unpark_q[c] = gen_dut[0].i_dut.park.unpark[c][0];
        end
    end
end

final begin
    if (`TB_RANDOM_PARK != 0) begin
        $display("[RANDOM] exported park: %0d toggles, %0d parks, %0d moves back", rnd_park_toggles, rnd_parks, rnd_unparks);
    end
    if (fault_mode == FAULT_SLOW) begin
        if (fenced_export[0] !== '0) $error("[RANDOM] slow core must not be fenced");
        if (replay_move_count[0] != 0) $error("[RANDOM] slow core: no replay expected, got %0d", replay_move_count[0]);
    end else begin
        if (retired_export[0][fault_core][0] !== 1'b1) $error("[RANDOM] faulty core %0d must be retired", fault_core);
        if (replay_move_count[0] == 0) $error("[RANDOM] the faulty task must be replayed");
    end
    if (fault_mode == FAULT_ZOMBIE && fence_drop_count[0] != 1) begin
        $error("[RANDOM] expected 1 dropped zombie done, got %0d", fence_drop_count[0]);
    end
    $display("[RANDOM] replayed %0d, remapped %0d, dropped %0d", replay_move_count[0], remap_count[0], fence_drop_count[0]);
end
