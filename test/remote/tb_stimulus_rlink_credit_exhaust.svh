// =============================================================================
// Level 3 over the real transport: credit exhaustion
// =============================================================================
// The remote_full_queue scenario (12 exports in order) with one credit.
// EXPECTED: as remote_full_queue; in addition the exports wait for a credit,
// never more than one task is outstanding, and all credits come back.
`include "tb_stimulus_remote_full_queue.svh"

final begin
    if (remote_credit_stall[0] == 0) $error("[CREDIT] exports never waited for a credit");
    if (remote_max_outstanding[0] > 1) $error("[CREDIT] %0d exports outstanding with one credit", remote_max_outstanding[0]);
    if (remote_done_in_count[0] != 12) $error("[CREDIT] %0d dones back, expected 12", remote_done_in_count[0]);
    if (gen_rlink.gen_node[0].credits != 1) $error("[CREDIT] credit not returned at the end");
    $display("[CREDIT] export waited %0d cycles for a credit", remote_credit_stall[0]);
end
