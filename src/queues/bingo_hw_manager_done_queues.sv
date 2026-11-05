// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Done queues: one FIFO per (core, cluster) slot, so the completions of
// different cores and clusters never block each other. The head of a slot's
// done queue retires the head of its checkout queue.
//
// A done enters the queue of the slot named in its done info:
//   InterfaceType 1: from the CSR port of the cores (csr_done_i), one per cycle
//   InterfaceType 0: from one AXI-Lite write mailbox that all cores write
// Level 3 (RemoteEn, CSR port only): the done of a task exported by this
// chiplet comes back from the chiplet that ran it (remote_done_i) and enters
// the done queue of its proxy slot, which is fenced and so gets no CSR done;
// a CSR done to the same queue in the same cycle wins. A reject instead marks
// the proxy slot (remote_o.reject), once the dones received before it have retired
// their entries. Only a fenced slot can be a proxy: a remote done or reject
// for any other slot (a live one, or an id out of range: a stray or corrupted
// packet) is accepted and dropped (remote_o.stray), so it cannot retire a live core's
// task, stop a live slot or block the link.
module bingo_hw_manager_done_queues #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned InterfaceType = 1,
    parameter int unsigned Depth = 32,            // of each done queue, and of the AXI-Lite mailbox
    parameter bit          RemoteEn = 1'b0,
    parameter int unsigned TaskIdWidth = 12,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    parameter int unsigned ChipIdWidth = 8,
    parameter int unsigned AxiAddrWidth = 48,
    parameter int unsigned AxiDataWidth = 32,
    parameter type         done_info_t = logic,   // bingo_hw_manager_done_info_full_t of the top
    parameter type         remote_done_t = logic, // remote_done_t of the top (the chip field is not read)
    parameter type         req_lite_t = logic,
    parameter type         resp_lite_t = logic,
    parameter type         addr_t = logic [AxiAddrWidth-1:0],
    parameter type         data_t = logic [AxiDataWidth-1:0],
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         slot_state_t = logic,
    parameter type         csr_done_t = logic,
    parameter type         done_remote_t = logic,
    parameter type         done_t = logic
) (
    input  logic                                 clk_i,
    input  logic                                 rst_ni,
    input  logic [ChipIdWidth-1:0]               chip_id_i,
    // CSR port (InterfaceType 1)
    input  csr_done_t                            csr_done_i,
    output logic                                 csr_done_ready_o,
    // AXI-Lite mailbox (InterfaceType 0)
    input  addr_t                                base_addr_i,
    input  req_lite_t                            axi_lite_req_i,
    output resp_lite_t                           axi_lite_resp_o,
    // Level 3: dones and rejects of exported tasks(across chiplet task), for their (fenced) proxy slots
    input  slot_state_t                          slot_i,
    input  logic                                 remote_done_valid_i,
    output logic                                 remote_done_ready_o,
    input  remote_done_t                         remote_done_i, // reject: 0: done, 1: reject
    output done_remote_t                         remote_o,
    // Per slot: the done pushed this cycle, and the queue head
    output done_t                                done_o,
    input  logic [NumCores-1:0][NumClusters-1:0] pop_i
);
    // The dones pushed and the heads (done_o); remote dones and rejects (remote_o)
    logic       [NumCores-1:0][NumClusters-1:0] push, empty, remote_push, reject;
    done_info_t [NumCores-1:0][NumClusters-1:0] push_data, head;
    logic                                       stray;
    assign done_o   = '{push: push, push_data: push_data, head: head, empty: empty};
    assign remote_o = '{push: remote_push, reject: reject, stray: stray};

    localparam int unsigned NumSlots = NumCores * NumClusters;
    logic [NumCores-1:0][NumClusters-1:0] full;

    for (genvar core = 0; core < NumCores; core++) begin: gen_done_q_core
        for (genvar cluster = 0; cluster < NumClusters; cluster++) begin: gen_done_q_cluster
            fifo_v3 #(
                .FALL_THROUGH ( 1'b0        ),
                .DEPTH        ( Depth       ),
                .dtype        ( done_info_t )
            ) i_done_q (
                .clk_i       ( clk_i                       ),
                .rst_ni      ( rst_ni                      ),
                .testmode_i  ( 1'b0                        ),
                .flush_i     ( 1'b0                        ),
                .full_o      ( full[core][cluster]         ),
                .empty_o     ( empty[core][cluster]      ),
                .usage_o     ( /*not used*/                ),
                .data_i      ( push_data[core][cluster]  ),
                .push_i      ( push[core][cluster]       ),
                .data_o      ( head[core][cluster]       ),
                .pop_i       ( pop_i[core][cluster]        )
            );
        end
    end

    if (InterfaceType == 0) begin: gen_done_queue_axi_lite_mailbox
        // A single mailbox writes into a shared FIFO, then each done goes to
        // the slot FIFO named in its done info
        data_t      mbox_data;
        logic       mbox_pop, mbox_empty;
        done_info_t mbox_info;
        bingo_hw_manager_write_mailbox #(
            .MailboxDepth(Depth        ),
            .IrqEdgeTrig (1'b0         ),
            .IrqActHigh  (1'b1         ),
            .AxiAddrWidth(AxiAddrWidth ),
            .AxiDataWidth(AxiDataWidth ),
            .ChipIdWidth (ChipIdWidth  ),
            .req_lite_t  (req_lite_t   ),
            .resp_lite_t (resp_lite_t  )
        ) i_bingo_hw_manager_done_queue (
            .clk_i       (clk_i          ),
            .rst_ni      (rst_ni         ),
            .chip_id_i   (chip_id_i      ),
            .test_i      (1'b0           ),
            .req_i       (axi_lite_req_i ),
            .resp_o      (axi_lite_resp_o),
            .irq_o       (),
            .base_addr_i (base_addr_i    ),
            .mbox_data_o (mbox_data      ),
            .mbox_pop_i  (mbox_pop       ),
            .mbox_empty_o(mbox_empty     ),
            .mbox_flush_i(1'b0)
        );
        assign mbox_info = done_info_t'(mbox_data);
        // The software names the slot: a done for a slot that does not exist
        // belongs to no queue, so it is popped and dropped (it would otherwise
        // read the full flag out of range and could block every later done)
        logic mbox_slot_ok;
        assign mbox_slot_ok = (int'(mbox_info.assigned_core_id) < NumCores) &&
                              (int'(mbox_info.assigned_cluster_id) < NumClusters);
        // Pop the mailbox when the target per-(core,cluster) FIFO accepts it
        assign mbox_pop = !mbox_empty &&
                          (!mbox_slot_ok || !full[mbox_info.assigned_core_id][mbox_info.assigned_cluster_id]);
`ifndef SYNTHESIS
        always @(posedge clk_i) begin
            if (rst_ni && mbox_pop && !mbox_slot_ok)
                $warning("[BINGO_DONE] %0t done of task %0d for core %0d cluster %0d: no such slot, dropped",
                         $time, mbox_info.task_id, mbox_info.assigned_core_id, mbox_info.assigned_cluster_id);
        end
`endif
        always_comb begin
            for (int c = 0; c < NumCores; c++) begin
                for (int cl = 0; cl < NumClusters; cl++) begin
                    push_data[c][cl] = mbox_info;
                    push[c][cl] = mbox_pop &&
                        (mbox_info.assigned_core_id == CoreIdWidth'(c)) &&
                        (mbox_info.assigned_cluster_id == ClusterIdWidth'(cl));
                end
            end
        end
        // Level 3 needs the CSR port (see the top)
        assign csr_done_ready_o    = 1'b0;
        assign remote_push       = '0;
        assign reject            = '0;
        assign remote_done_ready_o = 1'b0;
        assign stray             = 1'b0;
    end else begin: gen_done_queue_generic_fifo
        assign axi_lite_resp_o = '0;
        logic csr_done_to_remote_slot;
        logic remote_done_slot_ok;
        always_comb begin
            remote_done_slot_ok = (int'(remote_done_i.proxy_slot) < NumSlots) &&
                slot_i.fenced[int'(remote_done_i.proxy_slot) % NumCores]
                        [int'(remote_done_i.proxy_slot) / NumCores];
        end
        assign stray = RemoteEn && remote_done_valid_i && !remote_done_slot_ok;
        always_comb begin
            remote_push           = '0;
            reject                = '0;
            remote_done_ready_o     = stray;
            csr_done_to_remote_slot = csr_done_i.valid &&
                (csr_done_i.info.assigned_core_id == CoreIdWidth'(remote_done_i.proxy_slot % NumCores)) &&
                (csr_done_i.info.assigned_cluster_id == ClusterIdWidth'(remote_done_i.proxy_slot / NumCores));
            for (int c = 0; c < NumCores; c++) begin
                for (int cl = 0; cl < NumClusters; cl++) begin
                    push_data[c][cl] = csr_done_i.info;
                    push[c][cl] = csr_done_i.valid &&
                        (csr_done_i.info.assigned_core_id == CoreIdWidth'(c)) &&
                        (csr_done_i.info.assigned_cluster_id == ClusterIdWidth'(cl)) &&
                        !full[c][cl];
                    if (RemoteEn && remote_done_valid_i && remote_done_slot_ok && remote_done_i.reject &&
                        (int'(remote_done_i.proxy_slot) == c + cl * NumCores)) begin
                        // A reject marks the slot once the dones received before
                        // it have retired their entries
                        if (empty[c][cl]) begin
                            reject[c][cl]     = 1'b1;
                            remote_done_ready_o = 1'b1;
                        end
                    end else if (RemoteEn && remote_done_valid_i && remote_done_slot_ok && !csr_done_to_remote_slot &&
                        (int'(remote_done_i.proxy_slot) == c + cl * NumCores) &&
                        !full[c][cl]) begin
                        remote_push[c][cl]                   = 1'b1;
                        remote_done_ready_o                    = 1'b1;
                        push[c][cl]                          = 1'b1;
                        push_data[c][cl]                     = '0;
                        push_data[c][cl].assigned_core_id    = CoreIdWidth'(c);
                        push_data[c][cl].assigned_cluster_id = ClusterIdWidth'(cl);
                        push_data[c][cl].task_id             = remote_done_i.task_id;
                    end
                end
            end
        end
        assign csr_done_ready_o = !full[csr_done_i.info.assigned_core_id][csr_done_i.info.assigned_cluster_id];
    end
endmodule
