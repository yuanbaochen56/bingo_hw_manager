// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// Power manager of the bingo hardware manager. bingo_hw_manager_pm_policy
// chooses the level each domain (or the chip) should run at; this module acts
// on it in one of two modes (cfg_i.dvfs):
//   0: DFS, clock only, per domain. The PM applies the level itself: it writes
//      the clock division to the on-chip clk/rst controller over its AXI-Lite
//      master.
//   1: DVFS, voltage and clock, one level for the chip. The PM only asks the
//      host to apply the level: it publishes the request on dvfs_request_o and
//      rings a doorbell, a read-modify-write of the host's dedicated bit in the
//      CLINT MSIP word that keeps the pending bits of the other harts. The host
//      ISR then sets the external PMIC (voltage) and the clk/rst controller
//      (frequency) in the safe order: to raise, voltage first; to lower,
//      frequency first.

module bingo_hw_manager_pm #(
    parameter int unsigned NUM_CLUSTERS_PER_CHIPLET = 4,
    parameter int unsigned NUM_CORES_PER_CLUSTER = 8,
    parameter int unsigned CfgBusWidth = 32,
    // Dedicated host DVFS doorbell bit inside the shared CLINT MSIP word. Injected from
    // the HeMAiA level (occamygen hw_manager_ipi_idx) so it tracks the hart count instead
    // of being hardcoded; must match HW_MANAGER_DVFS_MSIP_BIT / occamy_soc.sv ipi_i.
    parameter int unsigned HOST_DVFS_MSIP_BIT = 3,
    // Layout of the clock/reset controller's division registers (DFS):
    // 0  four 8-bit divisions per 32-bit register from 0x08 (domains 4k..4k+3 at
    //    0x08 + 4k), loaded by a bit of the valid register at 0x04. The PM writes
    //    the whole 8-byte word that holds its domain (the other seven bytes with
    //    the levels it applied before), so it shares that word with any other
    //    writer of those domains.
    // 1  besides those, one division register per domain (domain d at
    //    0x38 + 8d; nothing at 0x3c + 8d) and its own valid register at 0x34.
    //    The PM writes only its domain's register and loads it with that valid
    //    register: it never writes a byte of another domain, and the packed
    //    registers are left to the other writers (the host). Same bus sequence
    //    as 0 (an 8-byte write at an 8-byte boundary, then a write to the upper
    //    half of an 8-byte word), so the level is applied in the same cycle.
    parameter bit      DivisionPerDomain = 1'b0,
    parameter type     req_lite_t   = logic,
    parameter type     resp_lite_t  = logic,
    parameter type     addr_t       = logic,
    parameter type     data_t       = logic,
    // Port type (bingo_hw_manager/typedef.svh)
    parameter type     pm_slot_t    = logic,
    // Derived type, do not override
    parameter type     cfg_t        = logic [CfgBusWidth-1:0]
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    // The configuration from the host: enable, DFS / DVFS, the levels, the
    // DVFS acknowledge
    input  bingo_hw_manager_pkg::pm_cfg_t cfg_i,
    // Every slot: its power domain (decoded once by the top), idle (polling or
    // fenced, bingo_hw_manager_power_view, so a dead core does not keep its
    // domain at the normal level), busy only with outside accesses, boosted,
    // derated
    input  pm_slot_t    slot_i,
    // The power management base address (clock / reset controller, DFS)
    input  addr_t       pm_base_addr_i,
    // Physical address of the host's CLINT MSIP word (target of the DVFS doorbell write)
    input  addr_t       dvfs_clint_msip_addr_i,
    // DVFS request published to the host: {target_level[15:8], direction[1], pending[0]}
    output cfg_t        dvfs_request_o,
    // Level last applied to each domain by the DFS path (0: none yet)
    output logic [31:0][7:0] domain_level_o,
    // AXI Lite Master Interface to Configure PMIC
    output req_lite_t              pm_axi_lite_req_o,
    input  resp_lite_t             pm_axi_lite_resp_i,
    // Sticky bus errors of that master (SLVERR or DECERR, e.g. a wrong base
    // address): [0] a write was answered with an error, so the level it set may
    // not apply (domain_level_o still shows it); [1] the DVFS read of the CLINT
    // word was answered with an error, so the doorbell write that follows may
    // change the other bits of that word. Report only: the PM goes on as before.
    output logic [1:0]             bus_error_o
);

    // Constants
    // Notice here is tightly coupled with the PMIC design
    // So we do not make those as configurable parameters
    localparam int unsigned MAX_DOMAINS = bingo_hw_manager_pkg::PmMaxDomains;
    localparam int unsigned OFFSET_CLOCK_VALID = 32'h04;
    localparam int unsigned OFFSET_CLOCK_DIVISION_BASE = 32'h08;
    // DivisionPerDomain: the per-domain registers and their valid register
    localparam int unsigned OFFSET_DOMAIN_VALID = 32'h34;
    localparam int unsigned OFFSET_DOMAIN_DIVISION_BASE = 32'h38;
    // HOST_DVFS_MSIP_BIT is now a module parameter (injected from the HeMAiA level).
    // DVFS_REQUEST field layout (must match occamy_quad_periph DVFS_REQUEST register)
    localparam int unsigned DVFS_REQ_PENDING_BIT = 0;
    localparam int unsigned DVFS_REQ_DIR_BIT     = 1;  // 1 = raise (chip busy), 0 = lower (chip idle)
    localparam int unsigned DVFS_REQ_LEVEL_LSB   = 8;  // target power level occupies [15:8]

    // Type definition for power level (using low 8 bits of cfg_t)
    typedef logic [7:0]                     power_level_t;
    typedef logic [$clog2(MAX_DOMAINS)-1:0] domain_id_t;
    // -------------------------------------------------------------------------
    // 1. Level policy (bingo_hw_manager_pm_policy): per domain (DFS) or for the
    //    chip (DVFS), the level it should run at
    // -------------------------------------------------------------------------
    power_level_t [MAX_DOMAINS-1:0] current_power_level_q; // State tracking
    logic                           update_req_valid;
    domain_id_t                     update_domain_id;
    power_level_t                   update_domain_target_level;
    logic                           chip_busy;
    power_level_t                   desired_chip_level; // clock-division / power level the chip should be at
    logic                           dvfs_pending;       // host has not yet applied the desired level
    bingo_hw_manager_pm_policy #(
        .NumCores    ( NUM_CORES_PER_CLUSTER    ),
        .NumClusters ( NUM_CLUSTERS_PER_CHIPLET ),
        .pm_slot_t   ( pm_slot_t                )
    ) i_policy (
        .cfg_i           ( cfg_i                      ),
        .slot_i          ( slot_i                     ),
        .level_i         ( current_power_level_q      ),
        .update_valid_o  ( update_req_valid           ),
        .update_domain_o ( update_domain_id           ),
        .update_level_o  ( update_domain_target_level ),
        .chip_busy_o     ( chip_busy                  ),
        .chip_level_o    ( desired_chip_level         ),
        .dvfs_pending_o  ( dvfs_pending               )
    );
    assign domain_level_o = current_power_level_q;

    // -------------------------------------------------------------------------
    // 2. DVFS request and doorbell
    // -------------------------------------------------------------------------
    // Publish the request the host reads in its ISR. Combinational: always reflects the
    // latest desired chip state, so a mid-service transition is picked up on re-read.
    always_comb begin
        dvfs_request_o = '0;
        dvfs_request_o[DVFS_REQ_PENDING_BIT]   = dvfs_pending;
        dvfs_request_o[DVFS_REQ_DIR_BIT]       = chip_busy; // 1 = raise, 0 = lower
        dvfs_request_o[DVFS_REQ_LEVEL_LSB +: 8] = desired_chip_level;
    end

    // Doorbell bookkeeping: exactly one doorbell per (re)transition; re-ring if the desired
    // target moves while a previous notify is still outstanding (solves the re-arm race).
    logic         notify_outstanding_q;
    power_level_t sent_level_q;   // desired level for which the last doorbell was rung
    logic [31:0]  msip_word_q;    // captured CLINT MSIP word for the read-modify-write
    logic         dvfs_issue;

    assign dvfs_issue = dvfs_pending &&
                        (!notify_outstanding_q || (sent_level_q != desired_chip_level));

    // -------------------------------------------------------------------------
    // 3. AXI-Lite Protocol FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        IDLE,
        // DFS path: program the on-chip clk/rst controller directly
        WRITE_FREQ_AW,
        WRITE_FREQ_W,
        WRITE_VALID_AW,
        WRITE_VALID_W,
        // DVFS path: read-modify-write the host's dedicated CLINT MSIP doorbell bit
        READ_MSIP_AR,
        READ_MSIP_R,
        WRITE_MSIP_AW,
        WRITE_MSIP_W
    } pm_state_t;

    pm_state_t state_d, state_q;

    // Latch arbitration results when starting a transaction
    domain_id_t         active_domain_id_d, active_domain_id_q;
    power_level_t       active_target_level_d, active_target_level_q;

    // FSM Output signals
    logic bus_aw_valid, bus_w_valid;
    localparam int unsigned BUS_ADDR = $bits(addr_t);
    localparam int unsigned BUS_DATA = $bits(data_t);
    localparam int unsigned WstrbWidth = BUS_DATA / 8;
    addr_t   bus_addr;
    data_t   bus_wdata;
    logic [WstrbWidth-1:0] bus_wstrb;
    // Read channel outputs (used only by the DVFS MSIP read-modify-write path)
    logic  bus_ar_valid, bus_r_ready;
    addr_t bus_araddr;

    // 1. Sequential Logic: State and Datapath Registers
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q               <= IDLE;
            active_domain_id_q    <= '0;
            active_target_level_q <= '0;
            current_power_level_q <= '0; // Reset assumes power-on defaults (or specific val)
            notify_outstanding_q  <= 1'b0;
            sent_level_q          <= '0;
            msip_word_q           <= '0;
        end else begin
            state_q               <= state_d;
            active_domain_id_q    <= active_domain_id_d;
            active_target_level_q <= active_target_level_d;

            // DFS: update the shadow register upon successful completion of the sequence
            // Assuming completion when last W-channel handshake is done
            if (state_q == WRITE_VALID_W && pm_axi_lite_resp_i.w_ready) begin
                current_power_level_q[active_domain_id_q] <= active_target_level_q;
            end

            // DVFS: capture the CLINT MSIP word on the read handshake (for read-modify-write)
            if (state_q == READ_MSIP_R && pm_axi_lite_resp_i.r_valid) begin
                msip_word_q <= dvfs_clint_msip_addr_i[2] ? pm_axi_lite_resp_i.r.data[63:32]
                                                         : pm_axi_lite_resp_i.r.data[31:0];
            end

            // DVFS: doorbell bookkeeping. Mark a notify outstanding once the write completes;
            // clear it when the host has caught up (dvfs_pending deasserts). The dvfs_issue
            // term (sent_level_q != desired) re-rings if the target moved meanwhile.
            if (state_q == WRITE_MSIP_W && pm_axi_lite_resp_i.w_ready) begin
                notify_outstanding_q <= 1'b1;
                sent_level_q         <= desired_chip_level;
            end else if (!dvfs_pending) begin
                notify_outstanding_q <= 1'b0;
            end
        end
    end

    // 2. Next State Logic
    always_comb begin
        state_d = state_q; // Default to hold state
        case (state_q)
            IDLE: begin
                if (cfg_i.enable) begin
                    if (cfg_i.dvfs) begin
                        // DVFS: ring the host doorbell for a pending chip-level transition
                        if (dvfs_issue) state_d = READ_MSIP_AR;
                    end else begin
                        // DFS: autonomously program the clk/rst controller
                        if (update_req_valid) state_d = WRITE_FREQ_AW;
                    end
                end
            end

            WRITE_FREQ_AW: begin
                if (pm_axi_lite_req_o.aw_valid && pm_axi_lite_resp_i.aw_ready) state_d = WRITE_FREQ_W;
            end

            WRITE_FREQ_W: begin
                if (pm_axi_lite_req_o.w_valid && pm_axi_lite_resp_i.w_ready) state_d = WRITE_VALID_AW;
            end

            WRITE_VALID_AW: begin
                if (pm_axi_lite_req_o.aw_valid && pm_axi_lite_resp_i.aw_ready) state_d = WRITE_VALID_W;
            end

            WRITE_VALID_W: begin
                if (pm_axi_lite_req_o.w_valid && pm_axi_lite_resp_i.w_ready) state_d = IDLE;
            end

            READ_MSIP_AR: begin
                if (pm_axi_lite_req_o.ar_valid && pm_axi_lite_resp_i.ar_ready) state_d = READ_MSIP_R;
            end

            READ_MSIP_R: begin
                if (pm_axi_lite_req_o.r_ready && pm_axi_lite_resp_i.r_valid) state_d = WRITE_MSIP_AW;
            end

            WRITE_MSIP_AW: begin
                if (pm_axi_lite_req_o.aw_valid && pm_axi_lite_resp_i.aw_ready) state_d = WRITE_MSIP_W;
            end

            WRITE_MSIP_W: begin
                if (pm_axi_lite_req_o.w_valid && pm_axi_lite_resp_i.w_ready) state_d = IDLE;
            end

            default: state_d = IDLE;
        endcase
    end

    // The 8-byte word of division registers that holds the active domain: the
    // new level of the active domain, the applied level of the other seven
    logic [63:0] division_word;
    always_comb begin
        for (int i = 0; i < 8; i++) begin
            automatic domain_id_t d = {active_domain_id_q[$bits(domain_id_t)-1:3], 3'(i)};
            division_word[8*i +: 8] = (d == active_domain_id_q) ? active_target_level_q
                                                                 : current_power_level_q[d];
        end
    end

    // 3. Output and Datapath Logic
    always_comb begin
        // Default Datapath Next Values
        active_domain_id_d    = active_domain_id_q;
        active_target_level_d = active_target_level_q;

        // Default Bus Outputs
        bus_aw_valid = 1'b0;
        bus_w_valid  = 1'b0;
        bus_addr     = '0;
        bus_wdata    = '0;
        bus_wstrb    = '0;
        bus_ar_valid = 1'b0;
        bus_r_ready  = 1'b0;
        bus_araddr   = '0;

        case (state_q)
            IDLE: begin
                // In DFS mode latch the arbitrated domain/target for the clk/rst write.
                // In DVFS mode nothing is latched here (the request is combinational).
                if (!cfg_i.dvfs && update_req_valid) begin
                    active_domain_id_d    = update_domain_id;
                    active_target_level_d = update_domain_target_level;
                end
            end

            WRITE_FREQ_AW: begin
                // The division registers hold the 8-bit levels of four domains each:
                // 0x08 domains 0-3, 0x0c domains 4-7, and so on. The PM writes the
                // whole 8-byte word that holds the active domain (domains 8k .. 8k+7
                // at 0x08 + 8k). The clock/reset controller takes only full 32-bit
                // writes: a 64-bit write with half of its strobes reaches it through
                // the 64- to 32-bit converter as a second write without strobes,
                // which it answers with SLVERR.
                // DivisionPerDomain: the 8-byte word of the active domain's own
                // register (0x38 + 8d), whose upper half holds no register.
                if (DivisionPerDomain) begin
                    bus_addr = pm_base_addr_i + OFFSET_DOMAIN_DIVISION_BASE + (addr_t'(active_domain_id_q) << 3);
                end else begin
                    bus_addr = pm_base_addr_i + OFFSET_CLOCK_DIVISION_BASE + ((active_domain_id_q >> 3) << 3);
                end
                bus_aw_valid = 1'b1;
            end

            WRITE_FREQ_W: begin
                // The other seven domains of the word keep the level the PM last
                // applied to them (0: none yet); the controller loads a domain's
                // level only with its valid bit (WRITE_VALID_*).
                // DivisionPerDomain: the level alone, in the register of the domain.
                if (DivisionPerDomain) begin
                    bus_wdata = data_t'(active_target_level_q);
                end else begin
                    bus_wdata = division_word;
                end
                bus_wstrb = 8'hff;
                bus_w_valid  = 1'b1;
            end

            WRITE_VALID_AW: begin
                bus_addr = pm_base_addr_i + (DivisionPerDomain ? OFFSET_DOMAIN_VALID : OFFSET_CLOCK_VALID);
                bus_aw_valid = 1'b1;
            end

            WRITE_VALID_W: begin
                // Replicate 32-bit data
                bus_wdata = {2{32'(1'b1) << active_domain_id_q}};
                // Valid register is at Offset 0x04 (Upper 32 bits; DivisionPerDomain: 0x34)
                // We are actully writes to the 0x00 to 0x08 range with the 64bit bus
                // So the valid bits are always in the upper 32 bits
                bus_wstrb = 8'hf0;
                bus_w_valid  = 1'b1;
            end

            // DVFS doorbell: read-modify-write the shared CLINT MSIP word so we set the
            // host's dedicated bit without clobbering the other harts' pending bits.
            READ_MSIP_AR: begin
                bus_araddr   = dvfs_clint_msip_addr_i;
                bus_ar_valid = 1'b1;
            end

            READ_MSIP_R: begin
                bus_r_ready = 1'b1;
            end

            WRITE_MSIP_AW: begin
                bus_addr     = dvfs_clint_msip_addr_i;
                bus_aw_valid = 1'b1;
            end

            WRITE_MSIP_W: begin
                // Set only the host DVFS doorbell bit; preserve the rest of the read word.
                // Replicate to both 64-bit halves and pick the strobe from address bit 2
                // (the MSIP word is 32-bit within the 64-bit AXI-Lite data bus).
                bus_wdata = {2{msip_word_q | (32'h1 << HOST_DVFS_MSIP_BIT)}};
                if (dvfs_clint_msip_addr_i[2]) begin
                    bus_wstrb = 8'hf0; // Upper 32 bits
                end else begin
                    bus_wstrb = 8'h0f; // Lower 32 bits
                end
                bus_w_valid = 1'b1;
            end

            default: begin
                // Should not occur
                active_domain_id_d    = '0;
                active_target_level_d = '0;
                bus_aw_valid          = 1'b0;
                bus_w_valid           = 1'b0;
                bus_addr              = 'hbaadf00d;
                bus_wdata             = '0;
                bus_wstrb             = '0;
            end
        endcase
    end

    // Map internal bus signals to output struct
    always_comb begin
        pm_axi_lite_req_o = '0;

        pm_axi_lite_req_o.aw.addr  = bus_addr;
        pm_axi_lite_req_o.aw.prot  = 3'b000;
        pm_axi_lite_req_o.aw_valid = bus_aw_valid;

        pm_axi_lite_req_o.w.data   = bus_wdata;
        pm_axi_lite_req_o.w.strb   = bus_wstrb;
        pm_axi_lite_req_o.w_valid  = bus_w_valid;

        pm_axi_lite_req_o.b_ready  = 1'b1;

        // Read channel (driven only during the DVFS MSIP read-modify-write)
        pm_axi_lite_req_o.ar.addr  = bus_araddr;
        pm_axi_lite_req_o.ar.prot  = 3'b000;
        pm_axi_lite_req_o.ar_valid = bus_ar_valid;
        pm_axi_lite_req_o.r_ready  = bus_r_ready;
    end

    logic [1:0] bus_error_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            bus_error_q <= '0;
        end else begin
            if (pm_axi_lite_resp_i.b_valid && pm_axi_lite_resp_i.b.resp[1])
                bus_error_q[0] <= 1'b1;
            if ((state_q == READ_MSIP_R) && pm_axi_lite_resp_i.r_valid && pm_axi_lite_resp_i.r.resp[1])
                bus_error_q[1] <= 1'b1;
        end
    end
    assign bus_error_o = bus_error_q;

    // -------------------------------------------------------------------------
    // DVFS voltage-safety assertion
    // -------------------------------------------------------------------------
    // Safety property: in DVFS mode the PM must NEVER autonomously drive the on-chip
    // clk/rst controller. Frequency there must be coordinated with the external PMIC
    // voltage by the host ISR (raise: V then F; lower: F then V), so if the PM changed
    // frequency on its own it could run the clock fast at low Vdd -> setup-timing
    // failure on silicon. In DVFS mode the PM may only ring the host doorbell via the
    // READ_MSIP_*/WRITE_MSIP_* states; it must stay out of the WRITE_FREQ_*/WRITE_VALID_*
    // (clk/rst-write) states. This catches a future FSM refactor that breaks the mode
    // gating. The V/F ordering contract itself is enforced in software (host has no
    // voltage feedback in RTL)
    // synopsys translate_off
`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        cfg_i.dvfs |-> !(state_q inside {WRITE_FREQ_AW, WRITE_FREQ_W,
                                           WRITE_VALID_AW, WRITE_VALID_W}))
    else $error("bingo_hw_manager_pm: entered a clk/rst-write state in DVFS mode ",
                "(the host, not the PM, must scale frequency under voltage coordination)");
`endif
    // synopsys translate_on

`ifndef SYNTHESIS
    // Simulation-only log: every domain level the DFS path applies, every DVFS doorbell
    always @(posedge clk_i) begin : pm_event_log
        if (rst_ni) begin
            if ((state_q == WRITE_VALID_W) && pm_axi_lite_req_o.w_valid && pm_axi_lite_resp_i.w_ready) begin
                $display("[BINGO_PM] %0t domain=%0d level=%0d", $time, active_domain_id_q, active_target_level_q);
            end
            if ((state_q == WRITE_MSIP_W) && pm_axi_lite_req_o.w_valid && pm_axi_lite_resp_i.w_ready) begin
                $display("[BINGO_PM] %0t dvfs_doorbell level=%0d busy=%0b", $time, desired_chip_level, chip_busy);
            end
            if (pm_axi_lite_resp_i.b_valid && pm_axi_lite_resp_i.b.resp[1])
                $display("[BINGO_BUS_ERROR] %0t PM write answered with resp %0d", $time, pm_axi_lite_resp_i.b.resp);
            if ((state_q == READ_MSIP_R) && pm_axi_lite_resp_i.r_valid && pm_axi_lite_resp_i.r.resp[1])
                $display("[BINGO_BUS_ERROR] %0t PM read of the CLINT word answered with resp %0d", $time,
                         pm_axi_lite_resp_i.r.resp);
        end
    end
`endif

endmodule