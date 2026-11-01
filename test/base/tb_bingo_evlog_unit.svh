logic clk = 0, rst = 0, enable = 0, move = 0;
always #5 clk = ~clk;
logic [31:0] clear = 0, pop = 0, count;
logic [23:0] events = 0;
logic [23:0][15:0] args = '0;
logic [7:0] code = 4, slot = 0;
logic [15:0] arg = 0, dropped;
logic [63:0] head;
bingo_hw_manager_evlog #(
    .NumCores(2), .NumClusters(1), .NumTypes(2), .Depth(16), .AgeWidth(AgeWidth)
) dut (
    .clk_i(clk), .rst_ni(rst), .enable_i(enable), .clear_i(clear), .pop_i(pop),
    .event_i(events), .arg_i(args), .move_i(move), .move_code_i(code),
    .move_slot_i(slot), .move_arg_i(arg),
    .head_o(head), .count_o(count), .dropped_o(dropped)
);
task automatic tick;
    @(posedge clk); #1; @(negedge clk);
endtask
task automatic reset_log;
    events = 0; move = 0; clear++; tick();
    if (count != 0 || dropped != 0) $fatal(1, "clear did not empty logger");
endtask
task automatic check_head(input logic [31:0] ts, input logic [7:0] ec, es,
                          input logic [15:0] ea);
    if (count == 0 || head !== {ts, ec, es, ea})
        $fatal(1, "head %h expected %h count=%0d", head, {ts, ec, es, ea}, count);
    pop++; tick();
endtask
logic [31:0] arrival;
initial begin
    repeat (3) tick(); rst = 1;
    move = 1; events[4] = 1; repeat (3) tick();
    if (count || dropped) $fatal(1, "disabled logger recorded an event");
    move = 0; events = 0; enable = 1;
    arrival = dut.timestamp_q;
    events[4] = 1; args[4] = 2; // FENCE slot 0, type threshold
    events[6] = 1;             // STUCK
    events[8] = 1;             // BLOCKED
    events[10] = 1;            // RISK
    events[18] = 1; args[18] = 16'h23; // CERF clear 3 / set 1
    move = 1; code = 13; arg = 16'h1007;
    tick(); events = 0; move = 0;
    repeat (5) tick();
    check_head(arrival, 13, 0, 16'h1007);
    check_head(arrival, 3, 0, 2);
    check_head(arrival, 10, 0, 16'h23);
    // AgeWidth=2 flags saturation beginning at age 3.
    check_head(arrival, AgeWidth == 2 ? 8'h85 : 8'h05, 0, 0);
    check_head(AgeWidth == 2 ? arrival + 1 : arrival,
               AgeWidth == 2 ? 8'h86 : 8'h06, 0, 0);
    check_head(AgeWidth == 2 ? arrival + 2 : arrival,
               AgeWidth == 2 ? 8'h87 : 8'h07, 0, 0);
    if (count || dropped) $fatal(1, "priority sequence did not drain");
    // Same code, lower flat slot first; exact event-edge timestamp.
    arrival = dut.timestamp_q; events[5:4] = 2'b11; args[5] = 1;
    tick(); events = 0; tick();
    check_head(arrival, 3, 0, 2); check_head(arrival, 3, 1, 1);
    // Values held steady do not repeatedly clear or pop.
    arrival = dut.timestamp_q; move = 1; code = 4; arg = 100;
    tick(); move = 0; repeat (3) tick();
    if (count != 1) $fatal(1, "held clear/pop retriggered");
    enable = 0; repeat (3) tick();
    check_head(arrival, 4, 0, 100);
    enable = 1; reset_log();
    // Keep earliest FIFO contents. New entries are dropped when full.
    arrival = dut.timestamp_q; move = 1;
    for (int i = 0; i < 16; i++) begin arg = 16'(100 + i); tick(); end
    arg = 999; tick(); move = 0;
    if (count != 16 || dropped != 1) $fatal(1, "full FIFO count/drop incorrect");
    for (int i = 0; i < 16; i++) check_head(arrival + i, 4, 0, 16'(100 + i));
    reset_log();
    // Pending collision counts a drop; a run of MOVE steps ages RISK.
    arrival = dut.timestamp_q; events[10] = 1; move = 1; arg = 5;
    tick(); tick(); events = 0;
    repeat (3) tick(); move = 0; tick();
    if (dropped != 1) $fatal(1, "pending collision not counted");
    repeat (5) begin pop++; tick(); end
    check_head(AgeWidth == 2 ? arrival + 2 : arrival,
               AgeWidth == 2 ? 8'h87 : 8'h07, 0, 0);
    reset_log();
    // CLEAR preserves the free-running timestamp and clears pending state.
    arrival = dut.timestamp_q;
    if (arrival == 0) $fatal(1, "clear reset timestamp");
    move = 1; events[10] = 1; tick(); reset_log(); repeat (5) tick();
    if (count || dropped) $fatal(1, "clear retained pending event");
    // Saturating dropped counter (one new MOVE discarded per full edge).
    move = 1; repeat (16) tick(); repeat (65540) tick();
    if (dropped != 65535) $fatal(1, "dropped counter wrapped");
    reset_log();
    $display("Event log unit AgeWidth=%0d passed", AgeWidth);
    $finish;
end
