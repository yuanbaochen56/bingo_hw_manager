// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// bingo_hw_manager_csr_to_fifo with requests to CSR numbers it does not know:
// a read is answered with 0 in the cycle the core takes the response, with
// the ready FIFO empty or not, and pops nothing; a write is taken at once,
// with the done FIFO ready or not, and pushes nothing; csr_req_unknown_o marks
// both. Ready reads, done writes and heartbeats behave as before, also right
// after an unknown request. Two channels, so the other channel's FIFOs must
// stay untouched (its ready may be high, as before: ready without valid).
module tb_bingo_hw_manager_csr_unknown;
    localparam int unsigned N = 2;
    typedef logic [31:0] data_t;
    typedef struct packed {
        logic [47:0] addr;
        logic [31:0] data;
        logic        write;
    } csr_req_t;
    typedef struct packed {
        logic [31:0] data;
    } csr_rsp_t;
    typedef struct packed {
        logic [18:0] reserved_bits;
        logic        assigned_cluster_id;
        logic        assigned_core_id;
        logic [10:0] task_id;
    } done_info_t;
    localparam logic [11:0] Ready = bingo_hw_manager_pkg::CsrReady;
    localparam logic [11:0] Done  = bingo_hw_manager_pkg::CsrDone;
    localparam logic [11:0] Beat  = 12'h5fd;

    csr_req_t [N-1:0] req;
    logic     [N-1:0] req_valid, req_ready, rsp_valid, rsp_ready;
    csr_rsp_t [N-1:0] rsp;
    data_t    [N-1:0] fifo_rdata, fifo_wdata, beat_data;
    logic     [N-1:0] fifo_rvalid, fifo_rready, fifo_wvalid, fifo_wready, beat_valid, unknown;

    bingo_hw_manager_csr_to_fifo #(
        .TaskIdWidth                       ( 11          ),
        .N                                 ( N           ),
        .NUM_CORES_PER_CLUSTER             ( 2           ),
        .NUM_CLUSTERS_PER_CHIPLET          ( 1           ),
        .csr_req_t                         ( csr_req_t   ),
        .csr_rsp_t                         ( csr_rsp_t   ),
        .data_t                            ( data_t      ),
        .bingo_hw_manager_done_info_full_t ( done_info_t ),
        .CsrHeartbeatAddr                  ( Beat        )
    ) i_dut (
        .csr_req_i         ( req         ),
        .csr_req_valid_i   ( req_valid   ),
        .csr_req_ready_o   ( req_ready   ),
        .csr_rsp_o         ( rsp         ),
        .csr_rsp_valid_o   ( rsp_valid   ),
        .csr_rsp_ready_i   ( rsp_ready   ),
        .fifo_data_i       ( fifo_rdata  ),
        .fifo_data_valid_i ( fifo_rvalid ),
        .fifo_data_ready_o ( fifo_rready ),
        .fifo_data_o       ( fifo_wdata  ),
        .fifo_data_valid_o ( fifo_wvalid ),
        .fifo_data_ready_i ( fifo_wready ),
        .heartbeat_data_o  ( beat_data   ),
        .heartbeat_valid_o ( beat_valid  ),
        .csr_req_unknown_o ( unknown     )
    );

    int unsigned checks = 0;
    // One request on channel 0 (channel 1 idle) with the given FIFO states;
    // the expected handshake and side effects, all combinational
    task automatic check(input string what, input logic write, input logic [11:0] csr, input data_t data,
                         input logic rvalid, input logic wready, input logic rsp_rdy,
                         input logic exp_ready, input logic exp_rsp, input data_t exp_data,
                         input logic exp_pop, input logic exp_push, input logic exp_beat, input logic exp_unknown);
        req = '0;
        req_valid = '0;
        req[0] = '{addr: 48'(csr), data: data, write: write};
        req_valid[0] = 1'b1;
        fifo_rvalid = {1'b1, rvalid};
        fifo_rdata  = {32'hbad0_0001, 32'h0000_0123};
        fifo_wready = {1'b1, wready};
        rsp_ready   = {1'b1, rsp_rdy};
        #1;
        if (req_ready[0] !== exp_ready || rsp_valid[0] !== exp_rsp || (exp_rsp && rsp[0].data !== exp_data) ||
            fifo_rready[0] !== exp_pop || fifo_wvalid[0] !== exp_push || beat_valid[0] !== exp_beat ||
            unknown[0] !== exp_unknown)
            $fatal(1, "[CSRU] %s: ready %b rsp %b data %h pop %b push %b beat %b unknown %b", what,
                   req_ready[0], rsp_valid[0], rsp[0].data, fifo_rready[0], fifo_wvalid[0], beat_valid[0], unknown[0]);
        if (rsp_valid[1] || fifo_rready[1] || fifo_wvalid[1] || beat_valid[1] || unknown[1])
            $fatal(1, "[CSRU] %s: the idle channel moved", what);
        checks++;
        req_valid = '0;
        #1;
    endtask

    initial begin
        //     what                       wr  csr    data         rvalid wready rsp  ready rsp  data         pop  push beat unknown
        check("unknown read, FIFO empty",  0, 12'h7c0, '0,          0,     1,     1,   1,    1,   '0,          0,   0,   0,   1);
        check("unknown read, FIFO full",   0, 12'h7c0, '0,          1,     1,     1,   1,    1,   '0,          0,   0,   0,   1);
        check("unknown read, rsp stalled", 0, 12'h5fd, '0,          1,     1,     0,   0,    1,   '0,          0,   0,   0,   1);
        check("ready read",                0, Ready,   '0,          1,     1,     1,   1,    1,   32'h123,     1,   0,   0,   0);
        check("ready read, empty",         0, Ready,   '0,          0,     1,     1,   0,    0,   '0,          0,   0,   0,   0);
        check("unknown write, done full",  1, 12'h7c1, 32'h55,      1,     0,     1,   1,    0,   '0,          0,   0,   0,   1);
        check("unknown write, both stall", 1, 12'h7c1, 32'h55,      1,     0,     0,   1,    0,   '0,          0,   0,   0,   1);
        check("unknown write",             1, Ready,   32'h55,      1,     1,     1,   1,    0,   '0,          0,   0,   0,   1);
        check("done write",                1, Done,    32'h7,       1,     1,     1,   1,    0,   '0,          0,   1,   0,   0);
        check("done write, full",          1, Done,    32'h7,       1,     0,     1,   0,    0,   '0,          0,   1,   0,   0);
        check("heartbeat",                 1, Beat,    32'h9,       1,     0,     1,   1,    0,   '0,          0,   0,   1,   0);
        check("unknown read of done",      0, Done,    '0,          1,     1,     1,   1,    1,   '0,          0,   0,   0,   1);
        $display("[CSRU] %0d checks", checks);
        $display("CSR unknown address test passed");
        $finish;
    end
endmodule
