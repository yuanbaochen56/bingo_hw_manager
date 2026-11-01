// Unit test of bingo_hw_manager_remote_link: two adapters (chip 0, chip 1)
// and an injector master on an axi_lite_xbar addressed by chip id.
//   T1 pack / unpack, done priority, invalid target held back
//   T2 credits run out: export stalls, resumes on the delivered done
//   T3 SLVERR from a full mailbox sets error bit 0; the packet is resent and
//      arrives once the mailbox drains (not lost: bit 5 stays clear)
//   T3b a mailbox that stays full: the packet is dropped after RetryLimit
//      resends (error bit 5) and its credit comes back
//   T3c the same for a done: dropped (bit 5), and the TX takes the next packet
//   T4 wrong kind on a page (dropped), T5 seq gap, T6 unknown peer,
//   T7 done without an outstanding export (credit overflow)
//   T8 reject: travels on the done page as kind 4'hC, returns the credit;
//      target_valid_o lists the types with a target
//   T9 the mailbox registers other than the write register are read-only
//      from the link: a CTRL flush answers SLVERR and loses no packet
`include "axi/typedef.svh"
`include "axi/assign.svh"
module tb_bingo_hw_manager_remote_link;
    localparam time CyclTime = 10ns;
    localparam int unsigned AW = 48, DW = 64, CIW = 8, SLW = 3, TIW = 12, CTW = 4;
    localparam int unsigned Credits = 2;
    typedef logic [AW-1:0]   addr_t;
    typedef logic [DW-1:0]   data_t;
    typedef logic [DW/8-1:0] strb_t;
    typedef logic [CIW-1:0]  chip_id_t;
    `AXI_LITE_TYPEDEF_ALL(lite, addr_t, data_t, strb_t)
    localparam addr_t LinkBase = 48'h5000_0000;

    logic clk, rst_n;
    initial begin
        clk = 1'b0;
        forever #(CyclTime / 2) clk = ~clk;
    end

    // ------------------------------------------------------------------
    // Bingo-side stimulus signals, per chip
    // ------------------------------------------------------------------
    logic            exp_valid [2], exp_ready [2];
    data_t           exp_desc  [2];
    logic [CTW-1:0]  exp_type  [2];
    logic [SLW-1:0]  exp_slot  [2];
    logic            dout_valid [2], dout_ready [2];
    chip_id_t        dout_chip  [2];
    logic [SLW-1:0]  dout_slot  [2];
    logic [TIW-1:0]  dout_tid   [2];
    logic            dout_reject [2];
    logic            imp_valid [2], imp_ready [2];
    data_t           imp_desc  [2];
    logic [CTW-1:0]  imp_type  [2];
    chip_id_t        imp_origin [2];
    logic [SLW-1:0]  imp_slot  [2];
    logic            din_valid [2], din_ready [2];
    logic [SLW-1:0]  din_slot  [2];
    logic [TIW-1:0]  din_tid   [2];
    logic            din_reject [2];
    logic [15:0]     tgt_valid  [2];
    logic [5:0]      err       [2];
    logic [0:0][1:0] credits   [2];

    lite_req_t  [2:0] xbar_in_req;
    lite_resp_t [2:0] xbar_in_resp;
    lite_req_t  [1:0] xbar_out_req;
    lite_resp_t [1:0] xbar_out_resp;

    // chip 0: type 1 -> chip 1; chip 1: type 1 -> chip 0; type 2 invalid everywhere
    localparam logic [15:0][CIW:0] Target0 = (16*(CIW+1))'({1'b1, 8'd1}) << (1 * (CIW + 1));
    localparam logic [15:0][CIW:0] Target1 = (16*(CIW+1))'({1'b1, 8'd0}) << (1 * (CIW + 1));

    for (genvar i = 0; i < 2; i++) begin : gen_link
        bingo_hw_manager_remote_link #(
            .ChipIdWidth       ( CIW                          ),
            .CoreTypeIdWidth   ( CTW                          ),
            .RemoteSlotIdWidth ( SLW                          ),
            .TaskIdWidth       ( TIW                          ),
            .AxiAddrWidth      ( AW                           ),
            .AxiDataWidth      ( DW                           ),
            .NumPeers          ( 1                            ),
            .PeerChipId        ( (i == 0) ? 8'd1 : 8'd0       ),
            .RemoteTargetChip  ( (i == 0) ? Target0 : Target1 ),
            .DispatchCredits   ( Credits                      ),
            .req_t             ( lite_req_t                   ),
            .resp_t            ( lite_resp_t                  )
        ) i_link (
            .clk_i                 ( clk               ),
            .rst_ni                ( rst_n             ),
            .chip_id_i             ( chip_id_t'(i)     ),
            .base_addr_i           ( LinkBase          ),
            .export_valid_i        ( exp_valid[i]      ),
            .export_ready_o        ( exp_ready[i]      ),
            .export_desc_i         ( exp_desc[i]       ),
            .export_core_type_i    ( exp_type[i]       ),
            .export_origin_chip_i  ( chip_id_t'(i)     ),
            .export_proxy_slot_i   ( exp_slot[i]       ),
            .done_out_valid_i      ( dout_valid[i]     ),
            .done_out_ready_o      ( dout_ready[i]     ),
            .done_out_chip_i       ( dout_chip[i]      ),
            .done_out_proxy_slot_i ( dout_slot[i]      ),
            .done_out_task_id_i    ( dout_tid[i]       ),
            .done_out_reject_i     ( dout_reject[i]    ),
            .import_valid_o        ( imp_valid[i]      ),
            .import_ready_i        ( imp_ready[i]      ),
            .import_desc_o         ( imp_desc[i]       ),
            .import_core_type_o    ( imp_type[i]       ),
            .import_origin_chip_o  ( imp_origin[i]     ),
            .import_proxy_slot_o   ( imp_slot[i]       ),
            .done_in_valid_o       ( din_valid[i]      ),
            .done_in_ready_i       ( din_ready[i]      ),
            .done_in_proxy_slot_o  ( din_slot[i]       ),
            .done_in_task_id_o     ( din_tid[i]        ),
            .done_in_reject_o      ( din_reject[i]     ),
            .mst_req_o             ( xbar_in_req[i]    ),
            .mst_resp_i            ( xbar_in_resp[i]   ),
            .slv_req_i             ( xbar_out_req[i]   ),
            .slv_resp_o            ( xbar_out_resp[i]  ),
            .target_valid_o        ( tgt_valid[i]      ),
            .error_o               ( err[i]            ),
            .credits_o             ( credits[i]        )
        );
    end

    // Injector
    AXI_LITE_DV #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW)) inj_if (.clk_i(clk));
    `AXI_LITE_ASSIGN_TO_REQ(xbar_in_req[2], inj_if)
    `AXI_LITE_ASSIGN_FROM_RESP(inj_if, xbar_in_resp[2])
    typedef axi_test::axi_lite_rand_master #(
        .AW ( AW ), .DW ( DW ), .TA ( 2ns ), .TT ( 8ns ),
        .MIN_ADDR ( 48'h0 ), .MAX_ADDR ( 48'h0 ),
        .MAX_READ_TXNS ( 1 ), .MAX_WRITE_TXNS ( 1 )
    ) inj_master_t;
    inj_master_t inj;
    initial begin
        inj = new(inj_if, "injector");
        inj.reset();
    end

    typedef struct packed {
        logic [31:0] idx;
        addr_t       start_addr;
        addr_t       end_addr;
    } rule_t;
    rule_t [1:0] addr_map;
    for (genvar i = 0; i < 2; i++) begin : gen_rules
        assign addr_map[i] = '{idx: i, start_addr: {8'(i), LinkBase[39:0]},
                               end_addr: {8'(i), LinkBase[39:0] + 40'h2000}};
    end
    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts: 3, NoMstPorts: 2, MaxSlvTrans: 4, MaxMstTrans: 4,
        FallThrough: 1'b0, LatencyMode: axi_pkg::CUT_ALL_PORTS, PipelineStages: 0,
        AxiIdWidthSlvPorts: 0, AxiIdUsedSlvPorts: 0, UniqueIds: 1'b0,
        AxiAddrWidth: AW, AxiDataWidth: DW, NoAddrRules: 2
    };
    axi_lite_xbar #(
        .Cfg        ( XbarCfg           ),
        .aw_chan_t  ( lite_aw_chan_t    ),
        .w_chan_t   ( lite_w_chan_t     ),
        .b_chan_t   ( lite_b_chan_t     ),
        .ar_chan_t  ( lite_ar_chan_t    ),
        .r_chan_t   ( lite_r_chan_t     ),
        .axi_req_t  ( lite_req_t        ),
        .axi_resp_t ( lite_resp_t       ),
        .rule_t     ( rule_t            )
    ) i_xbar (
        .clk_i                 ( clk           ),
        .rst_ni                ( rst_n         ),
        .test_i                ( 1'b0          ),
        .slv_ports_req_i       ( xbar_in_req   ),
        .slv_ports_resp_o      ( xbar_in_resp  ),
        .mst_ports_req_o       ( xbar_out_req  ),
        .mst_ports_resp_i      ( xbar_out_resp ),
        .addr_map_i            ( addr_map      ),
        .en_default_mst_port_i ( '0            ),
        .default_mst_port_i    ( '0            )
    );

    // ------------------------------------------------------------------
    // Monitors
    // ------------------------------------------------------------------
    typedef struct { int unsigned tid; int unsigned ttype; int unsigned ctype; int unsigned origin; int unsigned slot; } imp_rec_t;
    typedef struct { int unsigned tid; int unsigned slot; bit reject; } done_rec_t;
    imp_rec_t  imports [2][$];
    done_rec_t dones   [2][$];
    int unsigned exports_acc [2];
    int unsigned first_done_cycle [2], first_import_cycle [2], cycle;
    always @(posedge clk) begin
        cycle++;
        for (int i = 0; i < 2; i++) begin
            if (rst_n && imp_valid[i] && imp_ready[i]) begin
                imports[i].push_back('{tid: imp_desc[i][9 +: TIW], ttype: imp_desc[i][7 +: 2], ctype: imp_type[i],
                                       origin: imp_origin[i], slot: imp_slot[i]});
                if (first_import_cycle[i] == 0) first_import_cycle[i] = cycle;
                if (imp_desc[i] & ~((data_t'((1 << TIW) - 1) << 9) | (data_t'(3) << 7))) begin
                    $error("[T] chip %0d: import desc %h has bits outside task_id / task_type", i, imp_desc[i]);
                end
            end
            if (rst_n && din_valid[i] && din_ready[i]) begin
                dones[i].push_back('{tid: din_tid[i], slot: din_slot[i], reject: din_reject[i]});
                if (first_done_cycle[i] == 0) first_done_cycle[i] = cycle;
            end
            if (rst_n && exp_valid[i] && exp_ready[i]) exports_acc[i]++;
        end
    end

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function automatic data_t mk_desc(input int unsigned tid, input int unsigned ttype);
        data_t d = '0;
        d[9 +: TIW] = TIW'(tid);
        d[7 +: 2]   = 2'(ttype);
        d[0 +: 7]   = 7'h55;           // cond_exec fields: must not travel
        d[40 +: 20] = 20'hABCDE;       // dep / assigned fields: must not travel
        return d;
    endfunction
    function automatic data_t mk_pkt(input logic [3:0] kind, input int unsigned chip, input int unsigned slot,
                                     input int unsigned ctype, input int unsigned seq, input int unsigned tid);
        return {kind, 8'(chip), 8'(slot), 4'(ctype), 8'(seq), 2'b00, 30'(tid)};
    endfunction

    task automatic do_reset();
        rst_n = 1'b0;
        for (int i = 0; i < 2; i++) begin
            exp_valid[i] = 1'b0; exp_desc[i] = '0; exp_type[i] = '0; exp_slot[i] = '0;
            dout_valid[i] = 1'b0; dout_chip[i] = '0; dout_slot[i] = '0; dout_tid[i] = '0; dout_reject[i] = 1'b0;
            imp_ready[i] = 1'b1; din_ready[i] = 1'b1;
            imports[i].delete(); dones[i].delete(); exports_acc[i] = 0;
            first_done_cycle[i] = 0; first_import_cycle[i] = 0;
        end
        repeat (5) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask

    task automatic send_export(input int i, input int unsigned tid, input int unsigned ttype,
                               input int unsigned ctype, input int unsigned slot);
        #1;
        exp_valid[i] = 1'b1; exp_desc[i] = mk_desc(tid, ttype); exp_type[i] = CTW'(ctype); exp_slot[i] = SLW'(slot);
        do @(posedge clk); while (!exp_ready[i]);
        #1 exp_valid[i] = 1'b0;
    endtask

    task automatic send_done(input int i, input int unsigned chip, input int unsigned slot, input int unsigned tid);
        #1;
        dout_valid[i] = 1'b1; dout_chip[i] = chip_id_t'(chip); dout_slot[i] = SLW'(slot); dout_tid[i] = TIW'(tid);
        do @(posedge clk); while (!dout_ready[i]);
        #1 dout_valid[i] = 1'b0;
    endtask

    task automatic inject(input addr_t addr, input data_t data, output axi_pkg::resp_t resp);
        inj.write(addr, '0, data, '1, resp);
    endtask

    function automatic addr_t page(input int chip, input int p);
        return {8'(chip), LinkBase[39:0] + 40'(p * 32'h1000)};
    endfunction

    task automatic expect_err(input int i, input logic [5:0] exp, input string what);
        if (err[i] !== exp) $error("[%s] chip %0d error %b, expected %b", what, i, err[i], exp);
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    initial begin : tests
        automatic axi_pkg::resp_t resp;
        cycle = 0;

        // ---------------- T1: pack / unpack ----------------
        do_reset();
        for (int n = 0; n < 16; n++) begin
            automatic int unsigned tid   = $urandom_range(0, (1 << TIW) - 1);
            automatic int unsigned ttype = $urandom_range(0, 3);
            automatic int unsigned slot  = $urandom_range(0, (1 << SLW) - 1);
            automatic int src = n % 2;
            send_export(src, tid, ttype, 1, slot);
            wait (imports[1 - src].size() == n / 2 + 1);
            begin
                automatic imp_rec_t r = imports[1 - src][n / 2];
                if (r.tid != tid || r.ttype != ttype || r.ctype != 1 || r.origin != src || r.slot != slot) begin
                    $error("[T1] import %p, expected tid %0d type %0d ctype 1 origin %0d slot %0d", r, tid, ttype, src, slot);
                end
            end
            // done back to the origin
            send_done(1 - src, src, slot, tid);
            wait (dones[src].size() == n / 2 + 1);
            if (dones[src][n / 2].tid != tid || dones[src][n / 2].slot != slot) begin
                $error("[T1] done %p, expected tid %0d slot %0d", dones[src][n / 2], tid, slot);
            end
        end
        repeat (20) @(posedge clk);
        if (credits[0][0] != Credits || credits[1][0] != Credits) $error("[T1] credits not returned: %0d %0d", credits[0][0], credits[1][0]);
        // invalid target (type 2): never accepted
        #1 exp_valid[0] = 1'b1; exp_desc[0] = mk_desc(9, 0); exp_type[0] = 2; exp_slot[0] = 0;
        repeat (200) begin
            @(posedge clk);
            if (exp_ready[0]) $error("[T1] export of a type without a target was accepted");
        end
        #1 exp_valid[0] = 1'b0;
        if (imports[1].size() != 8) $error("[T1] chip 1 imported %0d, expected 8", imports[1].size());
        expect_err(0, '0, "T1");
        expect_err(1, '0, "T1");
        $display("[T1] pack/unpack done");

        // ---------------- T1b: done priority ----------------
        do_reset();
        send_export(0, 5, 0, 1, 2);            // chip 1 owes a done to chip 0
        wait (imports[1].size() == 1);
        #1;
        exp_valid[1] = 1'b1; exp_desc[1] = mk_desc(6, 0); exp_type[1] = 1; exp_slot[1] = 0;
        dout_valid[1] = 1'b1; dout_chip[1] = 0; dout_slot[1] = 2; dout_tid[1] = 5;
        @(posedge clk);
        if (!dout_ready[1] || exp_ready[1]) $error("[T1b] done must win: done_ready %b export_ready %b", dout_ready[1], exp_ready[1]);
        #1 dout_valid[1] = 1'b0;
        do @(posedge clk); while (!exp_ready[1]);
        #1 exp_valid[1] = 1'b0;
        wait (dones[0].size() == 1 && imports[0].size() == 1);
        if (first_done_cycle[0] > first_import_cycle[0]) $error("[T1b] export overtook the done");
        expect_err(0, '0, "T1b");
        expect_err(1, '0, "T1b");

        // ---------------- T2: credits ----------------
        do_reset();
        imp_ready[1] = 1'b0;
        fork
            for (int k = 0; k < 4; k++) send_export(0, 100 + k, 0, 1, k);
        join_none
        repeat (300) @(posedge clk);
        if (exports_acc[0] != Credits) $error("[T2] %0d exports accepted without credits, expected %0d", exports_acc[0], Credits);
        if (credits[0][0] != 0) $error("[T2] credits %0d, expected 0", credits[0][0]);
        #1 imp_ready[1] = 1'b1;
        wait (imports[1].size() == Credits);
        repeat (300) @(posedge clk);
        if (exports_acc[0] != Credits) $error("[T2] export accepted before a done returned");
        // done not yet delivered at chip 0: no credit
        #1 din_ready[0] = 1'b0;
        send_done(1, 0, 0, 100);
        repeat (200) @(posedge clk);
        if (exports_acc[0] != Credits) $error("[T2] credit returned before the done was delivered");
        #1 din_ready[0] = 1'b1;
        wait (exports_acc[0] == Credits + 1);
        send_done(1, 0, 1, 101);
        wait (imports[1].size() == 4);
        send_done(1, 0, 2, 102);
        send_done(1, 0, 3, 103);
        wait (dones[0].size() == 4);
        for (int k = 0; k < 4; k++) begin
            if (imports[1][k].tid != 100 + k) $error("[T2] import %0d is task %0d", k, imports[1][k].tid);
            if (dones[0][k].tid != 100 + k)   $error("[T2] done %0d is task %0d", k, dones[0][k].tid);
        end
        repeat (10) @(posedge clk);
        if (credits[0][0] != Credits) $error("[T2] credits %0d at the end", credits[0][0]);
        expect_err(0, '0, "T2");
        expect_err(1, '0, "T2");

        // ---------------- T3: SLVERR ----------------
        do_reset();
        imp_ready[1] = 1'b0;
        // fill chip 1's dispatch mailbox (depth 2) behind the link's back
        inject(page(1, 0), mk_pkt(4'h5, 0, 0, 1, 0, 1), resp);
        inject(page(1, 0), mk_pkt(4'h5, 0, 0, 1, 1, 2), resp);
        inject(page(1, 0), mk_pkt(4'h5, 0, 0, 1, 2, 3), resp);
        if (resp != axi_pkg::RESP_SLVERR) $error("[T3] write to a full mailbox answered %0d", resp);
        send_export(0, 4, 0, 1, 0);
        repeat (50) @(posedge clk);
        expect_err(0, 6'b000001, "T3");
        #1 imp_ready[1] = 1'b1;
        wait (imports[1].size() == 3);
        repeat (20) @(posedge clk);
        if ((imports[1].size() != 3) || (imports[1][2].tid != 4)) begin
            $error("[T3] %0d imports (last %0d), expected the resent task 4 third", imports[1].size(), imports[1][imports[1].size()-1].tid);
        end
        // the injected packets used chip 0's sequence numbers 0 and 1: the resent
        // export (seq 0) arrives as a gap
        expect_err(1, 6'b000100, "T3");

        // ---------------- T3b: retries run out ----------------
        do_reset();
        imp_ready[1] = 1'b0;
        inject(page(1, 0), mk_pkt(4'h5, 0, 0, 1, 0, 1), resp);
        inject(page(1, 0), mk_pkt(4'h5, 0, 0, 1, 1, 2), resp);
        send_export(0, 4, 0, 1, 0);
        repeat (2000) @(posedge clk);               // > RetryLimit * (RetryBackoff + handshake)
        if (credits[0][0] != Credits) $error("[T3b] credits %0d after the drop, expected %0d", credits[0][0], Credits);
        expect_err(0, 6'b100001, "T3b");
        #1 imp_ready[1] = 1'b1;
        repeat (100) @(posedge clk);
        if (imports[1].size() != 2) $error("[T3b] %0d imports, expected 2 (task 4 dropped)", imports[1].size());

        // ---------------- T3c: a done whose retries run out ----------------
        do_reset();
        din_ready[0] = 1'b0;
        // fill chip 0's done mailbox (depth 2) behind the link's back
        inject(page(0, 1), mk_pkt(4'hA, 1, 0, 0, 0, 1), resp);
        inject(page(0, 1), mk_pkt(4'hA, 1, 0, 0, 1, 2), resp);
        send_done(1, 0, 1, 5);
        repeat (2000) @(posedge clk);
        expect_err(1, 6'b100001, "T3c");
        expect_err(0, '0, "T3c");
        // the dropped done no longer holds chip 1's TX
        fork : t3c_free
            send_done(1, 0, 2, 6);
            begin
                repeat (50) @(posedge clk);
                $error("[T3c] chip 1 does not take a done after the drop");
            end
        join_any
        disable t3c_free;

        // ---------------- T4: wrong kind ----------------
        do_reset();
        inject(page(1, 0), mk_pkt(4'hA, 0, 0, 1, 0, 1), resp);   // done packet on the dispatch page
        repeat (20) @(posedge clk);
        expect_err(1, 6'b000010, "T4a");
        inject(page(1, 1), mk_pkt(4'h5, 0, 0, 1, 0, 1), resp);   // dispatch packet on the done page
        inject(page(1, 1), '0, resp);                            // garbage
        repeat (20) @(posedge clk);
        if (imports[1].size() != 0 || dones[1].size() != 0) $error("[T4] a bad packet was delivered");
        expect_err(1, 6'b000010, "T4b");
        // the link still works after dropping them
        send_export(0, 8, 0, 1, 0);
        wait (imports[1].size() == 1);
        repeat (5) @(posedge clk);
        expect_err(1, 6'b000010, "T4c");
        expect_err(0, '0, "T4c");

        // ---------------- T5: seq gap ----------------
        do_reset();
        inject(page(1, 0), mk_pkt(4'h5, 0, 0, 1, 0, 1), resp);   // seq 0: fine
        repeat (20) @(posedge clk);
        expect_err(1, '0, "T5a");
        inject(page(1, 0), mk_pkt(4'h5, 0, 0, 1, 2, 2), resp);   // seq 2: gap
        repeat (20) @(posedge clk);
        expect_err(1, 6'b000100, "T5b");
        if (imports[1].size() != 2) $error("[T5] %0d imports, expected 2", imports[1].size());

        // ---------------- T6: unknown peer ----------------
        do_reset();
        inject(page(1, 0), mk_pkt(4'h5, 7, 0, 1, 0, 1), resp);
        repeat (20) @(posedge clk);
        expect_err(1, 6'b001000, "T6a");
        do_reset();
        send_done(0, 7, 0, 1);                                   // done to a chip that is no peer
        repeat (20) @(posedge clk);
        if (!err[0][3]) $error("[T6b] done to an unknown chip not flagged");

        // ---------------- T7: credit overflow ----------------
        do_reset();
        inject(page(0, 1), mk_pkt(4'hA, 1, 0, 0, 0, 1), resp);   // done, but chip 0 exported nothing
        repeat (20) @(posedge clk);
        expect_err(0, 6'b010000, "T7");
        if (credits[0][0] != Credits) $error("[T7] credits %0d, expected %0d", credits[0][0], Credits);

        // ---------------- T8: reject ----------------
        do_reset();
        if (tgt_valid[0] !== 16'h0002 || tgt_valid[1] !== 16'h0002) begin
            $error("[T8] target_valid %h / %h, expected 0002", tgt_valid[0], tgt_valid[1]);
        end
        send_export(0, 21, 0, 1, 1);
        wait (imports[1].size() == 1);
        #1 dout_reject[1] = 1'b1;
        send_done(1, 0, 1, 21);                // chip 1 cannot run it: reject
        #1 dout_reject[1] = 1'b0;
        send_export(0, 22, 0, 1, 1);
        wait (imports[1].size() == 2);
        send_done(1, 0, 1, 22);                // normal done after the reject
        wait (dones[0].size() == 2);
        if (!dones[0][0].reject || dones[0][0].tid != 21 || dones[0][0].slot != 1) $error("[T8] first %p, expected reject of 21", dones[0][0]);
        if (dones[0][1].reject || dones[0][1].tid != 22) $error("[T8] second %p, expected done of 22", dones[0][1]);
        repeat (20) @(posedge clk);
        if (credits[0][0] != Credits) $error("[T8] credits %0d, expected %0d", credits[0][0], Credits);
        expect_err(0, '0, "T8");
        expect_err(1, '0, "T8");
        // a reject packet on the dispatch page is a wrong kind
        inject(page(1, 0), mk_pkt(4'hC, 0, 0, 0, 0, 3), resp);
        repeat (20) @(posedge clk);
        expect_err(1, 6'b000010, "T8");
        $display("[T8] reject done");

        // ---------------- T9: no remote register writes ----------------
        do_reset();
        imp_ready[1] = 1'b0;
        send_export(0, 31, 0, 1, 0);             // queued in chip 1's dispatch mailbox
        repeat (50) @(posedge clk);
        // WIRQT .. CTRL of both pages; CTRL (offset 0x48) = 2'b11 flushes both FIFOs
        for (int p = 0; p < 2; p++) begin
            for (int r = 4; r <= 9; r++) begin
                inject(page(1, p) + addr_t'(r * 8), data_t'(3), resp);
                if (resp != axi_pkg::RESP_SLVERR) $error("[T9] page %0d register %0d write answered %0d", p, r, resp);
            end
        end
        #1 imp_ready[1] = 1'b1;
        repeat (20) @(posedge clk);
        if (imports[1].size() != 1 || imports[1][0].tid != 31) $error("[T9] queued dispatch lost: %p", imports[1]);
        // the link still works
        send_export(0, 32, 0, 1, 0);
        wait (imports[1].size() == 2);
        repeat (5) @(posedge clk);
        expect_err(1, '0, "T9");
        expect_err(0, '0, "T9");
        $display("[T9] remote register writes done");

        $display("remote_link unit test passed");
        $finish;
    end

    initial begin
        #2ms;
        $fatal(1, "timeout");
    end
endmodule
