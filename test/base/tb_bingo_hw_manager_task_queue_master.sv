// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// bingo_hw_manager_task_queue_master on its own: for each task count it reads
// exactly that many descriptors, in order from the list base, then clears the
// start register and reads nothing more. A count of 0 reads nothing; a count
// beyond the 2^TaskIdWidth task ids reads one descriptor per id. The memory
// answers each read after a variable delay.
`include "axi/typedef.svh"
module tb_bingo_hw_manager_task_queue_master;
    localparam int unsigned TaskIdWidth = 4;   // 16 task ids
    localparam int unsigned Ids = 1 << TaskIdWidth;
    localparam int unsigned Depth = 32;
    typedef logic [47:0] addr_t;
    typedef logic [63:0] data_t;
    typedef logic [7:0]  strb_t;
    `AXI_LITE_TYPEDEF_ALL(lite, addr_t, data_t, strb_t)
    localparam addr_t Base = 48'h0000_8000_1000;

    logic clk_i = 1'b0, rst_ni = 1'b0;
    always #5ns clk_i = ~clk_i;

    lite_req_t   req;
    lite_resp_t  resp;
    logic [31:0] num_task, start_q, reset_start;
    logic        reset_start_en, start_set;
    data_t       q_data;
    logic        q_pop, q_empty;

    bingo_hw_manager_task_queue_master #(
        .TaskQueueDepth ( Depth       ),
        .TaskIdWidth    ( TaskIdWidth ),
        .req_lite_t     ( lite_req_t  ),
        .resp_lite_t    ( lite_resp_t ),
        .addr_t         ( addr_t      ),
        .data_t         ( data_t      )
    ) i_dut (
        .clk_i                      ( clk_i          ),
        .rst_ni                     ( rst_ni         ),
        .task_list_base_addr_i      ( Base           ),
        .num_task_i                 ( num_task       ),
        .start_i                    ( start_q        ),
        .reset_start_o              ( reset_start    ),
        .reset_start_en_o           ( reset_start_en ),
        .task_queue_axi_lite_req_o  ( req            ),
        .task_queue_axi_lite_resp_i ( resp           ),
        .task_queue_data_o          ( q_data         ),
        .task_queue_pop_i           ( q_pop          ),
        .task_queue_empty_o         ( q_empty        )
    );

    // Start register as in the quad periph: the host sets it, the manager
    // writes reset_start into it when it is done
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)             start_q <= '0;
        else if (start_set)      start_q <= 32'd1;
        else if (reset_start_en) start_q <= reset_start;
    end

    // Memory: one read at a time, answered 1-4 cycles after the address; the
    // data is the address with a marker, so order and position are checked
    int unsigned reads = 0;
    addr_t       read_addr [$];
    logic        r_pending;
    int unsigned r_delay;
    addr_t       r_addr;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_pending <= 1'b0;
            r_delay   <= 0;
            r_addr    <= '0;
        end else begin
            if (req.ar_valid && resp.ar_ready) begin
                if (r_pending) $fatal(1, "[TQM] second read before the first answer");
                r_pending <= 1'b1;
                r_delay   <= 1 + ($urandom % 4);
                r_addr    <= req.ar.addr;
                reads++;
                read_addr.push_back(req.ar.addr);
            end else if (r_pending && r_delay > 1) begin
                r_delay <= r_delay - 1;
            end
            if (resp.r_valid && req.r_ready) r_pending <= 1'b0;
        end
    end
    always_comb begin
        resp         = '0;
        resp.ar_ready = !r_pending;
        resp.r_valid = r_pending && (r_delay == 1);
        resp.r.data  = {16'hd5c0, r_addr};
        resp.r.resp  = axi_pkg::RESP_OKAY;
    end
    always @(posedge clk_i) begin
        if (rst_ni && (req.aw_valid || req.w_valid))
            $fatal(1, "[TQM] the task queue master wrote");
    end

    task automatic run(input int unsigned count, input int unsigned expected);
        automatic int unsigned first = reads;
        automatic int unsigned cycles = 0;
        @(negedge clk_i);
        num_task  = count;
        start_set = 1'b1;
        @(negedge clk_i);
        start_set = 1'b0;
        // the start register clears once the fetch is done
        while (start_q != '0) begin
            @(negedge clk_i);
            cycles++;
            if (cycles > 20 * (expected + 2) + 100)
                $fatal(1, "[TQM] count %0d: still fetching after %0d reads", count, reads - first);
        end
        repeat (60) @(negedge clk_i);
        if (reads - first != expected)
            $fatal(1, "[TQM] count %0d: %0d reads, expected %0d", count, reads - first, expected);
        for (int unsigned i = 0; i < expected; i++) begin
            automatic addr_t a = read_addr.pop_front();
            if (a != Base + 8 * i)
                $fatal(1, "[TQM] count %0d: read %0d at %h, expected %h", count, i, a, Base + 8 * i);
            if (q_empty)
                $fatal(1, "[TQM] count %0d: descriptor %0d missing in the queue", count, i);
            if (q_data != {16'hd5c0, Base + 8 * i})
                $fatal(1, "[TQM] count %0d: queue entry %0d is %h", count, i, q_data);
            q_pop = 1'b1;
            @(negedge clk_i);
            q_pop = 1'b0;
        end
        if (!q_empty) $fatal(1, "[TQM] count %0d: extra descriptors in the queue", count);
        if (read_addr.size() != 0) $fatal(1, "[TQM] count %0d: unexpected reads", count);
        $display("[TQM] count %0d: %0d descriptors read in order", count, expected);
    endtask

    initial begin
        num_task  = '0;
        start_set = 1'b0;
        q_pop     = 1'b0;
        repeat (3) @(negedge clk_i);
        rst_ni = 1'b1;
        run(1, 1);
        run(3, 3);
        run(0, 0);
        run(2, 2);           // after a count of 0, the counter starts at the list base again
        run(Ids, Ids);
        run(Ids + 5, Ids);   // one descriptor per task id, then it stops
        run(5, 5);
        $display("Task queue master fetch count test passed");
        $finish;
    end
endmodule
