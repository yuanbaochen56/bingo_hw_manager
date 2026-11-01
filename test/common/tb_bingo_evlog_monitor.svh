// Independent source scoreboard. Enabled only for directed logger checks.
logic [63:0] expected[$];
logic [8:0][NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] old = '0;
logic [31:0] cycle = '0;
logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0][1:0] fence_reason = '0;
int checked = 0;
int exec_moves = 0, noexec_moves = 0, bounces = 0;

task automatic expect_event(input logic [7:0] code, slot, input logic [15:0] arg);
    expected.push_back({cycle, code, slot, arg});
endtask

always @(posedge clk_i) begin
    if (!rst_ni) begin
        cycle = 0;
        old = '0;
        fence_reason = '0;
        expected.delete();
    end else begin
        if ($test$plusargs("EVLOG_CHECK")) begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    automatic logic [7:0] slot = {4'(cl), 4'(c)};
                    if (i_dut.core_dead_suspect[c][cl] && !old[0][c][cl] && !i_dut.core_fenced[c][cl])
                        expect_event(1, slot, 0);
                    if (!i_dut.core_dead_suspect[c][cl] && old[0][c][cl] && !i_dut.core_fenced[c][cl])
                        expect_event(2, slot, 0);
                    if (i_dut.core_fenced[c][cl] && !old[2][c][cl])
                        expect_event(3, slot, 16'(fence_reason[c][cl]));
                    if (i_dut.replay_stuck_slot[c][cl] && !old[3][c][cl]) expect_event(5, slot, 0);
                    if (i_dut.replay_blocked_o[c][cl] && !old[4][c][cl]) expect_event(6, slot, 0);
                    if (i_dut.ctrl_view.risk[c][cl] && !old[5][c][cl]) expect_event(7, slot, 0);
                    if (i_dut.park.parked[c][cl] && !old[6][c][cl]) expect_event(8, slot, 0);
                    if (i_dut.park.fail[c][cl] && !old[7][c][cl]) expect_event(9, slot, 0);
                    if (i_dut.core_retired[c][cl] && !old[8][c][cl]) expect_event(11, slot, 0);
                    fence_reason[c][cl] = (i_dut.ctrl_view.risk[c][cl] && i_dut.wd_bound.risk_valid[c][cl] &&
                        risk_confirm[chiplet_idx] != 0) ? 1 :
                        ((i_dut.wd_bound.confirm[c][cl] != 0) ? 2 : 0);
                end
            end
            if (i_dut.cerf_fb_done && i_dut.cerf_fb.req)
                expect_event(10, 8'(i_dut.cerf_fb.core_type),
                    {6'b0, i_dut.cerf_fb.set, i_dut.cerf_fb.clear});
            if (i_dut.replay_step.fire && !i_dut.replay_step.bounce) begin
                automatic logic [7:0] code = i_dut.replay_data.task_type == 1 ? 13 : 4;
                expect_event(code, {4'(i_dut.replay_src_cluster), 4'(i_dut.replay_src_core)},
                    {(i_dut.replay_rotate ? 4'hf :
                      4'(i_dut.replay_step.dst_core + i_dut.replay_step.dst_cluster * NUM_CORES_PER_CLUSTER)),
                     12'(i_dut.replay_data.task_id)});
                if (code == 4) exec_moves++; else noexec_moves++;
            end
            if (i_dut.replay_step.bounce) begin
                expect_event(14, {4'(i_dut.replay_src_cluster), 4'(i_dut.replay_src_core)},
                    {4'b0, 12'(i_dut.replay_data.task_id)});
                bounces++;
            end
            if (i_dut.gen_evlog.i_evlog.write_fire) begin
                automatic logic [63:0] actual = i_dut.gen_evlog.i_evlog.write_data;
                automatic int found = -1;
                foreach (expected[k]) if (expected[k] === actual && found < 0) found = k;
                if (found < 0) $fatal(1, "[EVLOG_CHECK] unexpected item %h at cycle %0d", actual, cycle);
                expected.delete(found);
                checked++;
                $display("[EVLOG_TB] %0t chip=%0d ts=%0d code=0x%02h slot=0x%02h arg=0x%04h",
                    $time, chiplet_idx, actual[63:32], actual[31:24], actual[23:16], actual[15:0]);
            end
            if (evlog_dropped[chiplet_idx] != 0) $fatal(1, "[EVLOG_CHECK] dropped events");
        end
        old[0] = i_dut.core_dead_suspect;
        old[2] = i_dut.core_fenced;
        old[3] = i_dut.replay_stuck_slot;
        old[4] = i_dut.replay_blocked_o;
        old[5] = i_dut.ctrl_view.risk;
        old[6] = i_dut.park.parked;
        old[7] = i_dut.park.fail;
        old[8] = i_dut.core_retired;
        cycle++;
    end
end
final if ($test$plusargs("EVLOG_CHECK"))
    $display("[EVLOG_CHECK_SUMMARY] chip=%0d checked=%0d exec=%0d noexec=%0d bounce=%0d pending=%0d",
             chiplet_idx, checked, exec_moves, noexec_moves, bounces, expected.size());
