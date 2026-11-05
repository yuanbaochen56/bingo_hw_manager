// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// Dependency unit of the manager, between the task queue and the placement.
//
// Task path:
//   1. A new task enters the waiting queue of its core index. There is one
//      queue per core index, shared by all clusters.
//   2. The queue head is checked against the dependency matrix of its cluster
//      (bingo_hw_manager_dep_matrix). A task without dep_check_en skips this
//      check.
//   3. A checked head is offered to the physical cluster the placement chose
//      (offer_cluster_i, bingo_hw_manager_router). A dummy check task is
//      dropped here: it only waited for its dependencies.
//
// Dependency sets:
//   Sets come from retiring checkout heads (set_i, one per slot) and from other
//   chiplets (remote_set_i, the head of the chiplet done mailbox). One set per
//   cycle is written to the matrix of its cluster, in the column of its core.
//
// Head-of-line blocking:
//   A head that waits for its dependencies, or that the placement does not
//   take, also blocks the tasks behind it in the shared queue, including those
//   of other clusters (see bingo_hw_manager_router).
//
// Index order:
//   Ports and queues use [core] or [core][cluster], as in the top. The
//   dependency matrix nets (dep_check_*, dep_set_*) use [cluster][core], with
//   one matrix per cluster. connect_dep_check_for_dep_matrix and
//   connect_dep_set_for_dep_matrix swap the indices.
module bingo_hw_manager_dep_unit #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned WaitingQueueDepth = 8,
    parameter int unsigned DepTagWidth = 4,
    parameter type         task_desc_t = logic,   // bingo_hw_manager_task_desc_t of the top
    parameter type         remote_desc_t = logic, // bingo_hw_manager_task_desc_full_t (chiplet done mailbox)
    // Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned CoreIdWidth = cf_math_pkg::idx_width(NumCores),
    parameter int unsigned ClusterIdWidth = cf_math_pkg::idx_width(NumClusters)
) (
    input  logic                                       clk_i,
    input  logic                                       rst_ni,
    // New tasks, one stream
    input  task_desc_t                                 task_i,
    input  logic                                       task_valid_i,
    output logic                                       task_ready_o,
    // The waiting queue heads
    output task_desc_t [NumCores-1:0]                  head_o,
    output logic [NumCores-1:0]                        head_empty_o,
    // Checked heads, offered to the physical cluster chosen for each
    input  logic [NumCores-1:0][ClusterIdWidth-1:0]    offer_cluster_i,
    output logic [NumCores-1:0][NumClusters-1:0]       offer_valid_o,
    input  logic [NumCores-1:0][NumClusters-1:0]       offer_ready_i,
    // Dependency sets of the retiring checkout heads, and of other chiplets
    input  task_desc_t [NumCores-1:0][NumClusters-1:0] set_i,
    input  logic [NumCores-1:0][NumClusters-1:0]       set_valid_i,
    output logic [NumCores-1:0][NumClusters-1:0]       set_ready_o,
    input  remote_desc_t                               remote_set_i,
    input  logic                                       remote_set_valid_i,
    output logic                                       remote_set_ready_o
);
    typedef logic [DepTagWidth-1:0] dep_tag_t;
    typedef logic [NumCores-1:0]    dep_code_t;
    typedef struct packed{
        logic [ClusterIdWidth-1:0] dep_matrix_id;
        logic [CoreIdWidth-1:0]    dep_matrix_col;
        dep_tag_t                  dep_matrix_set_tag;
        dep_code_t                 dep_set_code;
    } dep_matrix_set_meta_t;

    /////////////////////////////////////////////////////////
    // Stream demux by core index (assigned_core_id): one waiting queue per core index
    /////////////////////////////////////////////////////////
    logic                                           stream_demux_core_idx_inp_valid;
    logic                                           stream_demux_core_idx_inp_ready;
    logic [CoreIdWidth-1:0]                         stream_demux_core_idx_oup_sel;
    logic [NumCores-1:0]                            stream_demux_core_idx_oup_valid;
    logic [NumCores-1:0]                            stream_demux_core_idx_oup_ready;

    ///////////////////////////////////
    // Waiting dep check queue signals
    ///////////////////////////////////
    task_desc_t                       [NumCores-1:0] waiting_dep_check_task_desc;
    logic                             [NumCores-1:0] waiting_dep_check_queue_push;
    logic                             [NumCores-1:0] waiting_dep_check_queue_full;
    logic                             [NumCores-1:0] waiting_dep_check_queue_empty;
    logic                             [NumCores-1:0] waiting_dep_check_queue_pop;

    ////////////////////////////////
    // Dep Check Manager Signals
    ////////////////////////////////
    logic                             [NumCores-1:0] dep_check_manager_inp_wait_dep_check_queue_valid;
    logic                             [NumCores-1:0] dep_check_manager_inp_wait_dep_check_queue_ready;
    logic                             [NumCores-1:0] dep_check_manager_oup_dep_check_valid;
    logic                             [NumCores-1:0] dep_check_manager_oup_dep_check_ready;
    logic                             [NumCores-1:0] dep_check_manager_oup_ready_and_checkout_queue_valid;
    logic                             [NumCores-1:0] dep_check_manager_oup_ready_and_checkout_queue_ready;
    ////////////////////////////////
    // Dep matrix demux signals
    ////////////////////////////////
    typedef logic [NumClusters-1:0] dep_matrix_demux_oup_t;
    logic                             [NumCores-1:0] demux_dep_matrix_inp_valid;
    logic                             [NumCores-1:0] demux_dep_matrix_inp_ready;
    dep_matrix_demux_oup_t            [NumCores-1:0] demux_dep_matrix_oup_valid;
    dep_matrix_demux_oup_t            [NumCores-1:0] demux_dep_matrix_oup_ready;

    ////////////////////////////////
    // Ready and Checkout queue demux signals
    ////////////////////////////////
    logic                             [NumCores-1:0] demux_ready_and_checkout_queue_inp_valid;
    logic                             [NumCores-1:0] demux_ready_and_checkout_queue_inp_ready;

    //////////////////////
    // Dep matrix signals, indexed [cluster][core]
    //////////////////////
    logic      [NumClusters-1:0][NumCores-1:0] dep_check_valid;
    logic      [NumClusters-1:0][NumCores-1:0] dep_check_result;
    dep_code_t [NumClusters-1:0][NumCores-1:0] dep_check_code;
    dep_tag_t  [NumClusters-1:0][NumCores-1:0] dep_check_tag;
    logic      [NumClusters-1:0][NumCores-1:0] dep_set_valid;
    logic      [NumClusters-1:0][NumCores-1:0] dep_set_ready;
    dep_code_t [NumClusters-1:0][NumCores-1:0] dep_set_code;
    dep_tag_t  [NumClusters-1:0][NumCores-1:0] dep_set_tag;

    ///////////////////////////////////////
    // Stream Arbiter Dep Matrix Set
    ///////////////////////////////////////
    // There are two sources of input streams to set the dep matrix
    // Source 1: the checkout queues retiring a task (NUM_CORE * NUM_Cluster), normal and dummy set dep
    // Source 2: another chiplet (the chiplet dep set receive queue)
    // In total we have (NUM_CORE * NUM_Cluster) + 1 inputs for the dep matrix set
    localparam int unsigned STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP = NumCores * NumClusters + 1;
    dep_matrix_set_meta_t [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_data;
    logic                 [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_valid;
    logic                 [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_ready;
    dep_matrix_set_meta_t                                             stream_arbiter_dep_matrix_set_oup_data;
    logic                                                             stream_arbiter_dep_matrix_set_oup_valid;
    logic                                                             stream_arbiter_dep_matrix_set_oup_ready;

    ///////////////////////////////////////
    // Stream Demux Set Dep Matrix Cluster ID
    ///////////////////////////////////////
    // Possible to move the demux before the arbiter to support more parallelism
    logic                          stream_demux_set_dep_matrix_cluster_id_inp_valid;
    logic                          stream_demux_set_dep_matrix_cluster_id_inp_ready;
    logic  [ClusterIdWidth-1:0]    stream_demux_set_dep_matrix_cluster_id_oup_sel;
    logic  [NumClusters-1:0]       stream_demux_set_dep_matrix_cluster_id_oup_valid;
    logic  [NumClusters-1:0]       stream_demux_set_dep_matrix_cluster_id_oup_ready;
    ///////////////////////////////////////
    // Stream Demux Set Dep Matrix Core ID
    ///////////////////////////////////////
    logic                              [NumClusters-1:0] stream_demux_set_dep_matrix_core_id_inp_valid;
    logic                              [NumClusters-1:0] stream_demux_set_dep_matrix_core_id_inp_ready;
    logic [NumClusters-1:0][CoreIdWidth-1:0]             stream_demux_set_dep_matrix_core_id_oup_sel;
    logic [NumClusters-1:0][NumCores-1:0]                stream_demux_set_dep_matrix_core_id_oup_valid;
    logic [NumClusters-1:0][NumCores-1:0]                stream_demux_set_dep_matrix_core_id_oup_ready;

    assign task_ready_o = stream_demux_core_idx_inp_ready;
    assign head_o       = waiting_dep_check_task_desc;
    assign head_empty_o = waiting_dep_check_queue_empty;

    //////////////////////////////////////////////////////////////////////
    // Stream demux by core index (assigned_core_id): one waiting queue per core index
    //////////////////////////////////////////////////////////////////////
    stream_demux #(
        .N_OUP ( NumCores                        )
    ) i_stream_demux_core_idx (
        .inp_valid_i ( stream_demux_core_idx_inp_valid ),
        .inp_ready_o ( stream_demux_core_idx_inp_ready ),
        .oup_sel_i   ( stream_demux_core_idx_oup_sel   ),
        .oup_valid_o ( stream_demux_core_idx_oup_valid ),
        .oup_ready_i ( stream_demux_core_idx_oup_ready )
    );
    always_comb begin: compose_stream_demux_core_idx_signals
        stream_demux_core_idx_inp_valid = task_valid_i;
        stream_demux_core_idx_oup_sel = task_i.assigned_core_id;
        for (int unsigned core = 0; core < NumCores; core = core + 1) begin
            stream_demux_core_idx_oup_ready[core] = !waiting_dep_check_queue_full[core];
        end
    end


    for (genvar core = 0; core < NumCores; core = core + 1) begin: gen_waiting_dep_check_queue
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0                               ),
            .DEPTH        ( WaitingQueueDepth                  ),
            .dtype        ( task_desc_t                        )
        ) i_waiting_dep_check_queue (
            .clk_i       ( clk_i                               ),
            .rst_ni      ( rst_ni                              ),
            .testmode_i  ( 1'b0                                ),
            .flush_i     ( 1'b0                                ),
            .full_o      ( waiting_dep_check_queue_full[core]  ),
            .empty_o     ( waiting_dep_check_queue_empty[core] ),
            .usage_o     ( /*not used*/                        ),
            .data_i      ( task_i                              ),
            .push_i      ( waiting_dep_check_queue_push[core]  ),
            .data_o      ( waiting_dep_check_task_desc[core]   ),
            .pop_i       ( waiting_dep_check_queue_pop[core]   )
        );
        assign waiting_dep_check_queue_push[core] = stream_demux_core_idx_oup_valid[core] && !waiting_dep_check_queue_full[core];
        assign waiting_dep_check_queue_pop[core] = dep_check_manager_inp_wait_dep_check_queue_ready[core] && !waiting_dep_check_queue_empty[core];

        bingo_hw_manager_dep_check_manager i_dep_check_manager(
            .clk_i                       ( clk_i                        ),
            .rst_ni                      ( rst_ni                       ),
            .wait_dep_check_queue_valid_i(dep_check_manager_inp_wait_dep_check_queue_valid[core]),
            .wait_dep_check_queue_ready_o(dep_check_manager_inp_wait_dep_check_queue_ready[core]),
            .dep_check_valid_o           (dep_check_manager_oup_dep_check_valid[core]),
            .dep_check_ready_i           (dep_check_manager_oup_dep_check_ready[core]),
            .ready_and_checkout_queue_valid_o(dep_check_manager_oup_ready_and_checkout_queue_valid[core]),
            .ready_and_checkout_queue_ready_i(dep_check_manager_oup_ready_and_checkout_queue_ready[core])
        );
        assign dep_check_manager_inp_wait_dep_check_queue_valid[core] = ~waiting_dep_check_queue_empty[core];
        // To Dep Matrix
        // For the dep matrix, if the dep check is disable, we do not need to send the task to dep matrix
        stream_filter i_stream_filter_dep_check_en_to_dep_matrix (
            .valid_i ( dep_check_manager_oup_dep_check_valid[core]    ),
            .ready_o ( dep_check_manager_oup_dep_check_ready[core]    ),
            .drop_i  ( (!waiting_dep_check_task_desc[core].dep_check_info.dep_check_en) ),
            .valid_o ( demux_dep_matrix_inp_valid[core]  ),
            .ready_i ( demux_dep_matrix_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NumClusters                        )
        ) i_stream_demux_from_waiting_dep_check_queue_to_dep_matrix (
            .inp_valid_i ( demux_dep_matrix_inp_valid[core]    ),
            .inp_ready_o ( demux_dep_matrix_inp_ready[core]    ),
            .oup_sel_i   ( waiting_dep_check_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_dep_matrix_oup_valid[core]    ),
            .oup_ready_i ( demux_dep_matrix_oup_ready[core]    )
        );
        // To Ready Queue and Checkout Queue
        // We need a filter to drop the dummy check tasks
        // The dummy check does not need to go to the ready and checkout queue
        stream_filter i_stream_filter_dummy_check_task_to_ready_and_checkout_queue (
            .valid_i ( dep_check_manager_oup_ready_and_checkout_queue_valid[core]    ),
            .ready_o ( dep_check_manager_oup_ready_and_checkout_queue_ready[core]    ),
            .drop_i  ( (waiting_dep_check_task_desc[core].task_type == bingo_hw_manager_pkg::TaskDummy) && (waiting_dep_check_task_desc[core].dep_check_info.dep_check_en) ), // Drop if it is a dummy check task
            .valid_o ( demux_ready_and_checkout_queue_inp_valid[core]  ),
            .ready_i ( demux_ready_and_checkout_queue_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NumClusters                        )
        ) i_stream_demux_from_waiting_dep_check_queue_to_ready_and_checkout_queue (
            .inp_valid_i ( demux_ready_and_checkout_queue_inp_valid[core]    ),
            .inp_ready_o ( demux_ready_and_checkout_queue_inp_ready[core]    ),
            // Physical cluster: the logical one unless the task goes to a substitute
            .oup_sel_i   ( offer_cluster_i[core]                             ),
            .oup_valid_o ( offer_valid_o[core]                               ),
            .oup_ready_i ( offer_ready_i[core]                               )
        );

    end


    ////////////////////////////////////////////////////////////////////////
    // Dep Matrix
    //////////////////////////////////////////////////////////////////////

    for (genvar cluster = 0; cluster < NumClusters; cluster = cluster + 1) begin: gen_dep_matrix
        bingo_hw_manager_dep_matrix #(
            .DEP_MATRIX_ROWS(NumCores),
            .DEP_MATRIX_COLS(NumCores),
            .TagWidth(DepTagWidth)
        ) i_dep_matrix (
            .clk_i             (clk_i                    ),
            .rst_ni            (rst_ni                   ),
            .dep_check_valid_i (dep_check_valid[cluster] ),
            .dep_check_code_i  (dep_check_code[cluster]  ),
            .dep_check_tag_i   (dep_check_tag[cluster]   ),
            .dep_check_result_o(dep_check_result[cluster]),
            .dep_set_valid_i   (dep_set_valid[cluster]   ),
            .dep_set_ready_o   (dep_set_ready[cluster]   ),
            .dep_set_code_i    (dep_set_code[cluster]    ),
            .dep_set_tag_i     (dep_set_tag[cluster]     )
        );
    end

    always_comb begin : connect_dep_check_for_dep_matrix
        for ( int cluster = 0; cluster < NumClusters; cluster = cluster + 1) begin
            for ( int core = 0; core < NumCores; core = core + 1) begin
                dep_check_valid[cluster][core] = demux_dep_matrix_oup_valid[core][cluster];
                demux_dep_matrix_oup_ready[core][cluster] = dep_check_result[cluster][core];
                dep_check_code[cluster][core] = waiting_dep_check_task_desc[core].dep_check_info.dep_check_code;
                dep_check_tag[cluster][core] = waiting_dep_check_task_desc[core].dep_check_info.dep_check_tag;
            end
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Stream Arbiter Dep Matrix Set
    //////////////////////////////////////////////////////////////////////
    stream_arbiter #(
        .DATA_T(dep_matrix_set_meta_t),
        .N_INP (STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP)
    ) i_stream_arbiter_dep_matrix_set(
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .inp_data_i (stream_arbiter_dep_matrix_set_inp_data ),
        .inp_valid_i(stream_arbiter_dep_matrix_set_inp_valid),
        .inp_ready_o(stream_arbiter_dep_matrix_set_inp_ready),
        .oup_data_o (stream_arbiter_dep_matrix_set_oup_data ),
        .oup_valid_o(stream_arbiter_dep_matrix_set_oup_valid),
        .oup_ready_i(stream_arbiter_dep_matrix_set_oup_ready)
    );
    always_comb begin : compose_stream_arbiter_dep_matrix_set_inputs
        // For Checkout Queue
        int stream_arbiter_inp_idx;
        for ( int core = 0; core < NumCores; core = core + 1) begin
            for ( int cluster = 0; cluster < NumClusters; cluster = cluster + 1) begin
                    stream_arbiter_inp_idx = core + cluster * NumCores;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_id = set_i[core][cluster].dep_set_info.dep_set_cluster_id;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_col = set_i[core][cluster].assigned_core_id;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_set_tag = set_i[core][cluster].dep_set_info.dep_set_tag;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_set_code  = set_i[core][cluster].dep_set_info.dep_set_code;
                    // Valid only for a head that may retire, so a task that ran
                    // already has its done here (bingo_hw_manager_checkout_queue)
                    stream_arbiter_dep_matrix_set_inp_valid[stream_arbiter_inp_idx] = set_valid_i[core][cluster];
                    set_ready_o[core][cluster] = stream_arbiter_dep_matrix_set_inp_ready[stream_arbiter_inp_idx];
            end
        end
        // For Chiplet Set Queue
        stream_arbiter_dep_matrix_set_inp_data[NumCores * NumClusters].dep_matrix_id  = remote_set_i.dep_set_info.dep_set_cluster_id;
        stream_arbiter_dep_matrix_set_inp_data[NumCores * NumClusters].dep_matrix_col = remote_set_i.assigned_core_id;
        stream_arbiter_dep_matrix_set_inp_data[NumCores * NumClusters].dep_matrix_set_tag = remote_set_i.dep_set_info.dep_set_tag;
        stream_arbiter_dep_matrix_set_inp_data[NumCores * NumClusters].dep_set_code   = remote_set_i.dep_set_info.dep_set_code;
        stream_arbiter_dep_matrix_set_inp_valid[NumCores * NumClusters] = remote_set_valid_i;
        remote_set_ready_o = stream_arbiter_dep_matrix_set_inp_ready[NumCores * NumClusters];
        stream_arbiter_dep_matrix_set_oup_ready = stream_demux_set_dep_matrix_cluster_id_inp_ready;
    end
    //////////////////////////////////////////////////////////////////////
    // Stream Demux Set Dep Matrix Cluster ID
    //////////////////////////////////////////////////////////////////////
    stream_demux #(
        .N_OUP(NumClusters)
    ) i_stream_demux_set_dep_matrix_cluster_id (
        .inp_valid_i(stream_demux_set_dep_matrix_cluster_id_inp_valid),
        .inp_ready_o(stream_demux_set_dep_matrix_cluster_id_inp_ready),
        .oup_sel_i  (stream_demux_set_dep_matrix_cluster_id_oup_sel),
        .oup_valid_o(stream_demux_set_dep_matrix_cluster_id_oup_valid),
        .oup_ready_i(stream_demux_set_dep_matrix_cluster_id_oup_ready)
    );
    assign stream_demux_set_dep_matrix_cluster_id_inp_valid = stream_arbiter_dep_matrix_set_oup_valid;
    assign stream_demux_set_dep_matrix_cluster_id_oup_sel = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_id;

    //////////////////////////////////////////////////////////////////////
    // Stream Demux Set Dep Matrix Core ID
    //////////////////////////////////////////////////////////////////////
    for (genvar cluster= 0; cluster < NumClusters; cluster = cluster + 1) begin: gen_set_dep_matrix_core_id
        stream_demux #(
            .N_OUP(NumCores)
        ) i_stream_demux_set_dep_matrix_core_id (
            .inp_valid_i(stream_demux_set_dep_matrix_core_id_inp_valid[cluster]),
            .inp_ready_o(stream_demux_set_dep_matrix_core_id_inp_ready[cluster]),
            .oup_sel_i  (stream_demux_set_dep_matrix_core_id_oup_sel[cluster]  ),
            .oup_valid_o(stream_demux_set_dep_matrix_core_id_oup_valid[cluster]),
            .oup_ready_i(stream_demux_set_dep_matrix_core_id_oup_ready[cluster])
        );
        assign stream_demux_set_dep_matrix_cluster_id_oup_ready[cluster] = stream_demux_set_dep_matrix_core_id_inp_ready[cluster];
        assign stream_demux_set_dep_matrix_core_id_inp_valid[cluster] = stream_demux_set_dep_matrix_cluster_id_oup_valid[cluster];
        assign stream_demux_set_dep_matrix_core_id_oup_sel[cluster] = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_col;
    end

    always_comb begin : connect_dep_set_for_dep_matrix
        for ( int cluster = 0; cluster < NumClusters; cluster = cluster + 1) begin
            for ( int core = 0; core < NumCores; core = core + 1) begin
                dep_set_valid[cluster][core] = stream_demux_set_dep_matrix_core_id_oup_valid[cluster][core];
                stream_demux_set_dep_matrix_core_id_oup_ready[cluster][core] = dep_set_ready[cluster][core];
                dep_set_code[cluster][core] = stream_arbiter_dep_matrix_set_oup_data.dep_set_code;
                dep_set_tag[cluster][core] = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_set_tag;
            end
        end
    end
endmodule
