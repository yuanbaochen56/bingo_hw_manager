`timescale 1ns/1ps

// Unit testbench for bingo_hw_manager_dep_matrix (identity-aware presence-bit
// scoreboard).
//
// Stimulus is driven on the negedge and the DUT registers update on the posedge,
// so a non-destructive "peek" can read the combinational result and deassert
// dep_check_valid before the next posedge (the clear only fires when a check is
// both valid and passing at a clock edge).

module tb_bingo_hw_manager_dep_matrix();

    localparam int unsigned N     = 4;
    localparam int unsigned TAG_W = 3;

    logic clk_i;
    logic rst_ni;
    int   errors = 0;

    // Packed arrays matching the module's port types (dep_code_t [N-1:0], dep_tag_t [N-1:0]).
    logic [N-1:0]              t_check_valid,  t_check_result, t_set_valid, t_set_ready;
    logic [N-1:0][N-1:0]       t_check_code,   t_set_code;
    logic [N-1:0][TAG_W-1:0]   t_check_tag,    t_set_tag;

    bingo_hw_manager_dep_matrix #(
        .DEP_MATRIX_ROWS(N), .DEP_MATRIX_COLS(N), .TagWidth(TAG_W)
    ) dut (
        .clk_i, .rst_ni,
        .dep_check_valid_i(t_check_valid), .dep_check_code_i(t_check_code),
        .dep_check_tag_i(t_check_tag), .dep_check_result_o(t_check_result),
        .dep_set_valid_i(t_set_valid), .dep_set_ready_o(t_set_ready),
        .dep_set_code_i(t_set_code), .dep_set_tag_i(t_set_tag)
    );

    initial clk_i = 0;
    always #5 clk_i = ~clk_i;

    // ---- Helpers ----
    task automatic t_set(input int col, input logic [N-1:0] rows, input logic [TAG_W-1:0] tag);
        @(negedge clk_i); t_set_valid = '0; t_set_valid[col] = 1'b1; t_set_code[col] = rows; t_set_tag[col] = tag;
        @(posedge clk_i); @(negedge clk_i); t_set_valid = '0; t_set_code[col] = '0;
    endtask
    task automatic t_consume(input int row, input logic [N-1:0] cols, input logic [TAG_W-1:0] tag);
        @(negedge clk_i); t_check_valid = '0; t_check_valid[row] = 1'b1; t_check_code[row] = cols; t_check_tag[row] = tag;
        @(posedge clk_i); @(negedge clk_i); t_check_valid = '0; t_check_code[row] = '0;
    endtask
    task automatic t_peek(input int row, input logic [N-1:0] cols, input logic [TAG_W-1:0] tag, output logic res);
        t_check_valid = '0; t_check_valid[row] = 1'b1; t_check_code[row] = cols; t_check_tag[row] = tag; #1;
        res = t_check_result[row]; t_check_valid[row] = 1'b0; t_check_code[row] = '0;
    endtask

    task automatic expect_eq(input logic got, input logic exp, input string msg);
        if (got !== exp) begin errors++; $error("FAIL: %s (got=%0b exp=%0b)", msg, got, exp); end
        else $display("ok: %s = %0b", msg, got);
    endtask

    logic res;
    initial begin
        t_check_valid='0; t_set_valid='0; t_check_code='0; t_set_code='0; t_check_tag='0; t_set_tag='0;
        rst_ni = 1'b0; repeat (2) @(posedge clk_i); rst_ni = 1'b1; @(negedge clk_i);

        $display("--- ready is always high (no overlap rejection, no backpressure) ---");
        expect_eq(&t_set_ready, 1'b1, "dep_set_ready all high");

        $display("--- set / check / clear on a single tag ---");
        t_set(1, 4'b0010, 3'd0);                             // row1,col1 tag0
        t_peek(1, 4'b0010, 3'd0, res); expect_eq(res, 1'b1, "row1 col1 tag0 set");
        t_consume(1, 4'b0010, 3'd0);                         // drain
        t_peek(1, 4'b0010, 3'd0, res); expect_eq(res, 1'b0, "row1 col1 tag0 drained");

        $display("--- subset check across columns (same tag) ---");
        t_set(0, 4'b0001, 3'd0); t_set(2, 4'b0001, 3'd0);    // row0: col0 and col2, tag0
        t_peek(0, 4'b0101, 3'd0, res); expect_eq(res, 1'b1, "row0 {col0,col2} set");
        t_peek(0, 4'b0111, 3'd0, res); expect_eq(res, 1'b0, "row0 {col0,col1,col2} -> col1 missing");
        t_consume(0, 4'b0101, 3'd0);                         // drain for next section

        $display("--- a stray tag cannot satisfy a check for a different tag ---");
        t_set(1, 4'b0001, 3'd7);                             // row0,col1 tagged 7 (stray)
        t_peek(0, 4'b0010, 3'd2, res); expect_eq(res, 1'b0, "row0 col1 tag2 (stray tag7) -> miss");
        t_peek(0, 4'b0010, 3'd7, res); expect_eq(res, 1'b1, "row0 col1 tag7 -> hit");
        t_consume(0, 4'b0010, 3'd7);                         // drain for next section

        $display("--- two edges on the same cell are independent per tag ---");
        t_set(1, 4'b0001, 3'd1);                             // row0,col1 tag1
        t_set(1, 4'b0001, 3'd2);                             // row0,col1 tag2 (same cell)
        t_peek(0, 4'b0010, 3'd1, res); expect_eq(res, 1'b1, "tag1 present");
        t_consume(0, 4'b0010, 3'd1);                         // drain tag1 only
        t_peek(0, 4'b0010, 3'd1, res); expect_eq(res, 1'b0, "tag1 drained");
        t_peek(0, 4'b0010, 3'd2, res); expect_eq(res, 1'b1, "tag2 untouched");

        if (errors == 0) $display("All dep_matrix tests passed");
        else             $error("%0d dep_matrix test(s) FAILED", errors);
        #10 $finish;
    end

    initial begin #100000; $fatal("TIMEOUT"); end

endmodule
