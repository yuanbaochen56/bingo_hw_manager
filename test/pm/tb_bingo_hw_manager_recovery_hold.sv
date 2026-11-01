`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "bingo_hw_manager/typedef.svh"
module tb_bingo_hw_manager_recovery_hold;
    typedef logic [47:0] addr_t;
    typedef logic [63:0] data_t;
    typedef logic [7:0] strb_t;
    `AXI_LITE_TYPEDEF_ALL(bus, addr_t, data_t, strb_t)
    logic clk = 0, rst = 0;
    always #5 clk = ~clk;
    logic [3:0][0:0] fenced = '0, waiting = '1, retired = '0;
    logic [3:0][0:0] idle, active, access_only, found, load_clear, boost, tick_wd;
    logic [3:0][0:0][1:0] smt_core;
    logic [3:0][0:0][0:0] smt_cluster;
    logic [3:0][0:0][5:0] domains = {6'd4, 6'd3, 6'd2, 6'd1};
    logic [31:0] hold_cycles = 12;
    logic access = 0, update;
    logic [31:0][7:0] level;
    bus_req_t req;
    bus_resp_t resp;
    assign resp = '{aw_ready:1'b1, w_ready:1'b1, b_valid:1'b1,
                    b:'0, ar_ready:1'b1, r_valid:1'b1, r:'0};
    // Ready bus: IDLE selection plus four AW/W states takes five edges.
    // Four active domains give L_wake = 4 * 5 = 20 top-clock cycles.
    localparam int L_WAKE = 4 * 5;
    `BINGO_HW_MANAGER_TYPEDEF_PM_SLOT_T(pm_slot_t, 4, 1)
    bingo_hw_manager_pm #(
        .NUM_CLUSTERS_PER_CHIPLET(1), .NUM_CORES_PER_CLUSTER(4),
        .req_lite_t(bus_req_t), .resp_lite_t(bus_resp_t),
        .addr_t(addr_t), .data_t(data_t), .pm_slot_t(pm_slot_t)
    ) pm (
        .clk_i(clk), .rst_ni(rst),
        .cfg_i('{enable: 1'b1, idle_level: 8'd25, normal_level: 8'd6, default: '0}),
        .slot_i('{domain: domains, idle: idle, access_only: access_only, boost: boost, derate: '0}),
        .pm_base_addr_i(48'h1000), .dvfs_clint_msip_addr_i(48'd0),
        .dvfs_request_o(), .domain_level_o(level),
        .pm_axi_lite_req_o(req), .pm_axi_lite_resp_i(resp)
    );
    // The control plane under test; its port structs (bingo_hw_manager/typedef.svh)
    `include "bingo_hw_manager/typedef.svh"
    `BINGO_HW_MANAGER_TYPEDEF_CTRL_ALL(4, 1, 2, 1, 1, 4)
    ctrl_view_t view; smt_t smt;
    assign {idle, active, access_only} = {view.idle, view.rec_hold, view.access_only};
    assign {load_clear, tick_wd, boost} = {view.load_clear, view.wd_tick, view.boost};
    assign {found, smt_core, smt_cluster} = {smt.found, smt.core, smt.cluster};
    bingo_hw_manager_ctrl #(
        .NumCores(4), .NumClusters(1), .CoreIdWidth(2), .ClusterIdWidth(1), .CoreTypeIdWidth(1), .CoreTypeId(4'b0111),
        .slot_state_t(slot_state_t), .ctrl_queue_t(ctrl_queue_t), .ctrl_host_t(ctrl_host_t), .ctrl_view_t(ctrl_view_t),
        .type_cfg_t(type_cfg_t), .smt_t(smt_t), .park_t(park_t), .cerf_fb_t(cerf_fb_t)
    ) dut (
        .clk_i(clk), .rst_ni(rst), .slot_i('{fenced: fenced, retired: retired, default: '0}), .late_i('0),
        .queue_i('{waiting: waiting, checkout_empty: '1, ready_empty: '1, default: '0}), .host_i('{domain: domains, default: '0}),
        .type_cfg_i('0), .cfg_i('{access_hold: 32'd4, recovery_hold: hold_cycles, sub: bingo_hw_manager_pkg::SubCfgDefault, default: '0}), .cluster_access_i(access),
        .pm_i('{enable: 1'b1, dvfs: 1'b0, normal_level: 8'd6, dvfs_level: 8'd6, domain_level: '0, default: '0}), .cerf_fb_done_i(1'b0),
        .view_o(view), .smt_o(smt), .smt_update_o(update), .park_o(), .cerf_fb_o(), .cerf_fb_evt_o()
    );
    logic [31:0] cycle = 0, count, pop = 0;
    logic [3:0][0:0] seen = '0;
    logic [41:0] events;
    logic [41:0][15:0] args;
    logic [63:0] head;
    logic [15:0] dropped;
    logic move = 0;
    logic [63:0] expected[$];
    int starts = 0, ends = 0;
    bit [3:0] next_update = '0, woke = '0, cold = '0;
    int loaded_at[4], cold_windows = 0, hot_windows = 0;
    always_comb begin
        events = '0; args = '0;
        for (int c = 0; c < 4; c++) begin
            events[38+c] = active[c][0] != seen[c][0];
            args[38+c] = 16'(active[c][0]);
        end
    end
    bingo_hw_manager_evlog #(
        .NumCores(4), .NumClusters(1), .NumTypes(2), .Depth(32)
    ) logger (
        .clk_i(clk), .rst_ni(rst), .enable_i(1'b1), .clear_i(32'd0),
        .pop_i(pop), .event_i(events), .arg_i(args), .move_i(move),
        .move_code_i(8'h04), .move_slot_i(8'h00), .move_arg_i(16'd123),
        .head_o(head), .count_o(count), .dropped_o(dropped)
    );
    // Independent scoreboard: registered counter transitions after the edge
    // define the event time, including when MOVE delays logger arbitration.
    always @(posedge clk) begin
        if (!rst) begin
            cycle = 0; seen = '0; expected.delete();
            next_update = '0; woke = '0; cold = '0;
        end
        else begin
            automatic logic [3:0][0:0][31:0] previous = dut.i_power_view.rec_hold_q;
            automatic logic [31:0] edge_cycle = cycle;
            automatic logic [31:0][7:0] previous_level = level;
            // Inspect the target latched by the unmodified PM FSM, not just
            // the idle view. An update already in flight at load is inherited.
            if (pm.state_q == pm.IDLE && pm.update_req_valid &&
                next_update[pm.update_domain_id - 1]) begin
                if (pm.update_domain_target_level == 25)
                    $fatal(1, "[REC_HOLD] next PM update requested idle");
                next_update[pm.update_domain_id - 1] = 0;
            end
            if (move) expected.push_back({cycle, 8'h04, 8'h00, 16'd123});
            if (logger.write_fire) begin
                // Check after NBA so this edge's transitions are in the queue.
                automatic logic [63:0] item = logger.write_data;
                fork
                    begin
                        automatic int match = -1;
                        #2;
                        foreach (expected[k]) if (expected[k] === item && match < 0) match = k;
                        if (match < 0) $fatal(1, "[REC_HOLD] wrong event time/data %h", item);
                        expected.delete(match);
                    end
                join_none
            end
            seen <= active;
            cycle++;
            #1;
            for (int c = 0; c < 4; c++) begin
                // A hot domain may need no update at all until hold ends.
                // Its later idle request is outside the checked window.
                if (dut.i_power_view.rec_hold_q[c][0] == 0) next_update[c] = 0;
                if (previous[c][0] == 0 && dut.i_power_view.rec_hold_q[c][0] != 0) begin
                    loaded_at[c] = edge_cycle;
                    cold[c] = previous_level[c+1] == 25;
                    woke[c] = !cold[c];
                    next_update[c] = 1;
                    if (cold[c]) cold_windows++; else hot_windows++;
                end
                if (dut.i_power_view.rec_hold_q[c][0] != 0) begin
                    if (pm.i_policy.target_power_level[c+1] == 25)
                        $fatal(1, "[REC_HOLD] target idle while count nonzero");
                    if (level[c+1] != 25) woke[c] = 1;
                    if (woke[c] && level[c+1] == 25)
                        $fatal(1, "[REC_HOLD] applied idle after wake or in hot window");
                    if (cold[c] && !woke[c] && edge_cycle - loaded_at[c] >= L_WAKE)
                        $fatal(1, "[REC_HOLD] cold wake exceeded L_wake");
                end
                if ((previous[c][0] == 0) != (dut.i_power_view.rec_hold_q[c][0] == 0)) begin
                    automatic bit started = dut.i_power_view.rec_hold_q[c][0] != 0;
                    expected.push_back({edge_cycle, 8'h0c, 8'(c), 16'(started)});
                    if (started) starts++; else ends++;
                end
            end
            if (load_clear !== fenced || tick_wd !== '1)
                $fatal(1, "[REC_HOLD] changed load/watchdog view");
            if (boost !== '0) $fatal(1, "[REC_HOLD] polling hold created boost candidate");
            if (dropped) $fatal(1, "[REC_HOLD] logger dropped events");
        end
    end
    always @(negedge clk) if (count != 0) pop++;
    task automatic step;
        @(posedge clk); #3; @(negedge clk);
    endtask
    task automatic reset_ctrl;
        rst = 0; fenced = '0; retired = '0; access = 0;
        repeat (2) step(); rst = 1; repeat (2) step();
    endtask
    initial begin
        reset_ctrl();
        repeat (30) step();
        if (level[1] != 25) $fatal(1, "[REC_HOLD] cold case not idle");
        // Fence slot 2 -> slot 0. The SMT commits before hold is loaded.
        fenced[2][0] = 1; step();
        if (!idle[0][0] || dut.i_power_view.rec_hold_q[0][0] != 0)
            $fatal(1, "[REC_HOLD] loaded before the post-SMT edge");
        move = 1; step(); move = 0;
        if (dut.i_power_view.rec_hold_q[0][0] != 12 || idle[0][0] || !idle[2][0])
            $fatal(1, "[REC_HOLD] missing substitute hold or held victim");
        repeat (3) step();
        // Another logical slot shares the substitute, reloading without start.
        fenced[1][0] = 1; step(); step();
        if (dut.i_power_view.rec_hold_q[0][0] != 12 || starts != 1)
            $fatal(1, "[REC_HOLD] reload missing or emitted another start");
        access = 1; step(); access = 0;
        if (access_only[0][0]) $fatal(1, "[REC_HOLD] hold misclassified as access-only");
        repeat (10) begin
            if (idle[0][0]) $fatal(1, "[REC_HOLD] idle within W");
            step();
        end
        step();
        if (!idle[0][0] || dut.i_power_view.rec_hold_q[0][0] != 0 || ends != 1)
            $fatal(1, "[REC_HOLD] hold did not end at W");
        repeat (4) step();
        if (expected.size()) $fatal(1, "[REC_HOLD] events did not drain");
        if (next_update[0] || !woke[0])
            $fatal(1, "[REC_HOLD] cold case lacked a non-idle update");
        // No substitute (type 0 / exhausted local type, including L3/CERF).
        fenced[3][0] = 1; step(); step();
        fenced[0][0] = 1; step(); step();
        if (dut.i_power_view.rec_hold_q != 0) $fatal(1, "[REC_HOLD] held a missing substitute");
        hold_cycles = 0; reset_ctrl();
        fenced[2][0] = 1; repeat (16) step();
        if (dut.i_power_view.rec_hold_q != 0 || idle !== '1 || expected.size())
            $fatal(1, "[REC_HOLD] W=0 changed behavior");
        // Warm the substitute through existing access wake, then release it
        // only after recovery hold loads. Do not change product wake timing.
        hold_cycles = 32; reset_ctrl(); access = 1;
        repeat (30) step();
        if (level[1] != 6) $fatal(1, "[REC_HOLD] hot case not warm");
        fenced[2][0] = 1; step(); step(); access = 0;
        repeat (32) step();
        repeat (8) step();
        if (cold_windows == 0 || hot_windows == 0 || expected.size())
            $fatal(1, "[REC_HOLD] missing cold/hot coverage");
        // A logical slot retired by the post-SMT edge gets no hold.
        hold_cycles = '1; reset_ctrl();
        fenced[2][0] = 1; step(); retired[2][0] = 1; step();
        if (dut.i_power_view.rec_hold_q != 0) $fatal(1, "[REC_HOLD] held a retired logical slot");
        // Full 32-bit W loads without narrowing.
        fenced[1][0] = 1; step(); step();
        if (dut.i_power_view.rec_hold_q[0][0] !== 32'hffffffff)
            $fatal(1, "[REC_HOLD] W narrowed");
        fenced[0][0] = 1; step();
        if (dut.i_power_view.rec_hold_q[0][0] != 0 || !idle[0][0])
            $fatal(1, "[REC_HOLD] held a newly fenced substitute");
        repeat (5) step();
        if (expected.size()) $fatal(1, "[REC_HOLD] final events did not drain");
        $display("Recovery hold and exact event timestamps passed");
        $finish;
    end
endmodule
