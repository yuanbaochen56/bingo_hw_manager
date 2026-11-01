`timescale 1ns/1ps
`include "bingo_hw_manager/typedef.svh"

// Combinational slot mapping table for the unit test (bingo_hw_manager_slot_table
// keeps the same choice in a register)
module tb_core_remap_smt #(
    parameter int unsigned NumCores = 3,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter logic [NumCores-1:0][NumClusters-1:0][CoreTypeIdWidth-1:0] CoreTypeId =
        {(NumCores * NumClusters){CoreTypeIdWidth'(1)}},
    parameter logic [2:0] LevelMask = 3'b001
) (
    input  logic [NumCores-1:0][NumClusters-1:0]                     fenced_i,
    output logic [NumCores-1:0][NumClusters-1:0]                     found_o,
    output logic [NumCores-1:0][NumClusters-1:0][CoreIdWidth-1:0]    core_o,
    output logic [NumCores-1:0][NumClusters-1:0][ClusterIdWidth-1:0] cluster_o
);
    for (genvar c = 0; c < NumCores; c++) begin : gen_c
        for (genvar cl = 0; cl < NumClusters; cl++) begin : gen_cl
            bingo_hw_manager_substitute_sel #(
                .NumCores(NumCores), .NumClusters(NumClusters), .CoreIdWidth(CoreIdWidth),
                .ClusterIdWidth(ClusterIdWidth), .CoreTypeIdWidth(CoreTypeIdWidth),
                .CoreTypeId(CoreTypeId), .LevelMask(LevelMask)
            ) i_sel (
                .logical_core_i(CoreIdWidth'(c)), .logical_cluster_i(ClusterIdWidth'(cl)),
                .fenced_i(fenced_i), .found_o(found_o[c][cl]), .core_o(core_o[c][cl]),
                .cluster_o(cluster_o[c][cl])
            );
        end
    end
endmodule

