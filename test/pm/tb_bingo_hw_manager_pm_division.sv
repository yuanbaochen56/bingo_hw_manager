// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// PM division writes with a second writer of the same clock/reset controller
// (bingo_hw_manager_pm DivisionPerDomain).
// Two PMs get the same slot activity: one writes the packed division registers
// (DivisionPerDomain = 0), the other one register per domain (1). Each one has
// its own model of the controller behind the 64- to 32-bit converter of
// HeMAiA, and its own host that keeps reprogramming domains 0 and 3 (the host
// CPU and a fourth clock, in the PM's 8-byte word with domains 1 and 2) the
// way hemaia_clk_rst_controller.h does: read the packed register, change one
// byte, write it back, set the domain's valid bit. Both hosts follow the same
// random timing.
// The controller model has both register sets: a bit of the valid register
// (0x04) loads the domain's divider from its byte of the packed registers
// (0x08 + 4k), a bit of the per-domain valid register (0x34) from the
// domain's own register (0x38 + 8d, nothing at 0x3c + 8d). A load is checked
// against what its writer meant: the host's value for the host's loads, the
// level the PM applies (domain_level_o) for the PM's loads.
// Expected: with the packed registers both writers spoil each other's loads
// (the PM writes the host's byte with its shadow; the host writes a level of
// the PM back from before the PM's write), so the test needs both kinds at
// least once; with one register per domain none. Also checked: the bus
// sequence of the per-domain PM (an 8-byte write at 0x38 + 8d with the level
// in the low byte and zeros elsewhere, then the per-domain valid write in the
// upper half at 0x34, same beats as the packed PM), it never writes a packed
// or valid register, and no write misses a strobe.
`include "axi/typedef.svh"
`include "bingo_hw_manager/typedef.svh"
module tb_bingo_hw_manager_pm_division;
    typedef logic [47:0] addr_t;
    typedef logic [63:0] data_t;
    typedef logic [7:0]  strb_t;
    `AXI_LITE_TYPEDEF_ALL(lite, addr_t, data_t, strb_t)
    localparam addr_t       Base     = 48'h0000_0300_0000;
    localparam int unsigned Cores    = 2, Clusters = 2;
    localparam int unsigned HostOps  = 3000;

    logic clk_i = 1'b0, rst_ni = 1'b0;
    always #5ns clk_i = ~clk_i;

    logic [Cores-1:0][Clusters-1:0]      waiting;
    logic [Cores-1:0][Clusters-1:0][5:0] slot_domain;
    `BINGO_HW_MANAGER_TYPEDEF_PM_SLOT_T(pm_slot_t, Cores, Clusters)

    // Mismatches per PM (0 packed, 1 per domain): host loads spoiled by the PM,
    // PM loads spoiled by the host; and the counts of loads checked
    int unsigned host_spoiled[2], pm_spoiled[2], host_loads[2], pm_loads[2];
    int unsigned beats[2], partial[2];

    // The host's next operation, the same for both hosts (one random stream)
    int unsigned op_domain, op_gap_read, op_gap_write, op_gap_valid;
    logic [7:0]  op_value;
    logic        op_go;
    int unsigned ops_done[2];

    for (genvar m = 0; m < 2; m++) begin : gen_pm
        lite_req_t        pm_req;
        lite_resp_t       pm_resp;
        logic [31:0][7:0] domain_level;
        logic [1:0]       pm_error;
        logic [31:0]      dvfs_request;

        bingo_hw_manager_pm #(
            .NUM_CLUSTERS_PER_CHIPLET ( Clusters    ),
            .NUM_CORES_PER_CLUSTER    ( Cores       ),
            .CfgBusWidth              ( 32          ),
            .HOST_DVFS_MSIP_BIT       ( 3           ),
            .DivisionPerDomain        ( m == 1      ),
            .req_lite_t               ( lite_req_t  ),
            .resp_lite_t              ( lite_resp_t ),
            .addr_t                   ( addr_t      ),
            .data_t                   ( data_t      ),
            .pm_slot_t                ( pm_slot_t   )
        ) i_pm (
            .clk_i                  ( clk_i              ),
            .rst_ni                 ( rst_ni             ),
            .cfg_i                  ( '{enable: 1'b1, idle_level: 8'd25, normal_level: 8'd6, default: '0} ),
            .slot_i                 ( '{domain: slot_domain, idle: waiting, default: '0} ),
            .pm_base_addr_i         ( Base               ),
            .dvfs_clint_msip_addr_i ( 48'h0000_0400_0004 ),
            .dvfs_request_o         ( dvfs_request       ),
            .domain_level_o         ( domain_level       ),
            .pm_axi_lite_req_o      ( pm_req             ),
            .pm_axi_lite_resp_i     ( pm_resp            ),
            .bus_error_o            ( pm_error           )
        );

        // Controller model: the packed registers, the per-domain registers, and
        // what each divider was loaded with
        logic [31:0][7:0] packed_q, own_q;
        // The PM's write being applied: address of its AW, its 32-bit beats
        addr_t       aw_addr_q;
        logic        b_pending;
        logic [7:0]  pm_level_q;   // the level of the PM's last division write
        int unsigned pm_domain_q;
        // The host's value per domain (what its last write meant)
        logic [31:0][7:0] host_value;

        // One 32-bit beat into the controller (from the converter): full words only
        function automatic void beat(input addr_t addr, input logic [3:0] strb, input logic [31:0] data,
                                     input logic from_pm);
            automatic int unsigned off = 32'(addr - Base);
            if (from_pm) beats[m]++;
            if (strb != 4'hf) begin
                partial[m]++;
                return;
            end
            if (off >= 32'h08 && off < 32'h28) begin
                if (from_pm && m == 1) $fatal(1, "[PMDIV] per-domain PM wrote the packed register at %h", off);
                for (int j = 0; j < 4; j++) packed_q[(off - 8) + j] = data[8*j +: 8];
            end else if (off >= 32'h38 && off < 32'h138 && off[2] == 1'b0) begin
                own_q[(off - 32'h38) >> 3] = data[7:0];
            end else if (off == 32'h04 || off == 32'h34) begin
                if (from_pm && m == 1 && off == 32'h04) $fatal(1, "[PMDIV] per-domain PM wrote the packed valid register");
                for (int d = 0; d < 32; d++) begin
                    if (data[d]) begin
                        automatic logic [7:0] loaded = (off == 32'h04) ? packed_q[d] : own_q[d];
                        if (from_pm) begin
                            pm_loads[m]++;
                            if (d != pm_domain_q) $fatal(1, "[PMDIV] PM %0d loads domain %0d, wrote %0d", m, d, pm_domain_q);
                            if (loaded != pm_level_q) pm_spoiled[m]++;
                        end else begin
                            host_loads[m]++;
                            if (loaded != host_value[d]) host_spoiled[m]++;
                        end
                    end
                end
            end
        endfunction

        // PM side: the 64-bit write through the converter: two beats at an
        // 8-byte boundary, one in the upper half; the B one cycle later
        always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                aw_addr_q <= '0;
                b_pending <= 1'b0;
            end else begin
                if (pm_req.aw_valid && pm_resp.aw_ready) aw_addr_q <= pm_req.aw.addr;
                if (pm_req.w_valid && pm_resp.w_ready) begin
                    automatic int unsigned off = 32'(aw_addr_q - Base);
                    if (m == 1) begin
                        // The per-domain PM: its register, the level in the low byte
                        if (off >= 32'h38) begin
                            if (off[2:0] != 3'd0 || pm_req.w.strb != 8'hff || pm_req.w.data[63:8] != '0 ||
                                pm_req.w.data[7:0] != i_pm.active_target_level_q ||
                                off != 32'h38 + 8 * i_pm.active_domain_id_q)
                                $fatal(1, "[PMDIV] per-domain division write at %h: strobe %h data %h", off,
                                       pm_req.w.strb, pm_req.w.data);
                        end else if (off != 32'h34 || pm_req.w.strb != 8'hf0 ||
                                     pm_req.w.data[63:32] != (32'd1 << i_pm.active_domain_id_q)) begin
                            $fatal(1, "[PMDIV] per-domain valid write at %h: strobe %h data %h", off,
                                   pm_req.w.strb, pm_req.w.data);
                        end
                    end
                    if (off != 32'h04 && off != 32'h34) begin
                        pm_level_q  = i_pm.active_target_level_q;
                        pm_domain_q = i_pm.active_domain_id_q;
                    end
                    if (aw_addr_q[2] == 1'b0) begin
                        beat(aw_addr_q, pm_req.w.strb[3:0], pm_req.w.data[31:0], 1'b1);
                        beat(aw_addr_q + 4, pm_req.w.strb[7:4], pm_req.w.data[63:32], 1'b1);
                    end else begin
                        beat(aw_addr_q, pm_req.w.strb[7:4], pm_req.w.data[63:32], 1'b1);
                    end
                    b_pending <= 1'b1;
                end else if (b_pending && pm_req.b_ready) begin
                    b_pending <= 1'b0;
                end
            end
        end
        always_comb begin
            pm_resp          = '0;
            pm_resp.aw_ready = 1'b1;
            pm_resp.w_ready  = 1'b1;
            pm_resp.b_valid  = b_pending;
        end

        // Host side: hemaia_clk_rst_controller.h enable_clk_domain, one beat per
        // cycle, gaps from the shared random stream
        initial begin
            automatic logic [31:0] word;
            automatic int unsigned d, k;
            host_value  = '0;
            packed_q    = '0;
            own_q       = '0;
            ops_done[m] = 0;
            wait (rst_ni);
            for (int unsigned i = 0; i < HostOps; i++) begin
                wait (op_go);
                d = op_domain;
                k = d / 4;
                repeat (op_gap_read) @(posedge clk_i);
                #1ns;
                word = {packed_q[4 * k + 3], packed_q[4 * k + 2], packed_q[4 * k + 1], packed_q[4 * k]};
                repeat (op_gap_write) @(posedge clk_i);
                #1ns;
                word[8 * (d % 4) +: 8] = op_value;
                host_value[d] = op_value;
                beat(Base + 8 + 4 * k, 4'hf, word, 1'b0);
                repeat (op_gap_valid) @(posedge clk_i);
                #1ns;
                beat(Base + 4, 4'hf, 32'd1 << d, 1'b0);
                ops_done[m]++;
                wait (!op_go);
            end
        end
    end

    // The shared random stream of host operations: both hosts start an
    // operation together and wait for each other
    initial begin
        op_go = 1'b0;
        wait (rst_ni);
        for (int unsigned i = 0; i < HostOps; i++) begin
            op_domain    = ($urandom % 2) ? 3 : 0;
            op_value     = 8'(1 + ($urandom % 254));
            op_gap_read  = $urandom % 9;
            op_gap_write = 1 + ($urandom % 4);
            op_gap_valid = 1 + ($urandom % 3);
            op_go = 1'b1;
            wait (ops_done[0] == i + 1 && ops_done[1] == i + 1);
            op_go = 1'b0;
            #1ns;
        end
    end

    // Slot activity: domain 1 and domain 2 change between busy and idle at
    // random, so the PM writes most of the time
    initial begin
        waiting = '1;
        for (int c = 0; c < Cores; c++)
            for (int cl = 0; cl < Clusters; cl++)
                slot_domain[c][cl] = 6'd32;   // no domain
        slot_domain[0][0] = 6'd1;
        slot_domain[0][1] = 6'd2;
        for (int i = 0; i < 2; i++) begin
            host_spoiled[i] = 0; pm_spoiled[i] = 0; host_loads[i] = 0; pm_loads[i] = 0;
            beats[i] = 0; partial[i] = 0;
        end
        repeat (3) @(negedge clk_i);
        rst_ni = 1'b1;
        while (!(ops_done[0] == HostOps && ops_done[1] == HostOps)) begin
            repeat (1 + ($urandom % 14)) @(negedge clk_i);
            waiting[0][$urandom % 2] = $urandom % 2;
        end
        waiting = '1;
        repeat (40) @(negedge clk_i);
        for (int i = 0; i < 2; i++)
            $display("[PMDIV] %s PM: %0d PM loads (%0d spoiled by the host), %0d host loads (%0d spoiled by the PM), %0d PM beats, %0d without all strobes",
                     i ? "per-domain" : "packed", pm_loads[i], pm_spoiled[i], host_loads[i], host_spoiled[i],
                     beats[i], partial[i]);
        if (pm_loads[0] < 100 || pm_loads[1] != pm_loads[0] || host_loads[0] != HostOps || host_loads[1] != HostOps)
            $fatal(1, "[PMDIV] too few or unequal loads: PM %0d / %0d, host %0d / %0d", pm_loads[0], pm_loads[1],
                   host_loads[0], host_loads[1]);
        if (pm_spoiled[0] == 0 || host_spoiled[0] == 0)
            $fatal(1, "[PMDIV] the packed PM spoiled no load (%0d / %0d): the stimulus misses the race", pm_spoiled[0],
                   host_spoiled[0]);
        if (pm_spoiled[1] != 0 || host_spoiled[1] != 0)
            $fatal(1, "[PMDIV] per-domain PM: %0d PM loads and %0d host loads spoiled", pm_spoiled[1], host_spoiled[1]);
        if (beats[0] != beats[1] || partial[0] != 0 || partial[1] != 0)
            $fatal(1, "[PMDIV] beats %0d / %0d, partial %0d / %0d", beats[0], beats[1], partial[0], partial[1]);
        if (gen_pm[0].domain_level != gen_pm[1].domain_level)
            $fatal(1, "[PMDIV] the two PMs applied different levels");
        $display("PM division test passed");
        $finish;
    end
endmodule
