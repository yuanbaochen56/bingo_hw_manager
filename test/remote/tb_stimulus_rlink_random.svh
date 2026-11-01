// =============================================================================
// Level 3 over the real transport: random graphs, random fault
// =============================================================================
// Two chiplets, 3 cores of distinct types (no local substitute), exports
// through remote_link with random stalls. Chiplet c gets N_TASKS[c] normal
// tasks on random cores (ids 1.. on chiplet 0, 101.. on chiplet 1), each may
// depend on one earlier task of its chiplet (unique tag per dep-matrix cell,
// at most one consumer per task). One random task of chiplet 0 gets a random
// fault (hang / zombie / slow) on its core: the tasks of a fenced core run on
// chiplet 1. The harness checks retire order, done order per proxy slot and
// the link errors.
// EXPECTED: all tasks complete.
//
// TB_RR_TWO_FAULTS: a hang on a random task of each chiplet. When both dead
// cores have the same type, each chiplet rejects the other's exports (at
// import, or by bouncing them). Not every task can complete then; after the
// run goes quiet the stimulus checks that the link is idle, that every export
// got a done or a reject, and that every unfinished task is explained: its
// logical core is stuck / rejected, an earlier task of its core is unfinished,
// or it depends on an unfinished task.

localparam int unsigned N_TASKS_0               = 24;
localparam int unsigned N_TASKS_1               = 12;
`ifdef TB_RR_TWO_FAULTS
localparam int unsigned EXPECTED_TASK_COUNT     = 999;   // finished by rr_two_faults_check
localparam int unsigned DEADLOCK_THRESHOLD      = 1000000;
`else
localparam int unsigned EXPECTED_TASK_COUNT     = N_TASKS_0 + N_TASKS_1;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
`endif
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t rr_tasks [2][N_TASKS_0 + 1];
int unsigned                      rr_core_of [2][N_TASKS_0 + 1];
int unsigned                      rr_dep_of  [2][N_TASKS_0 + 1];  // producer index, 0: none

task automatic rr_graph(input int chip, input int unsigned n, input int unsigned id_base);
    automatic bit          has_cons  [N_TASKS_0 + 1];
    automatic int unsigned cell_tags [NUM_CORES_PER_CLUSTER][NUM_CORES_PER_CLUSTER];
    automatic int unsigned n_edges = 0;
    for (int r = 0; r < NUM_CORES_PER_CLUSTER; r++)
        for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) cell_tags[r][c] = 0;
    for (int unsigned i = 1; i <= n; i++) begin
        rr_core_of[chip][i] = $urandom_range(0, NUM_CORES_PER_CLUSTER - 1);
        has_cons[i] = 1'b0;
        rr_dep_of[chip][i] = 0;
        rr_tasks[chip][i] = pack_normal_task(2'b00, bingo_hw_manager_task_id_t'(id_base + i),
                                             bingo_hw_manager_assigned_chiplet_id_t'(chip), 0,
                                             bingo_hw_manager_assigned_core_id_t'(rr_core_of[chip][i]),
                                             1'b0, '0, 1'b0, 1'b0, bingo_hw_manager_assigned_chiplet_id_t'(chip), 0, '0);
    end
    for (int unsigned i = 2; i <= n; i++) begin
        if ($urandom_range(0, 99) < 70) begin
            automatic int unsigned j   = $urandom_range(1, i - 1);
            automatic int unsigned row = rr_core_of[chip][i];
            automatic int unsigned col = rr_core_of[chip][j];
            if (!has_cons[j] && (cell_tags[row][col] < (1 << DEP_TAG_WIDTH))) begin
                automatic bingo_hw_manager_dep_tag_t tag = bingo_hw_manager_dep_tag_t'(cell_tags[row][col]);
                cell_tags[row][col]++;
                has_cons[j] = 1'b1;
                rr_dep_of[chip][i] = j;
                n_edges++;
                rr_tasks[chip][j].dep_set_info.dep_set_en      = 1'b1;
                rr_tasks[chip][j].dep_set_info.dep_set_code    = bingo_hw_manager_dep_code_t'(1 << row);
                rr_tasks[chip][j].dep_set_info.dep_set_tag     = tag;
                rr_tasks[chip][i].dep_check_info.dep_check_en   = 1'b1;
                rr_tasks[chip][i].dep_check_info.dep_check_code = bingo_hw_manager_dep_code_t'(1 << col);
                rr_tasks[chip][i].dep_check_info.dep_check_tag  = tag;
            end
        end
    end
    $display("[RANDOM] chiplet %0d: %0d tasks, %0d edges", chip, n, n_edges);
endtask

initial begin : random_graph
    rr_graph(0, N_TASKS_0, 0);
    rr_graph(1, N_TASKS_1, 100);
    fault_task_id = $urandom_range(1, N_TASKS_0);
    fault_core    = rr_core_of[0][fault_task_id];   // flat id on chiplet 0
`ifdef TB_RR_TWO_FAULTS
    fault_mode     = FAULT_HANG;
    fault2_task_id = $urandom_range(1, N_TASKS_1);
    fault2_core    = NUM_CORES_PER_CLUSTER + rr_core_of[1][fault2_task_id];  // flat id on chiplet 1
    fault2_task_id = 100 + fault2_task_id;
    $display("[RANDOM] %0d tasks; hang on task %0d (chiplet 0 core %0d) and task %0d (chiplet 1 core %0d)",
             N_TASKS_0 + N_TASKS_1, fault_task_id, fault_core, fault2_task_id,
             fault2_core - NUM_CORES_PER_CLUSTER);
