// Copyright 2026 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// CSR port of the cores : a core reads its next task id from its ready queue, writes the done of
// a task and sends heartbeats, all through CSR requests
//
// - A fenced core is cut off: its ready reads stall, its heartbeats are
//   ignored, and its done writes are accepted and dropped (its tasks are
//   replayed on other cores, so a late done must not retire one twice).
// - The done writes of all cores are arbitrated into one stream (done_o);
//   bingo_hw_manager_done_queues puts each into the done queue of the slot
//   named in its done info.
// - A core waits for a task while its ready read stalls (core_o.waiting), and
//   has exited once it reports bit 31 in a heartbeat after its done write,
//   until its next ready read (core_o.exited).
// Slots are indexed [core][cluster]; the CSR channels of csr_to_fifo are flat
// (core + cluster * NumCores).
module bingo_hw_manager_csr_port #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned TaskIdWidth = 12,
    parameter logic [11:0] CsrHeartbeatAddr = 12'h5fd,
    parameter type         csr_req_t = logic,
    parameter type         csr_rsp_t = logic,
    parameter type         data_t = logic,        // device AXI-Lite data word
    parameter type         done_info_t = logic,   // bingo_hw_manager_done_info_full_t of the top
    parameter type         chip_id_t = logic,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type         slot_state_t = logic,
    parameter type         ready_t = logic,
    parameter type         core_status_t = logic,
    parameter type         csr_done_t = logic
) (
    input  logic                                     clk_i,
    input  logic                                     rst_ni,
    input  chip_id_t                                 chip_id_i,
    // CSR requests and responses of the cores
    input  csr_req_t [NumCores-1:0][NumClusters-1:0] csr_req_i,
    input  logic     [NumCores-1:0][NumClusters-1:0] csr_req_valid_i,
    output logic     [NumCores-1:0][NumClusters-1:0] csr_req_ready_o,
    output csr_rsp_t [NumCores-1:0][NumClusters-1:0] csr_rsp_o,
    output logic     [NumCores-1:0][NumClusters-1:0] csr_rsp_valid_o,
    input  logic     [NumCores-1:0][NumClusters-1:0] csr_rsp_ready_i,
    // Slot state: confirmed dead cores (bingo_hw_manager_watchdog)
    input  slot_state_t                              slot_i,
    // Ready queues (head, empty): a ready read pops the head
    input  ready_t                                   ready_i,
    output logic     [NumCores-1:0][NumClusters-1:0] ready_pop_o,
    // Heartbeats, waiting and exited cores
    output core_status_t                             core_o,
    // The done writes of the live cores, one at a time
    output csr_done_t                                done_o,
    input  logic                                     done_ready_i
);
    import bingo_hw_manager_pkg::*;

    // Heartbeats, waiting and exited cores (core_o), the arbitrated done write (done_o)
    logic [NumCores-1:0][NumClusters-1:0] heartbeat, waiting, exited_q;
    logic                                 done_valid;
    assign core_o = '{heartbeat: heartbeat, waiting: waiting, exited: exited_q};

    localparam int unsigned N_CORES_TOTAL = NumClusters * NumCores;
    // 1D CSR Requests
    csr_req_t [N_CORES_TOTAL-1:0] csr_req_1d;
    logic     [N_CORES_TOTAL-1:0] csr_req_valid_1d;
    logic     [N_CORES_TOTAL-1:0] csr_req_ready_1d;
    csr_rsp_t [N_CORES_TOTAL-1:0] csr_rsp_1d;
    logic     [N_CORES_TOTAL-1:0] csr_rsp_valid_1d;
    logic     [N_CORES_TOTAL-1:0] csr_rsp_ready_1d;
    // 1D Ready Queue FIFO Interface
    data_t    [N_CORES_TOTAL-1:0] read_ready_queue_data_1d;
    logic     [N_CORES_TOTAL-1:0] read_ready_queue_valid_1d;
    logic     [N_CORES_TOTAL-1:0] read_ready_queue_ready_1d;
    // 1D Done QUeue FIFO Interface
    data_t    [N_CORES_TOTAL-1:0] write_done_queue_data_1d;
    logic     [N_CORES_TOTAL-1:0] write_done_queue_valid_1d;
    logic     [N_CORES_TOTAL-1:0] write_done_queue_ready_1d;
    data_t                        write_done_queue_data;
    // 1D Heartbeats, and CSR requests to an unknown address
    logic     [N_CORES_TOTAL-1:0] heartbeat_valid_1d;
    data_t    [N_CORES_TOTAL-1:0] heartbeat_data_1d;
    logic     [N_CORES_TOTAL-1:0] csr_req_unknown_1d;
    // Done writes of fenced cores are accepted and dropped before the arbiter
    logic     [N_CORES_TOTAL-1:0] core_fenced_1d;
    logic     [N_CORES_TOTAL-1:0] write_done_arb_valid_1d;
    logic     [N_CORES_TOTAL-1:0] write_done_arb_ready_1d;

    bingo_hw_manager_csr_to_fifo #(
        .TaskIdWidth (TaskIdWidth),
        .N (N_CORES_TOTAL),
        .NUM_CORES_PER_CLUSTER (NumCores),
        .NUM_CLUSTERS_PER_CHIPLET (NumClusters),
        .csr_req_t (csr_req_t),
        .csr_rsp_t (csr_rsp_t),
        .data_t    (data_t),
        .bingo_hw_manager_done_info_full_t (done_info_t),
        .CsrHeartbeatAddr (CsrHeartbeatAddr)
    ) i_bingo_hw_manager_csr_to_fifo (
        .csr_req_i         (csr_req_1d               ),
        .csr_req_valid_i   (csr_req_valid_1d         ),
        .csr_req_ready_o   (csr_req_ready_1d         ),
        .csr_rsp_o         (csr_rsp_1d               ),
        .csr_rsp_valid_o   (csr_rsp_valid_1d         ),
        .csr_rsp_ready_i   (csr_rsp_ready_1d         ),
        // FIFO Read Interface
        .fifo_data_i       (read_ready_queue_data_1d ),
        .fifo_data_valid_i (read_ready_queue_valid_1d),
        .fifo_data_ready_o (read_ready_queue_ready_1d),
        // FIFO Write Interface
        .fifo_data_o       (write_done_queue_data_1d ),
        .fifo_data_valid_o (write_done_queue_valid_1d),
        .fifo_data_ready_i (write_done_queue_ready_1d),
        // heartbeat signal
        .heartbeat_valid_o  ( heartbeat_valid_1d     ),
        .heartbeat_data_o   ( heartbeat_data_1d      ),
        .csr_req_unknown_o  ( csr_req_unknown_1d     )
        );

