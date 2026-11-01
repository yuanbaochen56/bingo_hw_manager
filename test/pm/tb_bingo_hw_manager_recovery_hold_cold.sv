`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "bingo_hw_manager/typedef.svh"
module tb_bingo_hw_manager_recovery_hold_cold;
    typedef logic [47:0] addr_t;
    typedef logic [63:0] data_t;
    typedef logic [7:0] strb_t;
    `AXI_LITE_TYPEDEF_ALL(bus, addr_t, data_t, strb_t)
    logic clk = 0, rst = 0;
    always #5 clk = ~clk;
    logic [0:0][1:0] fenced = '0, idle, rec, access_only;
    logic [0:0][1:0][5:0] ctrl_domains = {6'd2, 6'd1};
    logic [31:0][7:0] level;
    bus_req_t req;
    bus_resp_t resp;
    assign resp = '{aw_ready:1'b1, w_ready:1'b1, b_valid:1'b1,
                    b:'0, ar_ready:1'b1, r_valid:1'b1, r:'0};
    `include "bingo_hw_manager/typedef.svh" // port structs of the control plane under test
    `BINGO_HW_MANAGER_TYPEDEF_CTRL_ALL(1, 2, 1, 1, 1, 4)
    ctrl_view_t view;
    assign {idle, rec, access_only} = {view.idle, view.rec_hold, view.access_only};
    bingo_hw_manager_ctrl #(
        .NumCores(1), .NumClusters(2), .CoreIdWidth(1), .ClusterIdWidth(1),
        .CoreTypeIdWidth(1), .CoreTypeId(2'b11), .SubstituteLevelMask(3'b011),
        .slot_state_t(slot_state_t), .ctrl_queue_t(ctrl_queue_t), .ctrl_host_t(ctrl_host_t), .ctrl_view_t(ctrl_view_t),
        .type_cfg_t(type_cfg_t), .smt_t(smt_t), .park_t(park_t), .cerf_fb_t(cerf_fb_t)
    ) ctrl (
        .clk_i(clk), .rst_ni(rst), .slot_i('{fenced: fenced, default: '0}), .late_i('0),
        .queue_i('{waiting: '1, checkout_empty: '1, ready_empty: '1, default: '0}), .host_i('{domain: ctrl_domains, default: '0}),
        .type_cfg_i('0), .cfg_i('{recovery_hold: 32'd32, sub: bingo_hw_manager_pkg::SubCfgDefault, default: '0}), .cluster_access_i(2'b00), .cerf_fb_done_i(1'b0),
        .pm_i('{enable: 1'b1, dvfs: 1'b0, normal_level: 8'd6, dvfs_level: 8'd6, domain_level: level, default: '0}),
        .view_o(view), .smt_o(), .smt_update_o(), .park_o(), .cerf_fb_o(), .cerf_fb_evt_o()
    );
    `BINGO_HW_MANAGER_TYPEDEF_PM_SLOT_T(pm_slot_t, 1, 2)
    bingo_hw_manager_pm #(
        .NUM_CLUSTERS_PER_CHIPLET(2), .NUM_CORES_PER_CLUSTER(1),
        .req_lite_t(bus_req_t), .resp_lite_t(bus_resp_t), .addr_t(addr_t), .data_t(data_t),
        .pm_slot_t(pm_slot_t)
    ) pm (
        .clk_i(clk), .rst_ni(rst),
        .cfg_i('{enable: 1'b1, idle_level: 8'd25, normal_level: 8'd6, default: '0}),
        .slot_i('{domain: ctrl_domains, idle: idle, access_only: access_only, boost: '0, derate: '0}),
        .pm_base_addr_i(48'h1000), .dvfs_clint_msip_addr_i(48'd0), .dvfs_request_o(),
        .domain_level_o(level), .pm_axi_lite_req_o(req), .pm_axi_lite_resp_i(resp)
    );
    // IDLE selection, frequency AW/W, valid AW/W: 5 cycles per update.
    localparam int L_WAKE = 2 * 5;
    int cycle = 0, fence_cycle, first_normal = -1, load_cycle = -1;
    bit next_update = 0, update_seen = 0;
    always @(posedge clk) begin
        cycle++;
        if (next_update && pm.state_q == pm.IDLE && pm.update_req_valid &&
            pm.update_domain_id == 2) begin
            if (pm.update_domain_target_level == 25)
                $fatal(1, "[REC_HOLD] cold next update was idle");
            next_update = 0; update_seen = 1;
        end
        #1;
        if (fenced[0][0]) begin
            if (ctrl.i_power_view.rec_hold_q[0][1] == 32 && load_cycle < 0) begin
                load_cycle = cycle; next_update = 1;
            end
            if (level[2] == 6 && first_normal < 0) first_normal = cycle;
            if (ctrl.i_power_view.rec_hold_q[0][1] != 0) begin
                if (pm.i_policy.target_power_level[2] == 25)
                    $fatal(1, "[REC_HOLD] cold target idle");
                if (first_normal >= 0 && level[2] == 25)
                    $fatal(1, "[REC_HOLD] cold returned to idle in hold");
                if (first_normal < 0 && cycle - load_cycle >= L_WAKE)
                    $fatal(1, "[REC_HOLD] cold exceeded L_wake");
            end
            $display("[P8_COLD] cycle=%0d hold=%0d target=%0d applied=%0d",
                     cycle, ctrl.i_power_view.rec_hold_q[0][1], pm.i_policy.target_power_level[2], level[2]);
        end
    end
    initial begin
        repeat (2) @(negedge clk); rst = 1;
        repeat (30) @(negedge clk);
        if (level[2] != 25) $fatal(1, "[REC_HOLD] probe did not start cold");
        fenced[0][0] = 1; fence_cycle = cycle + 1;
        repeat (40) @(negedge clk);
        if (load_cycle != fence_cycle + 1 || first_normal - load_cycle != 5 ||
            !update_seen || ctrl.i_power_view.rec_hold_q != 0)
            $fatal(1, "[REC_HOLD] cold probe timing/update mismatch");
        $display("Cold probe passed: fence=%0d load=%0d first_normal=%0d L_wake=%0d",
                 fence_cycle, load_cycle, first_normal, L_WAKE);
        $finish;
    end
endmodule