`else
    fault_mode    = $urandom_range(0, 2);
    $display("[RANDOM] %0d tasks; fault mode %0d on task %0d (chiplet 0 core %0d)",
             EXPECTED_TASK_COUNT, fault_mode, fault_task_id, fault_core);
`endif
end

for (genvar gc = 0; gc < 2; gc++) begin : gen_rr_push
    initial begin
        automatic axi_pkg::resp_t resp;
        wait (rst_ni);
        repeat (20) @(posedge clk_i);
        for (int unsigned i = 1; i <= ((gc == 0) ? N_TASKS_0 : N_TASKS_1); i++) begin
            task_queue_master[gc].write(task_queue_base[gc], '0, rr_tasks[gc][i], '1, resp);
        end
    end
end

`ifdef TB_RR_TWO_FAULTS
initial begin : rr_two_faults_check
    automatic int unsigned last_count = 0, quiet = 0, n_open = 0;
    automatic bit          open_t [2][N_TASKS_0 + 1];
    automatic bit          changed;
    wait (rst_ni);
    // Run until nothing completes and the link is idle for a while
    for (int unsigned cyc = 0; cyc < 200000; cyc++) begin
        @(posedge clk_i);
        if ((completed_task_count != last_count) || rd_valid[0] || rd_valid[1] || rd_in_valid[0] ||
            rd_in_valid[1] || rdn_valid[0] || rdn_valid[1] || rdn_in_valid[0] || rdn_in_valid[1]) begin
            last_count = completed_task_count;
            quiet = 0;
        end else if (++quiet == 6000) begin
            break;
        end
    end
    if (quiet < 6000) $error("[RANDOM2] the run did not go quiet");
    // Unfinished tasks must be explained (fixed point)
    for (int c = 0; c < 2; c++)
        for (int unsigned i = 1; i <= ((c == 0) ? N_TASKS_0 : N_TASKS_1); i++)
            open_t[c][i] = !task_completed_bitmap[(c == 0) ? i : 100 + i];
    for (int c = 0; c < 2; c++) begin
        automatic int unsigned n = (c == 0) ? N_TASKS_0 : N_TASKS_1;
        automatic bit expl [N_TASKS_0 + 1];
        for (int unsigned i = 1; i <= n; i++) expl[i] = 1'b0;
        do begin
            changed = 1'b0;
            for (int unsigned i = 1; i <= n; i++) begin
                automatic int unsigned core = rr_core_of[c][i];
                automatic bit why = 1'b0;
                if (!open_t[c][i] || expl[i]) continue;
                if (stuck_slot_export[c][core][0] || remote_rejected_export[c][core][0]) why = 1'b1;
                if ((rr_dep_of[c][i] != 0) && open_t[c][rr_dep_of[c][i]] && expl[rr_dep_of[c][i]]) why = 1'b1;
                for (int unsigned j = 1; j < i; j++)
                    if ((rr_core_of[c][j] == core) && open_t[c][j] && expl[j]) why = 1'b1;
                if (why) begin
                    expl[i] = 1'b1;
                    changed = 1'b1;
                end
            end
        end while (changed);
        for (int unsigned i = 1; i <= n; i++) begin
            if (open_t[c][i]) n_open++;
            if (open_t[c][i] && !expl[i]) begin
                $error("[RANDOM2] chiplet %0d task %0d (core %0d) is unfinished without a stuck / rejected cause",
                       c, (c == 0) ? i : 100 + i, rr_core_of[c][i]);
            end
        end
        if (remote_done_in_count[c] != remote_export_count[c]) begin
            $error("[RANDOM2] chiplet %0d: %0d exports, %0d dones + rejects back", c,
                   remote_export_count[c], remote_done_in_count[c]);
        end
    end
    $display("[RANDOM] exported %0d / %0d, rejects %0d / %0d, unfinished %0d, stuck %b %b, rejected %b %b",
             remote_export_count[0], remote_export_count[1], remote_rejects[0].size(), remote_rejects[1].size(),
             n_open, stuck_slot_export[0], stuck_slot_export[1], remote_rejected_export[0], remote_rejected_export[1]);
    $display("SIMULATION PASSED (two faults, liveness check)");
    $finish;
end
`else
final begin
    if (fault_mode == FAULT_SLOW) begin
        if (fenced_export[0] !== '0) $error("[RANDOM] slow core must not be fenced");
        if (remote_export_count[0] != 0) $error("[RANDOM] slow core: no export expected, got %0d", remote_export_count[0]);
    end else begin
        if (retired_export[0][fault_core][0] !== 1'b1) $error("[RANDOM] faulty core %0d must be retired", fault_core);
        if (remote_export_count[0] == 0) $error("[RANDOM] the faulty task must be exported");
    end
    if (remote_done_in_count[0] != remote_export_count[0]) begin
        $error("[RANDOM] %0d exports, %0d dones back", remote_export_count[0], remote_done_in_count[0]);
    end
    if (fenced_export[1] !== '0) $error("[RANDOM] chiplet 1 must not fence a core");
    $display("[RANDOM] exported %0d, credit stall %0d cycles, max outstanding %0d",
             remote_export_count[0], remote_credit_stall[0], remote_max_outstanding[0]);
end
`endif
