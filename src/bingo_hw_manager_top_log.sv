// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Simulation-only event log of bingo_hw_manager_top: prints the watchdog,
// parking, remap, replay and level 3 activity with [BINGO_*] tags, in any flow
// that simulates this RTL (bingo unit tests and full-system sims). Nothing here
// drives the design: slot_log_o only feeds bingo_hw_manager_top_assert.
//
// It reads the structs of the top, as bingo_hw_manager_top_assert does.
`ifndef SYNTHESIS
module bingo_hw_manager_top_log #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    parameter int unsigned TaskIdWidth = 12,
    parameter int unsigned RemoteSlotIdWidth = 3,
    parameter int unsigned OutstandingWidth = 1,
    parameter type         task_desc_t = logic,      // bingo_hw_manager_task_desc_t of the top
    parameter type         remote_export_t = logic,
    parameter type         chip_id_t = logic,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         slot_state_t = logic,
    parameter type         park_t = logic,
    parameter type         smt_t = logic,
    parameter type         waiting_t = logic,
    parameter type         route_t = logic,
    parameter type         checkout_t = logic,
    parameter type         replay_step_t = logic,
    parameter type         import_t = logic,
    parameter type         done_remote_t = logic,
    parameter type         proxy_t = logic
) (
    input  logic                                 clk_i,
    input  logic                                 rst_ni,
    input  chip_id_t                             chip_id_i,
    // Slots: their state, dead suspects, blocked replays
    input  slot_state_t                          slot_i,
    input  logic [NumCores-1:0][NumClusters-1:0] suspect_i,
    input  logic [NumCores-1:0][NumClusters-1:0] blocked_i,
    // Parking, the slot mapping table, tasks of each logical slot elsewhere
    input  park_t                                park_i,
    input  smt_t                                 smt_i,
    input  logic [OutstandingWidth-1:0]          outstanding_i [NumCores][NumClusters],
    // Queues and placement
    input  checkout_t                            checkout_i,
    input  waiting_t                             waiting_i,
    input  route_t                               route_i,
    // Replay step and its task
    input  replay_step_t                         step_i,
    input  task_desc_t                           replay_desc_i,
    // Level 3: exports, imports with the origin of the incoming dispatch
    input  logic                                 export_push_i,
    input  remote_export_t                       export_i,
    input  import_t                              imported_i,
    input  chip_id_t                             import_origin_chip_i,
    input  logic [RemoteSlotIdWidth-1:0]         import_proxy_slot_i,
    // Level 3: dones and rejects to the origin chiplets
    input  logic                                 done_out_valid_i,
    input  logic                                 done_out_ready_i,
    input  logic                                 done_out_reject_i,
    input  logic [TaskIdWidth-1:0]               done_out_task_id_i,
    input  chip_id_t                             done_out_chip_i,
    input  logic [RemoteSlotIdWidth-1:0]         done_out_proxy_slot_i,
    // Level 3: dones and rejects from the executing chiplets
    input  logic                                 done_in_valid_i,
    input  logic                                 done_in_ready_i,
    input  logic                                 done_in_reject_i,
    input  logic [TaskIdWidth-1:0]               done_in_task_id_i,
    input  logic [RemoteSlotIdWidth-1:0]         done_in_proxy_slot_i,
    input  done_remote_t                         done_remote_i,
    input  proxy_t                               proxy_i,
    // The slot state of the previous cycle (rejected is not tracked: 0)
    output slot_state_t                          slot_log_o
);
    // Previous values: a change or a rising edge is what gets printed
    logic [NumCores-1:0][NumClusters-1:0] suspect_q, fenced_q, retired_q, stuck_q, blocked_q;
    logic [NumCores-1:0][NumClusters-1:0] hold_q, parked_q, fail_q, unpark_q;
    assign slot_log_o = '{fenced:   fenced_q,
                          retired:  retired_q,
                          stuck:    stuck_q,
                          rejected: '0};

    always @(posedge clk_i or negedge rst_ni) begin : watchdog_remap_event_log
        if (!rst_ni) begin
            suspect_q <= '0;
            fenced_q  <= '0;
            retired_q <= '0;
            stuck_q   <= '0;
            blocked_q <= '0;
            hold_q    <= '0;
            parked_q  <= '0;
            fail_q    <= '0;
            unpark_q  <= '0;
        end else begin
            suspect_q <= suspect_i;
            hold_q    <= park_i.hold;
            parked_q  <= park_i.parked;
            fail_q    <= park_i.fail;
            unpark_q  <= park_i.unpark;
            fenced_q  <= slot_i.fenced;
            retired_q <= slot_i.retired;
            stuck_q   <= slot_i.stuck;
            blocked_q <= blocked_i;
            for (int unsigned c = 0; c < NumCores; c++) begin
                for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                    if (checkout_i.exit_absorb[c][cl]) begin
                        $display("[BINGO_EXIT_ABSORB] %0t chip=%0d task=%0d logical_core=%0d logical_cluster=%0d core=%0d cluster=%0d",
                                 $time, chip_id_i, checkout_i.push_desc[c][cl].task_id,
                                 checkout_i.push_desc[c][cl].assigned_core_id,
                                 checkout_i.push_desc[c][cl].assigned_cluster_id, c, cl);
                    end
                    if ((suspect_i[c][cl] != suspect_q[c][cl]) ||
                        (slot_i.fenced[c][cl] != fenced_q[c][cl])) begin
                        $display("[BINGO_WD] %0t chip=%0d core=%0d cluster=%0d dead_suspect=%0b fenced=%0b",
                                 $time, chip_id_i, c, cl, suspect_i[c][cl], slot_i.fenced[c][cl]);
                    end
                    if (park_i.hold[c][cl] && !hold_q[c][cl]) begin
                        $display("[BINGO_PARK] %0t chip=%0d core=%0d cluster=%0d HOLD",
                                 $time, chip_id_i, c, cl);
                    end
                    if (park_i.parked[c][cl] && !parked_q[c][cl]) begin
                        $display("[BINGO_PARK] %0t chip=%0d core=%0d cluster=%0d PARKED -> core=%0d cluster=%0d",
                                 $time, chip_id_i, c, cl, smt_i.core[c][cl], smt_i.cluster[c][cl]);
                    end
                    if (park_i.fail[c][cl] && !fail_q[c][cl]) begin
                        $display("[BINGO_PARK] %0t chip=%0d core=%0d cluster=%0d FAIL",
                                 $time, chip_id_i, c, cl);
                    end
                    if (park_i.unpark[c][cl] && !unpark_q[c][cl]) begin
                        $display("[BINGO_PARK] %0t chip=%0d core=%0d cluster=%0d UNPARK (%0d tasks left elsewhere)",
                                 $time, chip_id_i, c, cl, outstanding_i[c][cl]);
                    end
                    if (parked_q[c][cl] && !park_i.parked[c][cl] && unpark_q[c][cl] &&
                        !slot_i.fenced[c][cl] && !park_i.fail[c][cl]) begin
                        $display("[BINGO_PARK] %0t chip=%0d core=%0d cluster=%0d UNPARKED",
                                 $time, chip_id_i, c, cl);
                    end
                    if ((hold_q[c][cl] || parked_q[c][cl]) &&
                        !park_i.hold[c][cl] && !park_i.parked[c][cl] && slot_i.fenced[c][cl]) begin
                        $display("[BINGO_PARK] %0t chip=%0d core=%0d cluster=%0d dropped, fenced",
                                 $time, chip_id_i, c, cl);
                    end
                    if (slot_i.retired[c][cl] && !retired_q[c][cl]) begin
                        $display("[BINGO_RETIRED] %0t chip=%0d core=%0d cluster=%0d",
                                 $time, chip_id_i, c, cl);
                    end
                    if (slot_i.stuck[c][cl] && !stuck_q[c][cl]) begin
                        $display("[BINGO_REPLAY_STUCK] %0t chip=%0d core=%0d cluster=%0d: no live core may run task %0d (logical core %0d)",
                                 $time, chip_id_i, c, cl,
                                 checkout_i.head[c][cl].task_id,
                                 checkout_i.head[c][cl].assigned_core_id);
                    end
                    if (blocked_i[c][cl] && !blocked_q[c][cl]) begin
                        $display("[BINGO_REPLAY_BLOCKED] %0t chip=%0d core=%0d cluster=%0d task=%0d",
                                 $time, chip_id_i, c, cl, checkout_i.head[c][cl].task_id);
                    end
                    if (route_i.fire[c][cl] &&
                        ((route_i.src_core[c][cl] != CoreIdWidth'(c)) ||
                         (waiting_i.desc[route_i.src_core[c][cl]].assigned_cluster_id !=
                          ClusterIdWidth'(cl)))) begin
                        $display("[BINGO_REMAP] %0t chip=%0d task=%0d logical_core=%0d -> physical_core=%0d cluster=%0d logical_cluster=%0d",
                                 $time, chip_id_i,
                                 waiting_i.desc[route_i.src_core[c][cl]].task_id,
                                 route_i.src_core[c][cl], c, cl,
                                 waiting_i.desc[route_i.src_core[c][cl]].assigned_cluster_id);
                    end
                end
            end
            if (export_push_i) begin
                $display("[BINGO_EXPORT] %0t chip=%0d task=%0d type_id=%0d proxy_slot=%0d (replay %0b)",
                         $time, chip_id_i, export_i.desc.task_id, export_i.core_type,
                         export_i.proxy_slot, step_i.exported);
            end
            if (imported_i.fire) begin
                $display("[BINGO_IMPORT] %0t chip=%0d task=%0d from chip=%0d proxy_slot=%0d -> core=%0d cluster=%0d (home core=%0d cluster=%0d)",
                         $time, chip_id_i, imported_i.desc.task_id, import_origin_chip_i,
                         import_proxy_slot_i, imported_i.core, imported_i.cluster,
                         imported_i.home_core, imported_i.home_cluster);
            end
            if (done_out_valid_i && done_out_ready_i && !done_out_reject_i) begin
                $display("[BINGO_REMOTE_DONE_OUT] %0t chip=%0d task=%0d -> chip=%0d proxy_slot=%0d",
                         $time, chip_id_i, done_out_task_id_i, done_out_chip_i, done_out_proxy_slot_i);
            end
            if (done_in_valid_i && done_in_ready_i && !done_in_reject_i) begin
                $display("[BINGO_REMOTE_DONE_IN] %0t chip=%0d task=%0d proxy_slot=%0d",
                         $time, chip_id_i, done_in_task_id_i, done_in_proxy_slot_i);
            end
            if (imported_i.reject) begin
                $display("[BINGO_REMOTE_REJECT_OUT] %0t chip=%0d task=%0d -> chip=%0d proxy_slot=%0d (no live core of its type)",
                         $time, chip_id_i, imported_i.desc.task_id, import_origin_chip_i,
                         import_proxy_slot_i);
            end
            if (step_i.bounce) begin
                $display("[BINGO_REMOTE_REJECT_OUT] %0t chip=%0d task=%0d -> chip=%0d proxy_slot=%0d (its core died, no other live core)",
                         $time, chip_id_i, replay_desc_i.task_id,
                         checkout_i.head_tag[step_i.src_core][step_i.src_cluster].origin_chip,
                         checkout_i.head_tag[step_i.src_core][step_i.src_cluster].proxy_slot);
            end
            if (done_remote_i.stray) begin
                $display("[BINGO_REMOTE_DONE_DROP] %0t chip=%0d task=%0d proxy_slot=%0d reject=%0b: no proxy slot, dropped",
                         $time, chip_id_i, done_in_task_id_i, done_in_proxy_slot_i, done_in_reject_i);
            end
            if (|done_remote_i.reject) begin
                $display("[BINGO_REMOTE_REJECT_IN] %0t chip=%0d task=%0d proxy_slot=%0d: the proxy is stuck",
                         $time, chip_id_i, done_in_task_id_i, done_in_proxy_slot_i);
            end
            for (int unsigned c = 0; c < NumCores; c++) begin
                for (int unsigned cl = 0; cl < NumClusters; cl++) begin
                    if (proxy_i.timeout[c][cl]) begin
                        $display("[BINGO_REMOTE_TIMEOUT] %0t chip=%0d task=%0d proxy_slot=%0d: no remote done for %0d cycles, the proxy is stuck",
                                 $time, chip_id_i, checkout_i.head[c][cl].task_id,
                                 c + cl * NumCores, proxy_i.wait_cycles[c][cl]);
                    end
                end
            end
            if (step_i.fire && !step_i.bounce) begin
                $display("[BINGO_REPLAY] %0t chip=%0d task=%0d type=%0d logical_core=%0d from=%0d to=%0d cluster=%0d to_cluster=%0d logical_cluster=%0d",
                         $time, chip_id_i, replay_desc_i.task_id, replay_desc_i.task_type,
                         replay_desc_i.assigned_core_id, step_i.src_core, step_i.dst_core, step_i.src_cluster,
                         step_i.dst_cluster, replay_desc_i.assigned_cluster_id);
            end
        end
    end
endmodule
`endif
