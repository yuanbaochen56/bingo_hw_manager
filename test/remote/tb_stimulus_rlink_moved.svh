// =============================================================================
// Level 3: an imported task runs away from its own logical slot (moved)
// =============================================================================
// The remote dispatch of tb_stimulus_remote_dispatch.svh over the real
// transport: tasks 1, 2 and 7 of chiplet 0 are exported and run on core 0 of
// chiplet 1, next to chiplet 1's own tasks 11, 13 (core 0) and 12 (core 1).
// EXPECTED, besides the checks of that stimulus: on chiplet 1 the ready queue
// marks every imported task as moved and none of its own (bingo_hw_manager_ready_queue:
// an import that is no replay), and the watchdog latches that flag at the
// dispatch (wd_moved_q, read by bingo_hw_manager_wd_adapt for BINGO_WD_LATE[6]
// and [8:7]); on chiplet 0 nothing it runs is moved.
`include "tb_stimulus_remote_dispatch.svh"

int unsigned rm_dispatches [2][$];
int unsigned rm_imported   [$];    // dispatches of imported tasks on chiplet 1
for (genvar chip = 0; chip < 2; chip++) begin : gen_rlink_moved_monitor
    logic [2:0] check_core, check_moved;
    always @(negedge clk_i) begin
        if (rst_ni) begin
            // The flag latched at the dispatch one cycle earlier
            for (int core = 0; core < 3; core++) begin
                if (check_core[core] && gen_dut[chip].i_dut.wd_moved_q[core][0] !== check_moved[core])
                    $error("[RLINK_MOVED] chiplet %0d core %0d: wd_moved_q %b, expected %b", chip, core,
                           gen_dut[chip].i_dut.wd_moved_q[core][0], check_moved[core]);
            end
            check_core = '0;
            for (int core = 0; core < 3; core++) begin
                if (gen_dut[chip].i_dut.ready_queue_pop[core][0] && !gen_dut[chip].i_dut.done_q_push[core][0] &&
                    !gen_dut[chip].i_dut.core_fenced[core][0]) begin
                    automatic int unsigned id = gen_dut[chip].i_dut.ready_queue_data_out[core][0].task_id;
                    automatic logic imported = (chip == 1) && (id inside {1, 2, 7});
                    rm_dispatches[chip].push_back(id);
                    if (gen_dut[chip].i_dut.ready_moved[core][0] !== imported)
                        $error("[RLINK_MOVED] chiplet %0d core %0d task %0d: ready head moved %b, expected %b",
                               chip, core, id, gen_dut[chip].i_dut.ready_moved[core][0], imported);
                    if (imported) rm_imported.push_back(id);
                    check_core[core]  = 1'b1;
                    check_moved[core] = imported;
                end
            end
        end
    end
end

// Coverage only: the checks are the $error of every dispatch above; this one
// makes sure they saw the three imported tasks dispatched on chiplet 1
final begin
    if (rm_imported != '{1, 2, 7})
        $error("[RLINK_MOVED] imported dispatches on chiplet 1 %p, expected '{1, 2, 7}", rm_imported);
    else
        $display("[RLINK_MOVED] dispatches chiplet 0 %p, chiplet 1 %p; moved on chiplet 1: %p",
                 rm_dispatches[0], rm_dispatches[1], rm_imported);
end
