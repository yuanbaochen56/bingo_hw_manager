// Core remap selector.
//
// Picks the physical core that receives a task assigned to logical core
// `req_i.core` in cluster `req_i.cluster`.
module bingo_hw_manager_core_remap #(
    parameter int unsigned NumCores = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CoreIdWidth = 2,
    parameter int unsigned ClusterIdWidth = 1,
    // Type of each (core, cluster) slot (see bingo_hw_manager_top): a core may
    // run the tasks of another core of the chiplet iff both have the same
    // non-zero type.
    parameter int unsigned CoreTypeIdWidth = 4,
    parameter logic [NumCores-1:0][NumClusters-1:0][CoreTypeIdWidth-1:0] CoreTypeId =
        {(NumCores * NumClusters){CoreTypeIdWidth'(1)}},
    // Substitute levels (see bingo_hw_manager_top SubstituteLevelMask)
    parameter logic [2:0] SubstituteLevelMask = 3'b001,
    // Port types (bingo_hw_manager/typedef.svh)
    parameter type        remap_req_t = logic,
    parameter type        remap_sel_t = logic,
    parameter type        slot_state_t = logic,
    parameter type        smt_t = logic,
    parameter type        park_t = logic
) (
    // The head: valid, its logical slot (from the task descriptor), whether it
    // runs on a core (dummy-set and CERF-skipped tasks never leave their
    // logical core), task_type 11 (may run locally, but recovery of imports is
    // not defined)
    input  remap_req_t                    req_i,
    // Slot state: fenced (watchdog), retired and stuck (replay controller),
    // rejected (level 3: the proxy slot's exports were rejected, sticky)
    input  slot_state_t                   slot_i,
    // Level 3: core types with an export target (index: CoreTypeId)
    input  logic [2**CoreTypeIdWidth-1:0] remote_type_en_i,
    // Slot mapping table (bingo_hw_manager_slot_table), indexed by logical slot,
    // and the cycle it is written
    input  smt_t                          smt_i,
    input  logic                          smt_update_i,
    // Parking (bingo_hw_manager_slot_table). HOLD or UNPARK blocks every new task;
    // PARKED sends executing tasks through the table. All stay 0 when park_req
    // is 0.
    input  park_t                         park_i,
    // The selected physical slot (valid, core, cluster); remote: level 3, the
    // selected slot is the logical one, used as a remote proxy
    output remap_sel_t                    sel_o
);
    // HOLD or UNPARK: no new task enters the slot
    logic [NumCores-1:0][NumClusters-1:0] park_block;
    assign park_block = park_i.hold | park_i.unpark;

    logic logical_in_range;
    logic logical_fenced;
    logic logical_retired;
    logic logical_stuck;
    logic logical_hold;
    logic logical_parked;
    logic                      sub_found;
    logic [CoreIdWidth-1:0]    sub_core;
    logic [ClusterIdWidth-1:0] sub_cluster;
    logic                      logical_typed;
    logic                      logical_exportable;

    assign logical_in_range = (int'(req_i.core) < NumCores) &&
                              (int'(req_i.cluster) < NumClusters);
    assign logical_fenced   = logical_in_range && slot_i.fenced[req_i.core][req_i.cluster];
    assign logical_retired  = logical_in_range && slot_i.retired[req_i.core][req_i.cluster];
    assign logical_stuck    = logical_in_range && slot_i.stuck[req_i.core][req_i.cluster];
    assign logical_hold     = logical_in_range && park_block[req_i.core][req_i.cluster];
    assign logical_parked   = logical_in_range && park_i.parked[req_i.core][req_i.cluster];
    assign logical_typed    = logical_in_range && (CoreTypeId[req_i.core][req_i.cluster] != '0);
    assign logical_exportable = logical_typed && remote_type_en_i[CoreTypeId[req_i.core][req_i.cluster]] &&
                                !slot_i.rejected[req_i.core][req_i.cluster];

    // A fenced logical core is not a candidate for its own substitute. A parked
    // one is masked out the same way, so the table does not point back at it.
    assign sub_found   = logical_in_range && smt_i.found[req_i.core][req_i.cluster];
    assign sub_core    = smt_i.core[req_i.core][req_i.cluster];
    assign sub_cluster = smt_i.cluster[req_i.core][req_i.cluster];

    always_comb begin
        sel_o.valid   = req_i.valid && logical_in_range;
        sel_o.core    = req_i.core;
        sel_o.cluster = req_i.cluster;
        sel_o.remote  = 1'b0;

        if (req_i.valid && logical_in_range && logical_fenced) begin
            if (!logical_retired) begin
                // Outstanding tasks of this core are still being replayed. A
                // stuck core only takes the tasks that never run on a core.
                sel_o.valid = logical_stuck && !req_i.remappable;
            end else if (req_i.remappable && smt_update_i) begin
                // The substitute is being recomputed (a slot was just fenced)
                sel_o.valid = 1'b0;
            end else if (req_i.remappable) begin
                sel_o.valid = sub_found;
                if (sub_found) begin
                    sel_o.core    = sub_core;
                    sel_o.cluster = sub_cluster;
                end else if (SubstituteLevelMask[2] && logical_exportable && !req_i.no_replay) begin
                    sel_o.valid  = 1'b1;
                    sel_o.remote = 1'b1;
                end
            end
        end else if (req_i.valid && logical_in_range && logical_hold && !logical_fenced) begin
            // Drain: nothing new enters this slot's checkout.
            sel_o.valid = 1'b0;
        end else if (req_i.valid && logical_in_range && logical_parked && !logical_fenced) begin
            if (req_i.remappable && smt_update_i) begin
                sel_o.valid = 1'b0;
            end else if (req_i.remappable) begin
                // Live core: no level-3 export. A missing substitute waits; the
                // control plane drops PARKED instead of leaving it that way.
                sel_o.valid = sub_found &&
                    !((sub_core == req_i.core) && (sub_cluster == req_i.cluster));
                if (sel_o.valid) begin
                    sel_o.core    = sub_core;
                    sel_o.cluster = sub_cluster;
                end
            end
        end
    end

endmodule