// Unit test of bingo_hw_manager_core_remap (remap only once a fenced core is retired).
module tb_bingo_hw_manager_core_remap;

    localparam int unsigned NUM_CORES = 3;
    localparam int unsigned NUM_CLUSTERS = 2;
    localparam int unsigned CORE_ID_WIDTH = 2;
    localparam int unsigned CLUSTER_ID_WIDTH = 1;
    // Second instance, CoreTypeId[core][cluster] differs per cluster:
    //   cluster 0: core 0 type 1, core 1 type 2, core 2 type 1
    //   cluster 1: core 0 type 3, core 1 type 3, core 2 type 0 (never substituted)
    localparam logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][3:0] RESTRICTED_TYPES = '{
        '{4'd0, 4'd1},  // core 2: cluster 1, cluster 0
        '{4'd3, 4'd2},  // core 1
        '{4'd3, 4'd1}   // core 0
    };
    // Third instance, types shared across the clusters:
    //   cluster 0: core 0 type 1, core 1 type 2, core 2 type 2
    //   cluster 1: core 0 type 2, core 1 type 1, core 2 type 4 (unique)
    localparam logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][3:0] CROSS_TYPES = '{
        '{4'd4, 4'd2},  // core 2: cluster 1, cluster 0
        '{4'd1, 4'd2},  // core 1
        '{4'd2, 4'd1}   // core 0
    };

    logic req_valid_i;
    logic [CORE_ID_WIDTH-1:0] logical_core_i;
    logic [CLUSTER_ID_WIDTH-1:0] logical_cluster_i;
    logic remappable_i;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_fenced_i;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0] core_retired_i;

    // Port structs of bingo_hw_manager_core_remap: the request, the slot state
    // (fenced and retired, never stuck or rejected), the table, no parking
    `BINGO_HW_MANAGER_TYPEDEF_REMAP_REQ_T(remap_req_t, CORE_ID_WIDTH, CLUSTER_ID_WIDTH)
    `BINGO_HW_MANAGER_TYPEDEF_REMAP_SEL_T(remap_sel_t, CORE_ID_WIDTH, CLUSTER_ID_WIDTH)
    `BINGO_HW_MANAGER_TYPEDEF_SLOT_STATE_T(slot_state_t, NUM_CORES, NUM_CLUSTERS)
    `BINGO_HW_MANAGER_TYPEDEF_SMT_T(smt_t, NUM_CORES, NUM_CLUSTERS, CORE_ID_WIDTH, CLUSTER_ID_WIDTH)
    `BINGO_HW_MANAGER_TYPEDEF_PARK_T(park_t, NUM_CORES, NUM_CLUSTERS)
    remap_req_t  remap_req;
    slot_state_t slot_state;
    assign remap_req  = '{valid: req_valid_i, core: logical_core_i, cluster: logical_cluster_i,
                          remappable: remappable_i, no_replay: 1'b0};
    assign slot_state = '{fenced: core_fenced_i, retired: core_retired_i, stuck: '0, rejected: '0};

    logic select_valid_o;
    logic [CORE_ID_WIDTH-1:0] physical_core_o;
    logic [CLUSTER_ID_WIDTH-1:0] physical_cluster_o;

    logic select_valid_r;
    logic [CORE_ID_WIDTH-1:0] physical_core_r;
    logic [CLUSTER_ID_WIDTH-1:0] physical_cluster_r;

    logic select_valid_x;
    logic [CORE_ID_WIDTH-1:0] physical_core_x;
    logic [CLUSTER_ID_WIDTH-1:0] physical_cluster_x;

    logic select_valid_l1;
    logic [CORE_ID_WIDTH-1:0] physical_core_l1;
    logic [CLUSTER_ID_WIDTH-1:0] physical_cluster_l1;

    // Slot mapping tables of the four instances
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0]                       smt_d_found;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CORE_ID_WIDTH-1:0]    smt_d_core;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CLUSTER_ID_WIDTH-1:0] smt_d_cluster;
    tb_core_remap_smt #(.NumCores(NUM_CORES), .NumClusters(NUM_CLUSTERS), .CoreIdWidth(CORE_ID_WIDTH), .ClusterIdWidth(CLUSTER_ID_WIDTH), .LevelMask(3'b011)) i_smt_d (
        .fenced_i(core_fenced_i), .found_o(smt_d_found), .core_o(smt_d_core), .cluster_o(smt_d_cluster)
    );
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0]                       smt_r_found;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CORE_ID_WIDTH-1:0]    smt_r_core;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CLUSTER_ID_WIDTH-1:0] smt_r_cluster;
    tb_core_remap_smt #(.NumCores(NUM_CORES), .NumClusters(NUM_CLUSTERS), .CoreIdWidth(CORE_ID_WIDTH), .ClusterIdWidth(CLUSTER_ID_WIDTH), .CoreTypeIdWidth(4), .CoreTypeId(RESTRICTED_TYPES)) i_smt_r (
        .fenced_i(core_fenced_i), .found_o(smt_r_found), .core_o(smt_r_core), .cluster_o(smt_r_cluster)
    );
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0]                       smt_x_found;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CORE_ID_WIDTH-1:0]    smt_x_core;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CLUSTER_ID_WIDTH-1:0] smt_x_cluster;
    tb_core_remap_smt #(.NumCores(NUM_CORES), .NumClusters(NUM_CLUSTERS), .CoreIdWidth(CORE_ID_WIDTH), .ClusterIdWidth(CLUSTER_ID_WIDTH), .CoreTypeIdWidth(4), .CoreTypeId(CROSS_TYPES), .LevelMask(3'b011)) i_smt_x (
        .fenced_i(core_fenced_i), .found_o(smt_x_found), .core_o(smt_x_core), .cluster_o(smt_x_cluster)
    );
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0]                       smt_l1_found;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CORE_ID_WIDTH-1:0]    smt_l1_core;
    logic [NUM_CORES-1:0][NUM_CLUSTERS-1:0][CLUSTER_ID_WIDTH-1:0] smt_l1_cluster;
    tb_core_remap_smt #(.NumCores(NUM_CORES), .NumClusters(NUM_CLUSTERS), .CoreIdWidth(CORE_ID_WIDTH), .ClusterIdWidth(CLUSTER_ID_WIDTH), .CoreTypeIdWidth(4), .CoreTypeId(CROSS_TYPES)) i_smt_l1 (
        .fenced_i(core_fenced_i), .found_o(smt_l1_found), .core_o(smt_l1_core), .cluster_o(smt_l1_cluster)
    );

    // Levels 1 and 2 (substitutes in other clusters allowed)
    remap_sel_t sel_dut;
    assign select_valid_o = sel_dut.valid;
    assign physical_core_o = sel_dut.core;
    assign physical_cluster_o = sel_dut.cluster;
    bingo_hw_manager_core_remap #(
        .NumCores(NUM_CORES),
        .NumClusters(NUM_CLUSTERS),
        .CoreIdWidth(CORE_ID_WIDTH),
        .ClusterIdWidth(CLUSTER_ID_WIDTH),
        .SubstituteLevelMask(3'b011),
        .remap_req_t(remap_req_t),
        .remap_sel_t(remap_sel_t),
        .slot_state_t(slot_state_t),
        .smt_t(smt_t),
        .park_t(park_t)
    ) dut (
        .req_i(remap_req),
        .slot_i(slot_state),
        .remote_type_en_i('1),
        .smt_i('{found: smt_d_found, core: smt_d_core, cluster: smt_d_cluster}),
        .smt_update_i(1'b0),
        .park_i('0),
        .sel_o(sel_dut)
    );

    remap_sel_t sel_dut_restricted;
    assign select_valid_r = sel_dut_restricted.valid;
    assign physical_core_r = sel_dut_restricted.core;
    assign physical_cluster_r = sel_dut_restricted.cluster;
    bingo_hw_manager_core_remap #(
        .NumCores(NUM_CORES),
        .NumClusters(NUM_CLUSTERS),
        .CoreIdWidth(CORE_ID_WIDTH),
        .ClusterIdWidth(CLUSTER_ID_WIDTH),
        .CoreTypeIdWidth(4),
        .CoreTypeId(RESTRICTED_TYPES),
        .remap_req_t(remap_req_t),
        .remap_sel_t(remap_sel_t),
        .slot_state_t(slot_state_t),
        .smt_t(smt_t),
        .park_t(park_t)
    ) dut_restricted (
        .req_i(remap_req),
        .slot_i(slot_state),
        .remote_type_en_i('1),
        .smt_i('{found: smt_r_found, core: smt_r_core, cluster: smt_r_cluster}),
        .smt_update_i(1'b0),
        .park_i('0),
        .sel_o(sel_dut_restricted)
    );

    remap_sel_t sel_dut_cross;
    assign select_valid_x = sel_dut_cross.valid;
    assign physical_core_x = sel_dut_cross.core;
    assign physical_cluster_x = sel_dut_cross.cluster;
    bingo_hw_manager_core_remap #(
        .NumCores(NUM_CORES),
        .NumClusters(NUM_CLUSTERS),
        .CoreIdWidth(CORE_ID_WIDTH),
        .ClusterIdWidth(CLUSTER_ID_WIDTH),
        .CoreTypeIdWidth(4),
        .CoreTypeId(CROSS_TYPES),
        .SubstituteLevelMask(3'b011),
        .remap_req_t(remap_req_t),
        .remap_sel_t(remap_sel_t),
        .slot_state_t(slot_state_t),
        .smt_t(smt_t),
        .park_t(park_t)
    ) dut_cross (
        .req_i(remap_req),
        .slot_i(slot_state),
        .remote_type_en_i('1),
        .smt_i('{found: smt_x_found, core: smt_x_core, cluster: smt_x_cluster}),
        .smt_update_i(1'b0),
        .park_i('0),
        .sel_o(sel_dut_cross)
    );

    // Same types, level 1 only (default): never leaves the cluster
    remap_sel_t sel_dut_l1;
    assign select_valid_l1 = sel_dut_l1.valid;
    assign physical_core_l1 = sel_dut_l1.core;
    assign physical_cluster_l1 = sel_dut_l1.cluster;
    bingo_hw_manager_core_remap #(
        .NumCores(NUM_CORES),
        .NumClusters(NUM_CLUSTERS),
        .CoreIdWidth(CORE_ID_WIDTH),
        .ClusterIdWidth(CLUSTER_ID_WIDTH),
        .CoreTypeIdWidth(4),
        .CoreTypeId(CROSS_TYPES),
        .remap_req_t(remap_req_t),
        .remap_sel_t(remap_sel_t),
        .slot_state_t(slot_state_t),
        .smt_t(smt_t),
        .park_t(park_t)
    ) dut_l1 (
        .req_i(remap_req),
        .slot_i(slot_state),
        .remote_type_en_i('1),
        .smt_i('{found: smt_l1_found, core: smt_l1_core, cluster: smt_l1_cluster}),
        .smt_update_i(1'b0),
        .park_i('0),
        .sel_o(sel_dut_l1)
    );

    task automatic expect_l1(
        input logic expected_valid,
        input logic [CORE_ID_WIDTH-1:0] expected_core
    );
    begin
        #1;
        if (select_valid_l1 !== expected_valid) begin
            $fatal(1, "level 1 only: select_valid mismatch: expected %0b got %0b",
                   expected_valid, select_valid_l1);
        end
        if (expected_valid && ((physical_core_l1 !== expected_core) ||
                               (physical_cluster_l1 !== logical_cluster_i))) begin
            $fatal(1, "level 1 only: expected core %0d cluster %0d, got core %0d cluster %0d",
                   expected_core, logical_cluster_i, physical_core_l1, physical_cluster_l1);
        end
    end
    endtask

    task automatic clear_inputs;
    begin
        req_valid_i = 1'b0;
        logical_core_i = '0;
        logical_cluster_i = '0;
        remappable_i = 1'b1;
        core_fenced_i = '0;
        core_retired_i = '0;
    end
    endtask

    task automatic expect_select(
        input logic expected_valid,
        input logic [CORE_ID_WIDTH-1:0] expected_core,
        input logic [CLUSTER_ID_WIDTH-1:0] expected_cluster
    );
    begin
        #1;
        if (select_valid_o !== expected_valid) begin
            $fatal(1, "select_valid mismatch: expected %0b got %0b",
                   expected_valid, select_valid_o);
        end
        if (physical_core_o !== expected_core) begin
            $fatal(1, "physical_core mismatch: expected %0d got %0d",
                   expected_core, physical_core_o);
        end
        if (physical_cluster_o !== expected_cluster) begin
            $fatal(1, "physical_cluster mismatch: expected %0d got %0d",
                   expected_cluster, physical_cluster_o);
        end
    end
    endtask

    task automatic expect_restricted(
        input logic expected_valid,
        input logic [CORE_ID_WIDTH-1:0] expected_core
    );
    begin
        #1;
        if (select_valid_r !== expected_valid) begin
            $fatal(1, "restricted types: select_valid mismatch: expected %0b got %0b",
                   expected_valid, select_valid_r);
        end
        if (expected_valid && (physical_core_r !== expected_core)) begin
            $fatal(1, "restricted types: physical_core mismatch: expected %0d got %0d",
                   expected_core, physical_core_r);
        end
        if (expected_valid && (physical_cluster_r !== logical_cluster_i)) begin
            $fatal(1, "restricted types: physical_cluster mismatch: expected %0d got %0d",
                   logical_cluster_i, physical_cluster_r);
        end
    end
    endtask

    task automatic expect_cross(
        input logic expected_valid,
        input logic [CORE_ID_WIDTH-1:0] expected_core,
        input logic [CLUSTER_ID_WIDTH-1:0] expected_cluster
    );
    begin
        #1;
        if (select_valid_x !== expected_valid) begin
            $fatal(1, "cross-cluster types: select_valid mismatch: expected %0b got %0b",
                   expected_valid, select_valid_x);
        end
        if (expected_valid && ((physical_core_x !== expected_core) ||
                               (physical_cluster_x !== expected_cluster))) begin
            $fatal(1, "cross-cluster types: expected core %0d cluster %0d, got core %0d cluster %0d",
                   expected_core, expected_cluster, physical_core_x, physical_cluster_x);
        end
    end
    endtask

    // Fenced and retired (outstanding tasks already replayed)
    task automatic retire(input int unsigned core, input int unsigned cluster);
    begin
        core_fenced_i[core][cluster]  = 1'b1;
        core_retired_i[core][cluster] = 1'b1;
    end
    endtask

    initial begin
        clear_inputs();

        $display("Checking idle request");
        logical_core_i = 2'd1;
        expect_select(1'b0, 2'd1, 1'd0);

        $display("Checking healthy logical core keeps its task");
        req_valid_i = 1'b1;
        expect_select(1'b1, 2'd1, 1'd0);

        $display("Checking a retired core in another cluster does not matter");
        retire(1, 1);
        expect_select(1'b1, 2'd1, 1'd0);

        $display("Checking a fenced core whose tasks are still being replayed is held");
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd0;
        core_fenced_i[0][0] = 1'b1;
        expect_select(1'b0, 2'd0, 1'd0);

        $display("Checking retired logical core remaps to the lowest live core of its cluster");
        retire(0, 0);
        expect_select(1'b1, 2'd1, 1'd0);

        $display("Checking fenced candidates are skipped");
        core_fenced_i[1][0] = 1'b1;
        expect_select(1'b1, 2'd2, 1'd0);

        $display("Checking a cluster without live substitute hands over to another cluster");
        core_fenced_i[2][0] = 1'b1;
        expect_select(1'b1, 2'd0, 1'd1);

        $display("Checking no live substitute in the chiplet holds the task");
        core_fenced_i[0][1] = 1'b1;
        core_fenced_i[1][1] = 1'b1;
        core_fenced_i[2][1] = 1'b1;
        expect_select(1'b0, 2'd0, 1'd0);

        $display("Checking remap prefers the requested cluster over a lower one");
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd2;
        logical_cluster_i = 1'd1;
        retire(2, 1);
        core_fenced_i[0][1] = 1'b1;
        expect_select(1'b1, 2'd1, 1'd1);

        $display("Checking non-remappable (dummy-set / skipped) task");
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd0;
        remappable_i = 1'b0;
        core_fenced_i[0][0] = 1'b1;
        expect_select(1'b0, 2'd0, 1'd0);      // held while the core is replayed
        core_retired_i[0][0] = 1'b1;
        expect_select(1'b1, 2'd0, 1'd0);      // then stays on its retired core

        $display("Checking CoreTypeId restricts the substitute, per cluster");
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd0;
        retire(0, 0);
        expect_restricted(1'b1, 2'd2);        // core 1 live but of another type
        core_fenced_i[2][0] = 1'b1;
        expect_restricted(1'b0, 2'd0);        // only same-type core fenced -> hold
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd1;
        retire(1, 0);
        expect_restricted(1'b0, 2'd1);        // type 2 appears once in cluster 0
        clear_inputs();
        req_valid_i = 1'b1;
        logical_cluster_i = 1'd1;
        logical_core_i = 2'd2;
        retire(2, 1);
        expect_restricted(1'b0, 2'd2);        // type 0 never hands over its tasks
        logical_core_i = 2'd1;
        retire(1, 1);
        expect_restricted(1'b1, 2'd0);        // cluster 1: core 0 has type 3 too
        clear_inputs();
        req_valid_i = 1'b1;
        logical_cluster_i = 1'd1;
        logical_core_i = 2'd0;
        retire(0, 1);
        core_fenced_i[1][0] = 1'b1;           // other cluster does not matter
        expect_restricted(1'b1, 2'd1);

        $display("Checking CoreTypeId shared across clusters");
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd0;
        retire(0, 0);
        expect_cross(1'b1, 2'd1, 1'd1);       // type 1: only core 1 of cluster 1
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd1;
        retire(1, 0);
        expect_cross(1'b1, 2'd2, 1'd0);       // type 2: own cluster before core 0 of cluster 1
        core_fenced_i[2][0] = 1'b1;
        expect_cross(1'b1, 2'd0, 1'd1);       // then the other cluster
        core_fenced_i[0][1] = 1'b1;
        expect_cross(1'b0, 2'd0, 1'd0);       // every type-2 core fenced: hold
        clear_inputs();
        req_valid_i = 1'b1;
        logical_cluster_i = 1'd1;
        logical_core_i = 2'd0;
        retire(0, 1);
        expect_cross(1'b1, 2'd1, 1'd0);       // type 2 of cluster 1: lowest of cluster 0
        logical_core_i = 2'd2;
        retire(2, 1);
        expect_cross(1'b0, 2'd0, 1'd0);       // type 4 exists once in the chiplet

        $display("Checking level 1 only keeps the substitute in the cluster");
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd0;
        retire(0, 0);
        expect_l1(1'b0, 2'd0);                // type 1 only in cluster 1: hold
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd1;
        retire(1, 0);
        expect_l1(1'b1, 2'd2);                // type 2: core 2 of cluster 0
        core_fenced_i[2][0] = 1'b1;
        expect_l1(1'b0, 2'd0);                // not core 0 of cluster 1
        expect_cross(1'b1, 2'd0, 1'd1);       // which level 2 would take

        $display("Checking out-of-range logical core");
        clear_inputs();
        req_valid_i = 1'b1;
        logical_core_i = 2'd3;
        expect_select(1'b0, 2'd3, 1'd0);

        $display("All core remap tests passed");
        $finish;
    end

endmodule