`ifndef SYNTHESIS
    // A CSR request with an unknown address reads 0 or is ignored (e.g. an
    // integration that forwards a translated CSR number): a software or
    // integration error that the core does not see. Report it once when it appears.
    logic [N_CORES_TOTAL-1:0] csr_req_unknown_q;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            csr_req_unknown_q <= '0;
        end else begin
            csr_req_unknown_q <= csr_req_unknown_1d;
            for (int unsigned i = 0; i < N_CORES_TOTAL; i++) begin
                if (csr_req_unknown_1d[i] && !csr_req_unknown_q[i]) begin
                    $error("[BINGO_CSR] chip %0d core %0d cluster %0d: unknown CSR address 0x%0h (write=%0b), read as 0 / ignored",
                           chip_id_i, i % NumCores, i / NumCores,
                           csr_req_1d[i].addr, csr_req_1d[i].write);
                end
            end
        end
    end
`endif

    always_comb begin : connect_ready_queue_1d_to_2d
        for (int unsigned core = 0; core < NumCores; core = core + 1) begin
            for (int unsigned cluster = 0; cluster < NumClusters; cluster = cluster + 1) begin
                csr_req_1d[core + cluster * NumCores] = csr_req_i[core][cluster];
                csr_req_valid_1d[core + cluster * NumCores] = csr_req_valid_i[core][cluster];
                csr_req_ready_o[core][cluster] = csr_req_ready_1d[core + cluster * NumCores];
                csr_rsp_o[core][cluster] = csr_rsp_1d[core + cluster * NumCores];
                csr_rsp_valid_o[core][cluster] = csr_rsp_valid_1d[core + cluster * NumCores];
                csr_rsp_ready_1d[core + cluster * NumCores] = csr_rsp_ready_i[core][cluster];
                // A fenced core can no longer take tasks (its ready reads stall) or
                // report heartbeats: its outstanding tasks are replayed elsewhere.
                read_ready_queue_data_1d[core + cluster * NumCores] = data_t'(ready_i.data[core][cluster]);
                read_ready_queue_valid_1d[core + cluster * NumCores] = !ready_i.empty[core][cluster] &&
                                                                       !slot_i.fenced[core][cluster];
                ready_pop_o[core][cluster] = read_ready_queue_ready_1d[core + cluster * NumCores] &&
                                             !ready_i.empty[core][cluster] && !slot_i.fenced[core][cluster];
                heartbeat[core][cluster] = heartbeat_valid_1d[core + cluster * NumCores] &&
                                             !slot_i.fenced[core][cluster];
                core_fenced_1d[core + cluster * NumCores] = slot_i.fenced[core][cluster];
            end
        end
    end
    // Connect to the core_status_waiting_task
    // This signal indicates whether the core is waiting for a task to be read from the ready queue
    // If csr_req_i.write==0 and csr_req_valid_i is high and csr_req_ready_o is low, it means the core is waiting for a task
    always_comb begin : connect_core_status_waiting_task_signals
        for ( int core = 0; core < NumCores; core = core + 1) begin
            for ( int cluster = 0; cluster < NumClusters; cluster = cluster + 1) begin
                waiting[core][cluster] = (csr_req_i[core][cluster].write == 1'b0) &&
                                           csr_req_valid_i[core][cluster] &&
                                           !csr_req_ready_o[core][cluster];
            end
        end
    end

    // A real exit reports bit 31 after its done write. It no longer polls,
    // but is idle for PM and boost. A new ready read starts the next offload,
    // including when a task is already available and the read never stalls.
    logic [NumCores-1:0][NumClusters-1:0] ready_read, exit_beat, exited_d;
    always_comb begin
        exited_d = exited_q;
        for (int core = 0; core < NumCores; core++) begin
            for (int cluster = 0; cluster < NumClusters; cluster++) begin
                ready_read[core][cluster] = csr_req_valid_i[core][cluster] && !csr_req_i[core][cluster].write &&
                                            csr_req_i[core][cluster].addr[11:0] == CsrReady;
                exit_beat[core][cluster] = heartbeat[core][cluster] &&
                                           heartbeat_data_1d[core + cluster * NumCores][31];
                if (ready_read[core][cluster])     exited_d[core][cluster] = 1'b0;
                else if (exit_beat[core][cluster]) exited_d[core][cluster] = 1'b1;
            end
        end
    end
    // A polling core reads the ready queue on most edges, which leaves its bit
    // at 0: the register is written (and clocked) only when a bit changes
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            exited_q <= '0;
        end else begin
            if (exited_d != exited_q) exited_q <= exited_d;
`ifndef SYNTHESIS
            for (int core = 0; core < NumCores; core++) begin
                for (int cluster = 0; cluster < NumClusters; cluster++) begin
                    if (!ready_read[core][cluster] && exit_beat[core][cluster] && !exited_q[core][cluster])
                        $display("[BINGO_EXIT] %0t chip=%0d core=%0d cluster=%0d",
                                 $time, chip_id_i, core, cluster);
                end
            end
`endif
        end
    end

    // For the Done Queue, we arbitrate all cores' write requests; the done
    // queues route the result to the per-core FIFO named in the data.
    stream_arbiter #(
        .DATA_T(data_t),
        .N_INP (N_CORES_TOTAL)
    ) i_stream_arbiter_done_queue_write (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .inp_data_i (write_done_queue_data_1d),
        .inp_valid_i(write_done_arb_valid_1d),
        .inp_ready_o(write_done_arb_ready_1d),
        .oup_data_o (write_done_queue_data),
        .oup_valid_o(done_valid),
        .oup_ready_i(done_ready_i)
    );
    assign done_o = '{valid: done_valid, info: done_info_t'(write_done_queue_data)};
    // A fenced core's task is replayed on another core, so its own (late) done
    // must never retire the task a second time: accept the write and drop it.
    assign write_done_arb_valid_1d  = write_done_queue_valid_1d & ~core_fenced_1d;
    assign write_done_queue_ready_1d = write_done_arb_ready_1d | core_fenced_1d;

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_ni) begin
            for (int unsigned i = 0; i < N_CORES_TOTAL; i++) begin
                if (write_done_queue_valid_1d[i] && core_fenced_1d[i]) begin
                    $display("[BINGO_FENCE] %0t chip=%0d core=%0d cluster=%0d dropped done task=%0d",
                             $time, chip_id_i, i % NumCores, i / NumCores,
                             write_done_queue_data_1d[i][TaskIdWidth-1:0]);
                end
            end
        end
    end
`endif
endmodule
