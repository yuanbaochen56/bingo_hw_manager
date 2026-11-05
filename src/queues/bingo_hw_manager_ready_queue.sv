// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Ready queue of one physical slot: the tasks its core may start, in start
// order. The core only sees the task id.
//
// Push sources, never two in the same cycle (each yields to the ones above it
// before it pushes):
//   1. Replay: a replayed entry that runs on a core.
//   2. Route: a routed task that runs on a core. Dummy sets, CERF-skipped
//      tasks, absorbed exits and exports are dropped in bingo_hw_manager_router.
//   3. Import: a task imported from another chiplet (level 3).
// A routed task waits while the queue is full. Replay and import are not gated
// here: their sources push only when the queue has room.
//
// InterfaceType (READY_AND_DONE_QUEUE_INTERFACE_TYPE of bingo_hw_manager_top):
//   1: A FIFO the core reads through the CSR interface (pop_i). Each entry also
//      carries two fields the core never sees:
//        head_o.wd_class: the watchdog class of the task
//        head_o.moved:    the task does not run on its own logical slot
//      A replay flushes the queue of a fenced core (flush_i).
//   0: An AXI-Lite read mailbox at base_addr_i. head_o is 0, and pop_i and
//      flush_i are not used.
module bingo_hw_manager_ready_queue #(
    parameter int unsigned InterfaceType = 1,
    // This slot
    parameter int unsigned Core = 0,
    parameter int unsigned Cluster = 0,
    parameter int unsigned Depth = 8,
    parameter int unsigned WdClassWidth = 3,
    parameter int unsigned ChipIdWidth = 8,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    parameter int unsigned AxiAddrWidth = 48,
    parameter int unsigned AxiDataWidth = 32,
    parameter type         task_desc_t = logic,  // bingo_hw_manager_task_desc_t of the top
    parameter type         ready_desc_t = logic, // bingo_hw_manager_ready_task_desc_full_t of the top
    parameter type         req_lite_t = logic,
    parameter type         resp_lite_t = logic,
    parameter type         addr_t = logic [AxiAddrWidth-1:0],
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         task_push_t = logic,
    parameter type         ready_push_t = logic,
    parameter type         ready_head_t = logic
) (
    input  logic                      clk_i,
    input  logic                      rst_ni,
    input  logic [ChipIdWidth-1:0]    chip_id_i,
    // Push: a new task routed to this slot (bingo_hw_manager_router), a task the
    // replay controller moves here, a task imported from another chiplet
    input  task_push_t                route_i,
    input  task_push_t                replay_i,
    input  task_push_t                import_i,
    output ready_push_t               push_o,
    output logic                      full_o,
    // FIFO side (InterfaceType 1). Besides the task, the head carries its class
    // and whether it runs away from its own slot, which the watchdog adaptation
    // latches at the dispatch (never in the ready word the core reads)
    input  logic                      flush_i,
    input  logic                      pop_i,
    output ready_head_t               head_o,
    // Mailbox side (InterfaceType 0)
    input  addr_t                     base_addr_i,
    input  req_lite_t                 axi_lite_req_i,
    output resp_lite_t                axi_lite_resp_o
);
    // The entry pushed, and the head of the FIFO (push_o, head_o)
    logic                    push, head_empty, head_moved;
    ready_desc_t             push_data, head_data;
    logic [WdClassWidth-1:0] head_class;
    assign push_o = '{valid: push, data: push_data};
    assign head_o = '{empty: head_empty, data: head_data, wd_class: head_class, moved: head_moved};

    // Replay pushes never collide with routed pushes: routing into the cluster
    // is blocked while a replay MOVE may push into it.
    task_desc_t source_desc;
    assign source_desc = replay_i.valid ? replay_i.desc :
                         import_i.valid ? import_i.desc : route_i.desc;
    assign push_data.task_id       = source_desc.task_id;
    assign push_data.reserved_bits = '0;
    assign push = (route_i.valid & ~full_o) | replay_i.valid | import_i.valid;
    // The task does not run on its own logical slot: replayed or remapped onto
    // a substitute, or imported from another chiplet.
    logic moved;
    assign moved = (import_i.valid && !replay_i.valid) ||
                   (source_desc.assigned_core_id != CoreIdWidth'(Core)) ||
                   (source_desc.assigned_cluster_id != ClusterIdWidth'(Cluster));

    if (InterfaceType == 0) begin : gen_ready_queue_axi_lite_mailbox
        bingo_hw_manager_read_mailbox #(
            .MailboxDepth ( Depth        ),
            .IrqEdgeTrig  ( 1'b0         ),
            .IrqActHigh   ( 1'b1         ),
            .AxiAddrWidth ( AxiAddrWidth ),
            .AxiDataWidth ( AxiDataWidth ),
            .ChipIdWidth  ( ChipIdWidth  ),
            .req_lite_t   ( req_lite_t   ),
            .resp_lite_t  ( resp_lite_t  )
        ) i_bingo_hw_manager_ready_queue (
            .clk_i        ( clk_i           ),
            .rst_ni       ( rst_ni          ),
            .chip_id_i    ( chip_id_i       ),
            .test_i       ( 1'b0            ),
            .req_i        ( axi_lite_req_i  ),
            .resp_o       ( axi_lite_resp_o ),
            .irq_o        ( /*not used*/    ),
            .base_addr_i  ( base_addr_i     ),
            .mbox_data_i  ( push_data     ),
            .mbox_push_i  ( push          ),
            .mbox_full_o  ( full_o          ),
            .mbox_flush_i ( 1'b0            )
        );
        assign head_empty = 1'b0;
        assign head_data  = '0;
        assign head_class = '0;
        assign head_moved = 1'b0;
    end else begin : gen_ready_queue_generic_fifo
        // Extra internal metadata never appears in the device's ready word.
        typedef struct packed {
            logic                    moved;
            logic [WdClassWidth-1:0] wd_class;
            ready_desc_t             desc;
        } ready_entry_t;
        ready_entry_t entry_in, entry_out;
        assign entry_in.desc     = push_data;
        assign entry_in.wd_class = source_desc.wd_class;
        assign entry_in.moved    = moved;
        assign head_data            = entry_out.desc;
        assign head_class           = entry_out.wd_class;
        assign head_moved           = entry_out.moved;
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0          ),
            .DEPTH        ( Depth         ),
            .dtype        ( ready_entry_t )
        ) i_ready_queue (
            .clk_i       ( clk_i     ),
            .rst_ni      ( rst_ni    ),
            .testmode_i  ( 1'b0      ),
            // Replay: the entries of a fenced core are moved from its checkout queue
            .flush_i     ( flush_i   ),
            .full_o      ( full_o    ),
            .empty_o     ( head_empty   ),
            .usage_o     ( /*not used*/ ),
            .data_i      ( entry_in  ),
            .push_i      ( push    ),
            .data_o      ( entry_out ),
            .pop_i       ( pop_i     )
        );
        assign axi_lite_resp_o = '0;
    end
endmodule
