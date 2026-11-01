// Capacity-policy boundaries at the control-plane interface. The full-manager
// boost_capacity test covers checkout load, replay and the resulting PM levels.
`timescale 1ns/1ps

module tb_bingo_hw_manager_boost_capacity_edges;
    logic clk_i = 1'b0;
    logic rst_ni = 1'b0;
    always #5 clk_i = ~clk_i;

    // Three type-1 slots, two type-2 slots and a host slot (type 0).
    localparam logic [5:0][0:0][3:0] CoreTypeId =
        {4'd0, 4'd2, 4'd2, 4'd1, 4'd1, 4'd1};
    logic [5:0][0:0] fenced, waiting, stuck, rejected, park_req, late, risk_clear;
    logic [5:0][0:0][3:0] load;
    logic [5:0][0:0][5:0] slot_domain;
    logic [31:0][7:0] domain_level;
    logic [3:0] risk_thresh, boost_credit;
    logic [1:0] risk_action;
    logic boost_policy;
    logic [7:0] boost_load_min;
    logic [5:0][0:0] pm_boost, pm_derate, risk, parked;

    // The control plane under test; its port structs (bingo_hw_manager/typedef.svh)
    `include "bingo_hw_manager/typedef.svh"
    `BINGO_HW_MANAGER_TYPEDEF_CTRL_ALL(6, 1, 3, 1, 4, 4)
    ctrl_view_t view;
    park_t park;
    assign pm_boost  = view.boost;
    assign pm_derate = view.derate;
    assign risk      = view.risk;
    assign parked    = park.parked;

    bingo_hw_manager_ctrl #(
        .NumCores(6),
        .NumClusters(1),
        .CoreIdWidth(3),
        .ClusterIdWidth(1),
        .CoreTypeIdWidth(4),
        .CoreTypeId(CoreTypeId),
        .LoadWidth(4),
        .slot_state_t(slot_state_t),
        .ctrl_queue_t(ctrl_queue_t),
        .ctrl_host_t(ctrl_host_t),
        .ctrl_view_t(ctrl_view_t),
        .type_cfg_t(type_cfg_t),
        .smt_t(smt_t),
        .park_t(park_t),
        .cerf_fb_t(cerf_fb_t)
    ) i_ctrl (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .slot_i('{fenced:   fenced,
                  stuck:    stuck,
                  rejected: rejected,
                  default:  '0}),
        .late_i(late),
        .queue_i('{waiting: waiting, load: load,
                   checkout_empty: '1, ready_empty: '1, default: '0}),
        .host_i('{park_req: park_req, risk_clear: risk_clear, domain: slot_domain}),
        .type_cfg_i('0),
        .cfg_i('{risk_thresh:    risk_thresh,
                 risk_action:    risk_action,
                 boost_policy:   boost_policy,
                 boost_credit:   boost_credit,
                 boost_load_min: boost_load_min,
                 sub:            bingo_hw_manager_pkg::SubCfgDefault,
                 default:        '0}),
        .pm_i('{enable:       1'b1,
                dvfs:         1'b0,
                normal_level: 8'd6,
                dvfs_level:   8'd6,
                domain_level: domain_level,
                default:      '0}),
        .cluster_access_i(1'b0), .cerf_fb_done_i(1'b0),
        .view_o(view),
        .smt_o(),
        .smt_update_o(),
        .park_o(park),
        .cerf_fb_o(),
        .cerf_fb_evt_o()
    );

    task automatic settle();
        repeat (8) @(negedge clk_i);
    endtask

    task automatic expect_boost(input string step, input logic [5:0] expected);
        settle();
        if (pm_boost !== expected)
            $fatal(1, "[BOOSTEDGE] %s: boost %b, expected %b", step, pm_boost, expected);
    endtask

    task automatic reset_case();
        @(negedge clk_i);
        rst_ni = 1'b0;
        fenced = '0;
        stuck = '0;
        rejected = '0;
        waiting = '1;
        waiting[1][0] = 1'b0;
        waiting[2][0] = 1'b0;
        waiting[4][0] = 1'b0;
        load = {6{4'd1}};
        domain_level = {32{8'd6}};
        slot_domain[0][0] = 6'd0;
        slot_domain[1][0] = 6'd1;
        slot_domain[2][0] = 6'd2;
        slot_domain[3][0] = 6'd0;
        slot_domain[4][0] = 6'd3;
        slot_domain[5][0] = 6'd1;
        park_req = '0;
        late = '0;
        risk_clear = '0;
        risk_thresh = '0;
        risk_action = '0;
        boost_policy = 1'b1;
        boost_credit = 4'd1;
        boost_load_min = '0;
        repeat (2) @(negedge clk_i);
        rst_ni = 1'b1;
        settle();
    endtask

    initial begin
        reset_case();
        expect_boost("healthy capacity", 6'b000000);
        fenced[0][0] = 1'b1;
        expect_boost("one loss, lowest domain first", 6'b000010);
        boost_credit = 4'd2;
        expect_boost("two credits per lost slot", 6'b000110);
        boost_credit = 4'd0;
        expect_boost("unlimited excludes unrelated type", 6'b000110);

        reset_case();
        fenced[0][0] = 1'b1;
        fenced[3][0] = 1'b1;
        expect_boost("two types lost, credit 1 gives two domains", 6'b000110);
        boost_credit = 4'd2;
        expect_boost("two types lost, credit 2 gives all three domains", 6'b010110);
        boost_policy = 1'b0;
        expect_boost("legacy policy only boosts SMT substitutes", 6'b010010);

        reset_case();
        fenced[0][0] = 1'b1;
        stuck[0][0] = 1'b1;
        rejected[0][0] = 1'b1;
        expect_boost("three lost reasons on one slot count once", 6'b000010);
        // Fences are sticky until reset. Exercise the other loss reasons in
        // fresh cases rather than violating the mapping-table contract.
        reset_case();
        stuck[0][0] = 1'b1;
        waiting[0][0] = 1'b0;
        expect_boost("stuck alone is lost and cannot boost itself", 6'b000010);
        reset_case();
        rejected[0][0] = 1'b1;
        waiting[0][0] = 1'b0;
        expect_boost("rejected alone is lost and cannot boost itself", 6'b000010);

        reset_case();
        fenced[0][0] = 1'b1;
        slot_domain[2][0] = 6'd1;
        expect_boost("shared domain spends one credit", 6'b000110);
        fenced[3][0] = 1'b1;
        expect_boost("shared domain leaves the second credit for another type", 6'b010110);
        reset_case();
        fenced[0][0] = 1'b1;
        slot_domain[2][0] = 6'd1;
        waiting[1][0] = 1'b1;
        expect_boost("polling slot is not a candidate", 6'b000100);
        slot_domain[2][0] = 6'd32;
        expect_boost("unmapped slot does not alias domain 0", 6'b000000);
        slot_domain[2][0] = 6'd31;
        expect_boost("highest valid domain", 6'b000100);

        reset_case();
        fenced[0][0] = 1'b1;
        load[2][0] = 4'd2;
        boost_load_min = 8'd2;
        expect_boost("minimum load is inclusive", 6'b000100);
        boost_load_min = 8'd3;
        expect_boost("below minimum load", 6'b000000);
        boost_load_min = 8'd16;
        expect_boost("minimum load is not truncated to load width", 6'b000000);
        boost_load_min = 8'd0;
        load[1][0] = '0;
        expect_boost("minimum zero ignores load", 6'b000010);

        reset_case();
        fenced[0][0] = 1'b1;
        risk_thresh = 4'd1;
        risk_action = 2'b10;
        late[5][0] = 1'b1;
        @(negedge clk_i);
        late = '0;
        settle();
        if (!pm_derate[5][0]) $fatal(1, "[BOOSTEDGE] shared domain did not derate");
        expect_boost("derated domain is skipped, not charged a credit", 6'b000100);
        risk_clear[5][0] = 1'b1;
        @(negedge clk_i);
        risk_clear = '0;
        expect_boost("risk clear restores lowest-domain priority", 6'b000010);

        reset_case();
        park_req[0][0] = 1'b1;
        settle();
        if (!parked[0][0]) $fatal(1, "[BOOSTEDGE] host park did not complete");
        expect_boost("ordinary host park adds no fault credit", 6'b000000);

        reset_case();
        risk_thresh = 4'd1;
        late[0][0] = 1'b1;
        @(negedge clk_i);
        late = '0;
        settle();
        expect_boost("at-risk alone adds no parking credit", 6'b000000);
        risk_action = 2'b01;
        settle();
        if (!risk[0][0] || !parked[0][0])
            $fatal(1, "[BOOSTEDGE] at-risk slot did not park");
        waiting[0][0] = 1'b0;
        expect_boost("at-risk parked slot grants credit, never boosts itself", 6'b000010);
        risk_clear[0][0] = 1'b1;
        @(negedge clk_i);
        risk_clear = '0;
        expect_boost("risk clear withdraws parking credit", 6'b000000);

        $display("Capacity boost edge test passed");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "[BOOSTEDGE] test timed out");
    end
endmodule
