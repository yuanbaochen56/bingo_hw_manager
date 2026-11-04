// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Per-slot heartbeat watchdog.
//
// 1. Timer and busy state. One update per slot and cycle, the first that
//   applies (the numbered branches of the always_ff below):
//     (1) fenced > (2) done > (3) dispatch > (4) budget fence >
//     (5) heartbeat > (6) confirm timeout > (7) tick
//   A slot becomes busy on event_i.dispatch and idle on event_i.done. While
//   busy, timer_q counts event_i.tick pulses (normal-clock cycles from
//   bingo_hw_manager_wd_tick, saturating at all ones) and resets to 0 on
//   dispatch, heartbeat, or done.
//
// 2. Threshold comparisons (for monitored slots, CoreMask = 1)
//   suspect  timer_q >= suspect raises status_o.dead_suspect (reversible: a
//            later heartbeat or done resets timer_q; stays set once fenced)
//   confirm  timer_q >= confirm (with ConfirmTimeoutCycles != 0) latches
//            fenced_q until reset; the manager stops using the slot and replays
//            its tasks (bingo_hw_manager_replay_ctrl)
//   late     a heartbeat or done at timer_q >= late pulses status_o.late for
//            one cycle (fault precursor for bingo_hw_manager_risk)
//   budget   fence_req_i (bingo_hw_manager_wd_budget: the execution ran over its
//            total-time budget) fences a busy slot when fencing is on. Heartbeats
//            do not restart that budget, so a heartbeat in the same cycle does not
//            delay this fence; a done or dispatch in that cycle wins.
//
// 3. Threshold selection
//   bingo_hw_manager_wd_bounds decides every threshold (parameters, per core
//   type, learned by bingo_hw_manager_wd_adapt, or risk_confirm for an at-risk
//   slot) and gives the final values in bound_i (suspect_eff, confirm_eff,
//   late_eff; confirm_src for the log). This module only compares.
module bingo_hw_manager_watchdog #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CounterWidth = 24,
    parameter int unsigned HeartbeatTimeoutCycles = 100000,
    // Second, longer timeout after which a busy core without heartbeat is fenced
    // for good (sticky until reset): its outstanding tasks are then replayed on
    // another core. 0 disables fencing (detection only).
    parameter int unsigned ConfirmTimeoutCycles = 0,
    // Slots with CoreMask = 0 are never reported dead_suspect (e.g. a host slot
    // that does not send heartbeats, or a tied-off slot).
    parameter logic [NumCores-1:0][NumClusters-1:0] CoreMask = '1,
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter logic [NumCores-1:0][NumClusters-1:0][CoreTypeIdWidth-1:0] CoreTypeId = '0,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         wd_event_t = logic,
    parameter type         wd_bound_t = logic,
    parameter type         wd_status_t = logic
) (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  wd_event_t  event_i,   // dispatch, done, heartbeat, waiting, tick of every slot
    input  wd_bound_t  bound_i,   // thresholds (bingo_hw_manager_wd_bounds)
    // Fence requests of the total-time budget (bingo_hw_manager_wd_budget); 0: none
    input  logic [NumCores-1:0][NumClusters-1:0] fence_req_i = '0,
    output wd_status_t status_o
);
    localparam int unsigned MaxTimeoutCycles =
        (ConfirmTimeoutCycles > HeartbeatTimeoutCycles) ? ConfirmTimeoutCycles : HeartbeatTimeoutCycles;

    // The timer saturates at 2^CounterWidth-1, so the timeouts must fit in it;
    // otherwise the truncated compare value would silently shorten a timeout.
    if ($clog2(MaxTimeoutCycles + 1) > CounterWidth) begin : gen_counter_width_check
        initial begin
            $error("Watchdog timeout (%0d cycles) does not fit in a %0d-bit counter",
                   MaxTimeoutCycles, CounterWidth);
            $finish;
        end
    end
    // Fencing is irreversible, so it must come strictly after the reversible suspicion.
    if ((ConfirmTimeoutCycles != 0) && (ConfirmTimeoutCycles <= HeartbeatTimeoutCycles)) begin : gen_confirm_timeout_check
        initial begin
            $error("Watchdog confirm timeout (%0d) must exceed the heartbeat timeout (%0d)",
                   ConfirmTimeoutCycles, HeartbeatTimeoutCycles);
            $finish;
        end
    end

    // Internal registers to track core status and timers
    logic [CounterWidth-1:0] timer_q [NumCores][NumClusters];
    logic                    busy_q [NumCores][NumClusters];
    logic                    fenced_q [NumCores][NumClusters];

    // Watchdog logic: Update core status and timers
    always_comb begin
        for(int c=0; c<NumCores; c++) begin
            for(int cl=0; cl<NumClusters; cl++) begin
                status_o.busy[c][cl] = busy_q[c][cl];
                status_o.fenced[c][cl] = fenced_q[c][cl];
                // A fenced core stays dead_suspect, so the event log never shows a
                // fake recovery.
                status_o.dead_suspect[c][cl] = fenced_q[c][cl] ||
                                               (CoreMask[c][cl] && busy_q[c][cl] &&
                                                (timer_q[c][cl] >= bound_i.suspect_eff[c][cl]));
                status_o.available[c][cl] = event_i.waiting[c][cl] && !busy_q[c][cl] && !status_o.dead_suspect[c][cl];
                // Same priority as the timer update below: a fenced core is ignored
                status_o.late[c][cl] = (bound_i.late_eff[c][cl] != '0) && CoreMask[c][cl] && !fenced_q[c][cl] &&
                                       busy_q[c][cl] && (event_i.done[c][cl] || event_i.heartbeat[c][cl]) &&
                                       (timer_q[c][cl] >= bound_i.late_eff[c][cl]);
                // Matches done -> dispatch -> heartbeat priority. No fenced
                // interval or heartbeat concurrent with dispatch is learned.
                status_o.progress[c][cl] = CoreMask[c][cl] && !fenced_q[c][cl] && busy_q[c][cl] &&
                    (event_i.done[c][cl] || (!event_i.dispatch[c][cl] && event_i.heartbeat[c][cl]));
                status_o.interval[c][cl] = timer_q[c][cl];
            end
        end
    end

    // Sequential logic to update busy status and timers
    always_ff @(posedge clk_i or negedge rst_ni)begin
        if(!rst_ni) begin
            for (int c = 0; c < NumCores; c++) begin
                for (int cl = 0; cl < NumClusters; cl++) begin
                    busy_q[c][cl] <= 1'b0;
                    timer_q[c][cl] <= '0;
                    fenced_q[c][cl] <= 1'b0;
                end
            end
        end else begin
            for(int c=0; c<NumCores; c++) begin
                for(int cl=0; cl<NumClusters; cl++) begin
                    // (1) Fenced: ignore the core for good.
                    if (fenced_q[c][cl]) begin
                        busy_q[c][cl] <= 1'b0;
                        timer_q[c][cl] <= '0;
                    // (2) Done, (3) dispatch: the timer restarts
                    end else if(event_i.done[c][cl]) begin
                        busy_q[c][cl] <= 1'b0;
                        timer_q[c][cl] <= '0;
                    end else if(event_i.dispatch[c][cl]) begin
                        busy_q[c][cl] <= 1'b1;
                        timer_q[c][cl] <= '0;
                    end else if ((ConfirmTimeoutCycles != 0) && CoreMask[c][cl] && busy_q[c][cl] &&
                                 fence_req_i[c][cl]) begin
                        // (4) Over the total-time budget: before a heartbeat of this cycle
                        fenced_q[c][cl] <= 1'b1;
                        busy_q[c][cl] <= 1'b0;
                        timer_q[c][cl] <= '0;
`ifndef SYNTHESIS
                        $display("[BINGO_BUDGET_FENCE] %0t core=%0d cluster=%0d type=%0d class=%0d",
                                 $time, c, cl, CoreTypeId[c][cl], bound_i.wd_class[c][cl]);
`endif
                    end else if (event_i.heartbeat[c][cl]) begin
                        timer_q[c][cl] <= '0; // (5) Reset timer on heartbeat
                    end else if ((ConfirmTimeoutCycles != 0) && CoreMask[c][cl] && busy_q[c][cl] &&
                                 (timer_q[c][cl] >= bound_i.confirm_eff[c][cl])) begin
                        // (6) Confirm timeout. A done, dispatch or heartbeat in this
                        // cycle wins (branches above).
                        fenced_q[c][cl] <= 1'b1;
                        busy_q[c][cl] <= 1'b0;
                        timer_q[c][cl] <= '0;
`ifndef SYNTHESIS
                        if (bound_i.confirm_src[c][cl] == bingo_hw_manager_pkg::WdConfirmLearned)
                            $display("[BINGO_ADAPT_CONFIRM] %0t core=%0d cluster=%0d type=%0d class=%0d threshold=%0d",
                                     $time, c, cl, CoreTypeId[c][cl], bound_i.wd_class[c][cl], bound_i.confirm_eff[c][cl]);
                        else if (bound_i.confirm_src[c][cl] == bingo_hw_manager_pkg::WdConfirmRisk)
                            $display("[BINGO_RISK_CONFIRM] %0t core=%0d cluster=%0d threshold=%0d",
                                     $time, c, cl, bound_i.confirm_eff[c][cl]);
                        else if (bound_i.confirm_src[c][cl] == bingo_hw_manager_pkg::WdConfirmType)
                            $display("[BINGO_TYPE_CONFIRM] %0t core=%0d cluster=%0d type=%0d threshold=%0d",
                                     $time, c, cl, CoreTypeId[c][cl], bound_i.confirm_eff[c][cl]);
`endif
                    end else if (busy_q[c][cl] && event_i.tick[c][cl] && timer_q[c][cl] != {CounterWidth{1'b1}}) begin
                        timer_q[c][cl] <= timer_q[c][cl] + 1'b1; // (7) Increment timer if core is busy and no heartbeat
                    end
                end
            end
        end
    end

endmodule
