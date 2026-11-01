// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Done queues with the AXI-Lite mailbox (InterfaceType 0): the software names
// the slot of a done in its data. 3 cores x 2 clusters, so core id 3 names no
// slot. EXPECTED: dones go to the queue of their slot; a done for core 3 is
// taken out of the mailbox and dropped (no queue gets it), and the dones behind
// it still reach their queues; a done for a full queue waits in the mailbox
// until that queue is popped.
`include "axi/typedef.svh"
`include "bingo_hw_manager/typedef.svh"

module tb_bingo_hw_manager_done_mailbox;
    localparam int unsigned NumCores = 3;
    localparam int unsigned NumClusters = 2;
    localparam int unsigned Depth = 2;
    localparam int unsigned TaskIdWidth = 12;
    localparam int unsigned AddrWidth = 48;
    localparam int unsigned DataWidth = 32;

    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [DataWidth/8-1:0] strb_t;
    `AXI_LITE_TYPEDEF_ALL(lite, addr_t, data_t, strb_t)
    typedef struct packed {
        logic [DataWidth-TaskIdWidth-3-1:0] reserved_bits;
        logic [0:0]                         assigned_cluster_id;
        logic [1:0]                         assigned_core_id;
        logic [TaskIdWidth-1:0]             task_id;
    } done_info_t;
    typedef struct packed {
        logic [7:0]             chip;
        logic [2:0]             proxy_slot;
        logic [TaskIdWidth-1:0] task_id;
        logic                   reject;
    } remote_done_t;
    `BINGO_HW_MANAGER_TYPEDEF_SLOT_STATE_T(slot_state_t, NumCores, NumClusters)
    `BINGO_HW_MANAGER_TYPEDEF_CSR_DONE_T(csr_done_t, done_info_t)
    `BINGO_HW_MANAGER_TYPEDEF_DONE_REMOTE_T(done_remote_t, NumCores, NumClusters)
    `BINGO_HW_MANAGER_TYPEDEF_DONE_T(done_t, done_info_t, NumCores, NumClusters)

    logic clk_i = 1'b0, rst_ni = 1'b0;
    always #5 clk_i = ~clk_i;

    lite_req_t  req;
    lite_resp_t resp;
    done_t      done;
    logic [NumCores-1:0][NumClusters-1:0] pop = '0;
    int unsigned pushes [NumCores][NumClusters];

    bingo_hw_manager_done_queues #(
        .NumCores      ( NumCores      ),
        .NumClusters   ( NumClusters   ),
        .InterfaceType ( 0             ),
        .Depth         ( Depth         ),
        .TaskIdWidth   ( TaskIdWidth   ),
        .CoreIdWidth   ( 2             ),
        .ClusterIdWidth( 1             ),
        .AxiAddrWidth  ( AddrWidth     ),
        .AxiDataWidth  ( DataWidth     ),
        .done_info_t   ( done_info_t   ),
        .remote_done_t ( remote_done_t ),
        .req_lite_t    ( lite_req_t    ),
        .resp_lite_t   ( lite_resp_t   ),
        .slot_state_t  ( slot_state_t  ),
        .csr_done_t    ( csr_done_t    ),
        .done_remote_t ( done_remote_t ),
        .done_t        ( done_t        )
    ) i_dut (
        .clk_i               ( clk_i  ),
        .rst_ni              ( rst_ni ),
        .chip_id_i           ( '0     ),
        .csr_done_i          ( '0     ),
        .csr_done_ready_o    (        ),
        .base_addr_i         ( '0     ),
        .axi_lite_req_i      ( req    ),
        .axi_lite_resp_o     ( resp   ),
        .slot_i              ( '0     ),
        .remote_done_valid_i ( 1'b0   ),
        .remote_done_ready_o (        ),
        .remote_done_i       ( '0     ),
        .remote_o            (        ),
        .done_o              ( done   ),
        .pop_i               ( pop    )
    );

    always @(negedge clk_i) begin : count_pushes
        if (rst_ni) begin
            if ($isunknown(done.push)) $error("[DONE_MBOX] %0t push %b has unknown bits", $time, done.push);
            for (int c = 0; c < NumCores; c++)
                for (int cl = 0; cl < NumClusters; cl++)
                    if (done.push[c][cl]) pushes[c][cl]++;
        end
    end

    // One write of the mailbox write register (offset 0)
    task automatic write_done(input int core, input int cluster, input int task_id);
        done_info_t info;
        info = '{reserved_bits: '0, assigned_cluster_id: cluster, assigned_core_id: core, task_id: task_id};
        @(negedge clk_i);
        req.aw = '{addr: '0, prot: '0};
        req.w  = '{data: data_t'(info), strb: '1};
        req.aw_valid = 1'b1;
        req.w_valid  = 1'b1;
        req.b_ready  = 1'b1;
        fork
            begin
                do @(posedge clk_i); while (!resp.aw_ready);
                @(negedge clk_i) req.aw_valid = 1'b0;
            end
            begin
                do @(posedge clk_i); while (!resp.w_ready);
                @(negedge clk_i) req.w_valid = 1'b0;
            end
        join
        while (!resp.b_valid) @(negedge clk_i);
        if (resp.b.resp != axi_pkg::RESP_OKAY) $error("[DONE_MBOX] write answered %0d", resp.b.resp);
        @(negedge clk_i) req.b_ready = 1'b0;
    endtask

    task automatic expect_counts(input string what, input int unsigned expected [NumCores][NumClusters]);
        repeat (5) @(negedge clk_i);
        for (int c = 0; c < NumCores; c++)
            for (int cl = 0; cl < NumClusters; cl++)
                if (pushes[c][cl] != expected[c][cl])
                    $error("[DONE_MBOX] %s: %0d dones pushed to core %0d cluster %0d, expected %0d",
                           what, pushes[c][cl], c, cl, expected[c][cl]);
    endtask

    initial begin
        int unsigned expected [NumCores][NumClusters];
        req = '0;
        foreach (pushes[c, cl]) begin pushes[c][cl] = 0; expected[c][cl] = 0; end
        repeat (3) @(negedge clk_i);
        rst_ni = 1'b1;
        repeat (2) @(negedge clk_i);

        write_done(1, 1, 5);
        expected[1][1] = 1;
        expect_counts("a done for core 1 cluster 1", expected);
        if (done.empty[1][1] || done.head[1][1].task_id != 5)
            $error("[DONE_MBOX] head of core 1 cluster 1: empty %b task %0d, expected task 5",
                   done.empty[1][1], done.head[1][1].task_id);

        // No slot: taken out of the mailbox and dropped
        write_done(3, 0, 7);
        write_done(3, 1, 8);
        expect_counts("two dones for core 3", expected);
        if (!i_dut.gen_done_queue_axi_lite_mailbox.mbox_empty)
            $error("[DONE_MBOX] a done for core 3 is still in the mailbox");

        // The dones behind it still arrive
        write_done(0, 0, 9);
        expected[0][0] = 1;
        expect_counts("a done for core 0 cluster 0 after them", expected);
        if (done.head[0][0].task_id != 9)
            $error("[DONE_MBOX] head of core 0 cluster 0: task %0d, expected 9", done.head[0][0].task_id);

        // A full queue holds the mailbox until it is popped (Depth 2)
        write_done(2, 0, 10);
        write_done(2, 0, 11);
        write_done(2, 0, 12);
        expected[2][0] = 2;
        expect_counts("three dones for core 2 cluster 0 (queue of 2)", expected);
        if (i_dut.gen_done_queue_axi_lite_mailbox.mbox_empty)
            $error("[DONE_MBOX] the third done for core 2 cluster 0 left the mailbox while its queue was full");
        @(negedge clk_i) pop[2][0] = 1'b1;
        @(negedge clk_i) pop[2][0] = 1'b0;
        expected[2][0] = 3;
        expect_counts("after one pop of core 2 cluster 0", expected);

        $display("[DONE_MBOX] pushes c0: %0d %0d, c1: %0d %0d, c2: %0d %0d",
                 pushes[0][0], pushes[0][1], pushes[1][0], pushes[1][1], pushes[2][0], pushes[2][1]);
        $display("Done mailbox test passed");
        $finish;
    end
endmodule
