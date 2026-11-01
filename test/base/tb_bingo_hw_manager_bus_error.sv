// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Bus errors of the manager's AXI-Lite masters.
// Task fetch (bingo_hw_manager_task_queue_master): a descriptor read answered
// with SLVERR or DECERR is dropped, the fetch stops there and clears start,
// bus_error_o stays set; the descriptors read before it are kept in order, and
// a later fetch without errors reads all its descriptors.
// PM (bingo_hw_manager_pm): bus_error_o[0] is set by the first write answered
// with an error and stays set, bus_error_o[1] by the DVFS read of the CLINT
// word; the PM goes on as before (it still applies the levels, rings the
// doorbell), and an OKAY or EXOKAY answer sets nothing.
`include "axi/typedef.svh"
`include "bingo_hw_manager/typedef.svh"
module tb_bingo_hw_manager_bus_error;
    localparam int unsigned TaskIdWidth = 4;
    typedef logic [47:0] addr_t;
    typedef logic [63:0] data_t;
    typedef logic [7:0]  strb_t;
    `AXI_LITE_TYPEDEF_ALL(lite, addr_t, data_t, strb_t)
    localparam addr_t Base = 48'h0000_8000_1000;

    logic clk_i = 1'b0, rst_ni = 1'b0;
    always #5ns clk_i = ~clk_i;

    // ------------------------------------------------------------------
    // Task fetch
    // ------------------------------------------------------------------
    lite_req_t   tq_req;
    lite_resp_t  tq_resp;
    logic [31:0] num_task, start_q, reset_start;
    logic        reset_start_en, start_set;
    data_t       q_data;
    logic        q_pop, q_empty, tq_error;

    bingo_hw_manager_task_queue_master #(
        .TaskQueueDepth ( 32          ),
        .TaskIdWidth    ( TaskIdWidth ),
        .req_lite_t     ( lite_req_t  ),
        .resp_lite_t    ( lite_resp_t ),
        .addr_t         ( addr_t      ),
        .data_t         ( data_t      )
    ) i_fetch (
        .clk_i                      ( clk_i          ),
        .rst_ni                     ( rst_ni         ),
        .task_list_base_addr_i      ( Base           ),
        .num_task_i                 ( num_task       ),
        .start_i                    ( start_q        ),
        .reset_start_o              ( reset_start    ),
        .reset_start_en_o           ( reset_start_en ),
        .task_queue_axi_lite_req_o  ( tq_req         ),
        .task_queue_axi_lite_resp_i ( tq_resp        ),
        .task_queue_data_o          ( q_data         ),
        .task_queue_pop_i           ( q_pop          ),
        .task_queue_empty_o         ( q_empty        ),
        .bus_error_o                ( tq_error       )
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)             start_q <= '0;
        else if (start_set)      start_q <= 32'd1;
        else if (reset_start_en) start_q <= reset_start;
    end

    // Memory: answers each read 1-3 cycles after the address; read number
    // bad_read (counted from 0 within a fetch) gets bad_resp
    int unsigned  reads, bad_read;
    axi_pkg::resp_t bad_resp;
    logic         r_pending;
    int unsigned  r_delay;
    addr_t        r_addr;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_pending <= 1'b0;
            r_delay   <= 0;
            r_addr    <= '0;
        end else begin
            if (tq_req.ar_valid && tq_resp.ar_ready) begin
                r_pending <= 1'b1;
                r_delay   <= 1 + ($urandom % 3);
                r_addr    <= tq_req.ar.addr;
            end else if (r_pending && r_delay > 1) begin
                r_delay <= r_delay - 1;
            end
            if (tq_resp.r_valid && tq_req.r_ready) begin
                r_pending <= 1'b0;
                reads++;
            end
        end
    end
    always_comb begin
        tq_resp          = '0;
        tq_resp.ar_ready = !r_pending;
        tq_resp.r_valid  = r_pending && (r_delay == 1);
        tq_resp.r.data   = {16'hd5c0, r_addr};
        tq_resp.r.resp   = (reads == bad_read) ? bad_resp : axi_pkg::RESP_OKAY;
    end

    // Fetch COUNT descriptors with read BAD answered with RESP; with an error
    // (SLVERR, DECERR) expect the descriptors before BAD in the queue and no
    // read after it, otherwise all of them
    task automatic fetch(input int unsigned count, input int unsigned bad, input axi_pkg::resp_t resp,
                         input logic error_before);
        automatic logic        failed   = (bad < count) && resp[1];
        automatic int unsigned expected = failed ? bad : count;
        automatic int unsigned cycles = 0;
        @(negedge clk_i);
        if (tq_error !== error_before) $fatal(1, "[BUSERR] fetch flag %b before the fetch", tq_error);
        reads    = 0;
        bad_read = bad;
        bad_resp = resp;
        num_task  = count;
        start_set = 1'b1;
        @(negedge clk_i);
        start_set = 1'b0;
        while (start_q != '0) begin
            @(negedge clk_i);
            if (++cycles > 400) $fatal(1, "[BUSERR] count %0d: fetch does not stop", count);
        end
        repeat (40) @(negedge clk_i);
        if (reads != (failed ? bad + 1 : count))
            $fatal(1, "[BUSERR] count %0d, error at %0d: %0d reads", count, bad, reads);
        for (int unsigned i = 0; i < expected; i++) begin
            if (q_empty || (q_data != {16'hd5c0, Base + 8 * i}))
                $fatal(1, "[BUSERR] count %0d: entry %0d missing or wrong (%h)", count, i, q_data);
            q_pop = 1'b1;
            @(negedge clk_i);
            q_pop = 1'b0;
        end
        if (!q_empty) $fatal(1, "[BUSERR] count %0d: the failed read entered the queue", count);
        if (tq_error !== (error_before || failed))
            $fatal(1, "[BUSERR] count %0d, error at %0d: flag %b", count, bad, tq_error);
        $display("[BUSERR] fetch of %0d, read %0d answered %0d: %0d descriptors, flag %b",
                 count, bad, resp, expected, tq_error);
    endtask

    // ------------------------------------------------------------------
    // PM
    // ------------------------------------------------------------------
    localparam int unsigned Cores = 2, Clusters = 2;
    lite_req_t   pm_req;
    lite_resp_t  pm_resp;
    logic [31:0] pm_mode, dvfs_ack, dvfs_request;
    logic [Cores-1:0][Clusters-1:0] waiting;
    logic [Cores-1:0][Clusters-1:0][5:0] slot_domain;
    logic [31:0][7:0] domain_level;
    logic [1:0]  pm_error;

    `BINGO_HW_MANAGER_TYPEDEF_PM_SLOT_T(pm_slot_t, Cores, Clusters)
    bingo_hw_manager_pm #(
        .NUM_CLUSTERS_PER_CHIPLET ( Clusters    ),
        .NUM_CORES_PER_CLUSTER    ( Cores       ),
        .CfgBusWidth              ( 32          ),
        .HOST_DVFS_MSIP_BIT       ( 3           ),
        .req_lite_t               ( lite_req_t  ),
        .resp_lite_t              ( lite_resp_t ),
        .addr_t                   ( addr_t      ),
        .data_t                   ( data_t      ),
        .pm_slot_t                ( pm_slot_t   )
    ) i_pm (
        .clk_i                  ( clk_i              ),
        .rst_ni                 ( rst_ni             ),
        .cfg_i                  ( '{enable: 1'b1, dvfs: pm_mode[0], idle_level: 8'd25, normal_level: 8'd6,
                                    dvfs_level: dvfs_ack[7:0], default: '0} ),
        .slot_i                 ( '{domain: slot_domain, idle: waiting, default: '0} ),
        .pm_base_addr_i         ( 48'h0000_0300_0000 ),
        .dvfs_clint_msip_addr_i ( 48'h0000_0400_0004 ),
        .dvfs_request_o         ( dvfs_request       ),
        .domain_level_o         ( domain_level       ),
        .pm_axi_lite_req_o      ( pm_req             ),
        .pm_axi_lite_resp_i     ( pm_resp            ),
        .bus_error_o            ( pm_error           )
    );

    // Slave: takes every AW, W and AR at once, answers each W with a B and each
    // AR with an R in the next cycle; write number bad_write (from 0) and read
    // number bad_pm_read get pm_bad_resp. It answers like the path of HeMAiA:
    // the 64- to 32-bit converter splits a write into the 32-bit words from its
    // address to the end of the 8-byte word (two at an 8-byte boundary, one at
    // the upper half), and the registers take only full 32-bit writes, so a
    // word written without all four strobes gets SLVERR.
    int unsigned    writes, pm_reads, bad_write, bad_pm_read, partial_writes;
    axi_pkg::resp_t pm_bad_resp;
    logic           b_pending, pr_pending;
    logic [1:0]     b_resp_q, r_resp_q;
    addr_t          aw_addr_q;
    function automatic logic full_words(input addr_t addr, input strb_t strb);
        return (addr[2] || strb[3:0] == 4'hf) && strb[7:4] == 4'hf;
    endfunction
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            b_pending  <= 1'b0;
            pr_pending <= 1'b0;
            b_resp_q   <= '0;
            r_resp_q   <= '0;
            aw_addr_q  <= '0;
        end else begin
            if (pm_req.aw_valid && pm_resp.aw_ready) aw_addr_q <= pm_req.aw.addr;
            if (pm_req.w_valid && pm_resp.w_ready) begin
                if (b_pending && !pm_req.b_ready) $fatal(1, "[BUSERR] PM: second write before the B");
                b_pending <= 1'b1;
                b_resp_q  <= !full_words(aw_addr_q, pm_req.w.strb) ? axi_pkg::RESP_SLVERR :
                             (writes == bad_write) ? pm_bad_resp : axi_pkg::RESP_OKAY;
                if (!full_words(aw_addr_q, pm_req.w.strb)) partial_writes++;
                // A division write: the whole 8-byte word of domains 0-7 at 0x08,
                // the new level of domain 1 or 2 in its byte, the level applied
                // so far in every other byte
                if (aw_addr_q == 48'h0000_0300_0008) begin
                    automatic int unsigned changed = 0;
                    for (int i = 0; i < 8; i++)
                        if (pm_req.w.data[8*i +: 8] != domain_level[i]) begin
                            changed++;
                            if (!(i inside {1, 2}) || !(pm_req.w.data[8*i +: 8] inside {8'd6, 8'd25}))
                                $fatal(1, "[BUSERR] PM division write: byte %0d is %0d", i, pm_req.w.data[8*i +: 8]);
                        end
                    if (pm_req.w.strb != 8'hff || changed != 1)
                        $fatal(1, "[BUSERR] PM division write: strobe %h data %h (levels %h)", pm_req.w.strb,
                               pm_req.w.data, domain_level[7:0]);
                end
                writes++;
            end else if (b_pending && pm_req.b_ready) begin
                b_pending <= 1'b0;
            end
            if (pm_req.ar_valid && pm_resp.ar_ready) begin
                pr_pending <= 1'b1;
                r_resp_q   <= (pm_reads == bad_pm_read) ? pm_bad_resp : axi_pkg::RESP_OKAY;
                pm_reads++;
            end else if (pr_pending && pm_req.r_ready) begin
                pr_pending <= 1'b0;
            end
        end
    end
    always_comb begin
        pm_resp          = '0;
        pm_resp.aw_ready = 1'b1;
        pm_resp.w_ready  = 1'b1;
        pm_resp.b_valid  = b_pending;
        pm_resp.b.resp   = b_resp_q;
        pm_resp.ar_ready = !pr_pending;
        pm_resp.r_valid  = pr_pending;
        pm_resp.r.data   = 64'h0000_0001_0000_0001;
        pm_resp.r.resp   = r_resp_q;
    end

    // Toggle domain 1 between busy and idle until WRITES writes were answered
    task automatic pm_writes(input int unsigned count);
        automatic int unsigned cycles = 0;
        while (writes < count) begin
            waiting[0][0] = ~waiting[0][0];
            repeat (12) @(negedge clk_i);
            if (++cycles > 100) $fatal(1, "[BUSERR] PM: only %0d writes", writes);
        end
        repeat (4) @(negedge clk_i);
    endtask

    initial begin
        num_task    = '0;
        start_set   = 1'b0;
        q_pop       = 1'b0;
        bad_read    = '1;
        bad_resp    = axi_pkg::RESP_OKAY;
        pm_mode     = '0;
        dvfs_ack    = '0;
        waiting     = '1;
        for (int c = 0; c < Cores; c++)
            for (int cl = 0; cl < Clusters; cl++)
                slot_domain[c][cl] = 6'd32;   // no domain
        slot_domain[0][0] = 6'd1;
        slot_domain[0][1] = 6'd2;             // always idle: its level sits next to domain 1's
        bad_write   = '1;
        bad_pm_read = '1;
        pm_bad_resp = axi_pkg::RESP_SLVERR;
        writes      = 0;
        pm_reads    = 0;
        partial_writes = 0;
        repeat (3) @(negedge clk_i);
        rst_ni = 1'b1;

        // Task fetch
        fetch(4, 4, axi_pkg::RESP_OKAY, 1'b0);     // no error
        fetch(4, 3, axi_pkg::RESP_EXOKAY, 1'b0);   // EXOKAY is no error
        fetch(6, 2, axi_pkg::RESP_SLVERR, 1'b0);   // read 2 fails: 0 and 1 kept
        fetch(3, 3, axi_pkg::RESP_OKAY, 1'b1);     // later fetch: all 3, flag stays
        fetch(5, 0, axi_pkg::RESP_DECERR, 1'b1);   // the first read fails: nothing
        fetch(2, 2, axi_pkg::RESP_OKAY, 1'b1);

        // PM, DFS: two writes per level change; the first four are answered
        // OKAY, write 4 (counted from 0) EXOKAY, write 7 (the valid write of
        // the fourth change) SLVERR
        pm_writes(4);
        if (pm_error !== 2'b00) $fatal(1, "[BUSERR] PM flag %b after OKAY writes", pm_error);
        pm_bad_resp = axi_pkg::RESP_EXOKAY;
        bad_write = 4;
        pm_writes(6);
        if (pm_error !== 2'b00) $fatal(1, "[BUSERR] PM flag %b after an EXOKAY write", pm_error);
        pm_bad_resp = axi_pkg::RESP_SLVERR;
        bad_write = 7;
        pm_writes(8);
        if (pm_error !== 2'b01) $fatal(1, "[BUSERR] PM flag %b after the failed write", pm_error);
        // the PM goes on: later writes still happen and apply their levels
        pm_writes(12);
        if (pm_error !== 2'b01) $fatal(1, "[BUSERR] PM flag %b is not sticky", pm_error);
        if (domain_level[1] != (waiting[0][0] ? 8'd25 : 8'd6))
            $fatal(1, "[BUSERR] PM level %0d after the failed write", domain_level[1]);
        if (partial_writes != 0) $fatal(1, "[BUSERR] PM: %0d writes without full 32-bit words", partial_writes);
        $display("[BUSERR] PM write error: flag %b after %0d writes", pm_error, writes);

        // PM, DVFS: the first doorbell read OKAY, the second DECERR
        pm_mode = 32'd1;
        pm_bad_resp = axi_pkg::RESP_DECERR;
        bad_pm_read = 1;
        waiting = '1;
        dvfs_ack = 32'd6;     // chip idle, host at normal: lower
        repeat (30) @(negedge clk_i);
        if (pm_reads != 1 || pm_error !== 2'b01) $fatal(1, "[BUSERR] DVFS: %0d reads, flag %b", pm_reads, pm_error);
        dvfs_ack = 32'd25;    // host applied it
        repeat (5) @(negedge clk_i);
        waiting[1][0] = 1'b0; // slot (1, 0) is in no domain: the chip stays idle
        repeat (30) @(negedge clk_i);
        if (pm_reads != 1) $fatal(1, "[BUSERR] DVFS: a slot in no domain rang the doorbell");
        waiting[0][0] = 1'b0; // domain 1 busy: raise
        repeat (30) @(negedge clk_i);
        if (pm_reads != 2 || pm_error !== 2'b11) $fatal(1, "[BUSERR] DVFS: %0d reads, flag %b", pm_reads, pm_error);
        $display("[BUSERR] PM read error: flag %b after %0d doorbell reads", pm_error, pm_reads);
        $display("Bus error test passed");
        $finish;
    end
endmodule
