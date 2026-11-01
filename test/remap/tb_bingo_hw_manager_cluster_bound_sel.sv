`timescale 1ns/1ps

module tb_bingo_hw_manager_cluster_bound_sel;
    localparam logic [2:0][1:0][3:0] Types =
        '{{4'd2, 4'd2}, '{4'd1, 4'd1}, '{4'd1, 4'd1}};
    logic [1:0] logical_core;
    logic logical_cluster;
    logic [2:0][1:0] fenced;
    logic found;
    logic [1:0] core;
    logic cluster;

    bingo_hw_manager_substitute_sel #(
        .NumCores(3), .NumClusters(2), .CoreIdWidth(2), .ClusterIdWidth(1),
        .CoreTypeId(Types), .LevelMask(3'b011), .L2TypeEn(16'hfffd)
    ) dut (
        .logical_core_i(logical_core), .logical_cluster_i(logical_cluster),
        .fenced_i(fenced), .found_o(found), .core_o(core), .cluster_o(cluster)
    );

    initial begin
        logical_core = 0;
        logical_cluster = 0;
        fenced = '0;
        fenced[0][0] = 1;
        #1;
        if (!found || core != 1 || cluster != 0)
            $fatal(1, "B1: cluster-bound type lost its L1 substitute");
        fenced[1][0] = 1;
        #1;
        if (found || dut.candidate[0][1] || dut.candidate[1][1])
            $fatal(1, "B1: cluster-bound type selected an L2 substitute");
        logical_core = 2;
        fenced[2][0] = 1;
        #1;
        if (!found || core != 2 || cluster != 1)
            $fatal(1, "B1: another type lost its L2 substitute");
        fenced = '0;
        logical_core = 0;
        #1;
        if (!found || core != 0 || cluster != 0)
            $fatal(1, "B1: own slot changed");
        $display("Cluster-bound selector B1 passed");
        $finish;
    end
endmodule
