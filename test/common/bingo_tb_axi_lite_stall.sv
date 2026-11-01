// Testbench helper: random handshake stalls on every channel of an AXI-Lite
// link (common_cells stream_delay per channel; keeps valid stable).
module bingo_tb_axi_lite_stall #(
    parameter bit          Enable    = 1'b1,
    parameter logic [15:0] Seed      = 16'd1,
    parameter type         aw_chan_t = logic,
    parameter type         w_chan_t  = logic,
    parameter type         b_chan_t  = logic,
    parameter type         ar_chan_t = logic,
    parameter type         r_chan_t  = logic,
    parameter type         req_t     = logic,
    parameter type         resp_t    = logic
) (
    input  logic  clk_i,
    input  logic  rst_ni,
    input  req_t  slv_req_i,
    output resp_t slv_resp_o,
    output req_t  mst_req_o,
    input  resp_t mst_resp_i
);
    stream_delay #(.StallRandom(Enable), .FixedDelay(0), .payload_t(aw_chan_t), .Seed(Seed)) i_aw (
        .clk_i, .rst_ni,
        .payload_i(slv_req_i.aw), .ready_o(slv_resp_o.aw_ready), .valid_i(slv_req_i.aw_valid),
        .payload_o(mst_req_o.aw), .ready_i(mst_resp_i.aw_ready), .valid_o(mst_req_o.aw_valid));
    stream_delay #(.StallRandom(Enable), .FixedDelay(0), .payload_t(w_chan_t), .Seed(Seed + 16'd1)) i_w (
        .clk_i, .rst_ni,
        .payload_i(slv_req_i.w), .ready_o(slv_resp_o.w_ready), .valid_i(slv_req_i.w_valid),
        .payload_o(mst_req_o.w), .ready_i(mst_resp_i.w_ready), .valid_o(mst_req_o.w_valid));
    stream_delay #(.StallRandom(Enable), .FixedDelay(0), .payload_t(b_chan_t), .Seed(Seed + 16'd2)) i_b (
        .clk_i, .rst_ni,
        .payload_i(mst_resp_i.b), .ready_o(mst_req_o.b_ready), .valid_i(mst_resp_i.b_valid),
        .payload_o(slv_resp_o.b), .ready_i(slv_req_i.b_ready), .valid_o(slv_resp_o.b_valid));
    stream_delay #(.StallRandom(Enable), .FixedDelay(0), .payload_t(ar_chan_t), .Seed(Seed + 16'd3)) i_ar (
        .clk_i, .rst_ni,
        .payload_i(slv_req_i.ar), .ready_o(slv_resp_o.ar_ready), .valid_i(slv_req_i.ar_valid),
        .payload_o(mst_req_o.ar), .ready_i(mst_resp_i.ar_ready), .valid_o(mst_req_o.ar_valid));
    stream_delay #(.StallRandom(Enable), .FixedDelay(0), .payload_t(r_chan_t), .Seed(Seed + 16'd4)) i_r (
        .clk_i, .rst_ni,
        .payload_i(mst_resp_i.r), .ready_o(mst_req_o.r_ready), .valid_i(mst_resp_i.r_valid),
        .payload_o(slv_resp_o.r), .ready_i(slv_req_i.r_ready), .valid_o(slv_resp_o.r_valid));
endmodule
