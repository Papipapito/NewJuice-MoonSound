// ============================================================================
// nj_v9990_arb.v - SDRAM arbiter of the New Juice V9990 fork.
// Copyright (c) 2026 Albert "Papipapito", with Claude. BSD-3-Clause.
//
// Three clients share New Juice's controller (sdram.v, CL3, 108 MHz):
//   A  New Juice's sdram_command_adapter (CPU accesses and the Z80-paced
//      refreshes). Its command wires go straight to the controller; this
//      module only tells it when it may issue (a_busy).
//   V  the VRAM port of the tiny9990 (RAM_* of T9990), through the V port of
//      sdram.v. It has a deadline: the core gets a slot every 20 clocks
//      (v_timing) and its access must be over before the next one.
//   R  a refresh timer of its own, as in the MoonSound fork: New Juice only
//      refreshes after Z80 RFSH cycles.
//
// It also makes the tiny9990's clock enables and its slot pulse, copied from
// tnCart's UMA (DIV = 30): 21.6, 14.4 and 25.2 MHz enables and one slot pulse
// every 20 clocks, two clocks after an enable.
//
// Timing of a slot (ph = clocks since v_timing was 1):
//   ph 0   v_timing
//   ph 1   the core's EXEC
//   ph 2   the core's request is visible here (RAM_OE_n / RAM_WE_n / RAM_RFSH_n)
// Rules:
//  - a_busy is 1 from the clock the request is visible, so A issues nothing
//    new after it. A may still issue in that very clock (it decided one clock
//    earlier): then V waits for that one operation. V's access itself is
//    issued in the first clock with the controller idle and no A command.
//  - Worst case for V: A writes at ph 2 (controller idle again at ph 10), V
//    reads two words from ph 10, RAM_DOUT and RAM_ACK_n at ph 19, the core is
//    back in its idle state at ph 20 = ph 0 of the next slot, one clock
//    before its EXEC.
//  - Worst case for A: one V access, 7 to 9 clocks.
//  - R only starts with ph in 3..14, so that it is over before the next
//    request of V, never with a request of V pending, and (unless overdue)
//    never while a CPU read is announced by the slot pins.
//  - RAM_RFSH_n of the core is acknowledged without touching the SDRAM: R
//    already refreshes it.
//  - Reads of V are captured by the adapter's own read register (aux_capture,
//    see sdram_command_adapter.v); rd_q is that register, one clock later.
//
// VRAM: 512 KB at SDRAM byte 0x780000 (word 0x1E0000).
// ============================================================================
`default_nettype none

module nj_v9990_arb #(
    parameter integer REFRESH_CYCLES = 842,   // 7.8 us at 108 MHz without any refresh
    parameter integer URGENT_CYCLES  = 1350,  // 12.5 us: R no longer waits for a CPU read
    parameter         CPU_HINT       = 1,
    parameter integer HINT_MAX       = 40
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- client A: command pulses of the adapter (watched, not routed) ----
    input  wire        a_rd,
    input  wire        a_wr,
    input  wire        a_refresh,
    output wire        a_busy,
    input  wire        cpu_sltsl_n,      // raw slot pins (asynchronous)
    input  wire        cpu_rd_n,

    // ---- client V: tiny9990 ----
    input  wire        v_en,             // 0 = the SDRAM is not ready for V
    output reg         v_timing,         // RAM_REQ
    output reg         clk21m_en,
    output reg         clk14m_en,
    output reg         clk25m_en,
    input  wire        v_oe_n,
    input  wire        v_we_n,
    input  wire        v_rfsh_n,
    input  wire [18:0] v_addr,           // VRAM byte address
    input  wire [31:0] v_din,
    input  wire [2:0]  v_din_size,
    output reg  [31:0] v_dout,
    output reg         v_ack_n,

    // ---- controller (sdram.v) ----
    output wire        s_refresh,        // a_refresh or this module's own
    output wire        s_v_rd,
    output wire        s_v_wr,
    output wire        s_v_dbl,
    output wire [20:0] s_v_addr,
    output wire [31:0] s_v_din0,
    output wire [3:0]  s_v_dqm0,
    output wire [31:0] s_v_din1,
    output wire [3:0]  s_v_dqm1,
    input  wire        s_busy,
    input  wire        s_v_data_ready,

    // ---- shared read capture (the adapter's read_data register) ----
    output wire        aux_capture,
    input  wire [31:0] rd_q,

    // ---- status ----
    output wire        own_refresh
);
    localparam [2:0] SZ_8 = 3'b000, SZ_16 = 3'b001, SZ_32 = 3'b010,
                     SZ_32_E = 3'b011, SZ_32_O = 3'b111;

    // ------------------------------------------------------------------
    //  Clock enables and slot pulse (tnCart UMA, DIV = 30, free running)
    // ------------------------------------------------------------------
    reg [4:0] mem_cnt;
    reg       slot_tog;
    reg [4:0] ph;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_cnt <= 5'd0; slot_tog <= 1'b0; ph <= 5'd31;
            v_timing <= 1'b0; clk21m_en <= 1'b0; clk14m_en <= 1'b0; clk25m_en <= 1'b0;
        end else begin
            mem_cnt <= (mem_cnt == 5'd29) ? 5'd0 : mem_cnt + 5'd1;

            clk25m_en <= (mem_cnt == 5'd0)  || (mem_cnt == 5'd4)  || (mem_cnt == 5'd8)  ||
                         (mem_cnt == 5'd12) || (mem_cnt == 5'd17) || (mem_cnt == 5'd21) ||
                         (mem_cnt == 5'd25);
            clk21m_en <= (mem_cnt == 5'd0)  || (mem_cnt == 5'd5)  || (mem_cnt == 5'd10) ||
                         (mem_cnt == 5'd15) || (mem_cnt == 5'd20) || (mem_cnt == 5'd25);
            clk14m_en <= (mem_cnt == 5'd0)  || (mem_cnt == 5'd7)  || (mem_cnt == 5'd15) ||
                         (mem_cnt == 5'd22);

            // every 10 clocks, every other one is the V9990's
            v_timing <= 1'b0;
            if (mem_cnt == 5'd2 || mem_cnt == 5'd12 || mem_cnt == 5'd22) begin
                v_timing <= slot_tog;
                slot_tog <= ~slot_tog;
            end

            if (v_timing)            ph <= 5'd1;
            else if (ph != 5'd31)    ph <= ph + 5'd1;
        end
    end

    // ------------------------------------------------------------------
    //  CPU read hint (as in the MoonSound fork's arbiter)
    // ------------------------------------------------------------------
    (* syn_preserve = 1, ASYNC_REG = "TRUE" *)
    reg [1:0] hint_sync = 2'b00;
    reg       hint_served;
    reg [5:0] hint_age;
    wire      hint = hint_sync[1];
    wire      cpu_block = (CPU_HINT != 0) && hint && !hint_served &&
                          (hint_age < HINT_MAX[5:0]);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hint_sync <= 2'b00; hint_served <= 1'b0; hint_age <= 6'd0;
        end else begin
            hint_sync <= {hint_sync[0], !cpu_sltsl_n && !cpu_rd_n};
            if (!hint) begin
                hint_served <= 1'b0;
                hint_age <= 6'd0;
            end else begin
                if (a_rd | a_wr) hint_served <= 1'b1;
                if (hint_age != 6'h3F) hint_age <= hint_age + 6'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    //  V and R
    // ------------------------------------------------------------------
    localparam [1:0] V_IDLE = 2'd0, V_READ = 2'd1, V_ACK = 2'd2;
    reg [1:0]  vst;
    reg        v_second;
    reg        vr_q;
    reg [31:0] w0;

    wire a_cmd    = a_rd | a_wr | a_refresh;
    wire v_rw_req = v_en && (vst == V_IDLE) && (!v_oe_n || !v_we_n);
    wire v_rf_req = v_en && (vst == V_IDLE) && !v_rfsh_n && v_oe_n && v_we_n;
    wire v_dbl    = (v_din_size == SZ_32_E) || (v_din_size == SZ_32_O);
    wire v_take   = v_rw_req && !s_busy && !a_cmd;

    reg [10:0] r_cnt;
    reg        rf_hold;
    wire       r_need   = (r_cnt >= REFRESH_CYCLES[10:0]);
    wire       r_urgent = (r_cnt >= URGENT_CYCLES[10:0]);
    wire       r_window = (ph >= 5'd3) && (ph <= 5'd14);
    wire       rf_issue = rf_hold && !s_busy && !a_cmd && !v_rw_req && r_window;

    assign s_v_rd    = v_take && v_we_n;
    assign s_v_wr    = v_take && !v_we_n;
    assign s_v_dbl   = v_dbl;
    assign s_v_addr  = {4'b1111, v_addr[18:2]};
    assign s_refresh = a_refresh | rf_issue;
    assign own_refresh = rf_issue;
    assign aux_capture = s_v_data_ready;

    // write data and masks, as tnCart's sdram.sv
    wire [31:0] din_eo0 = {v_din[15:8],  v_din[15:8],  v_din[7:0],   v_din[7:0]};
    wire [31:0] din_eo1 = {v_din[31:24], v_din[31:24], v_din[23:16], v_din[23:16]};
    assign s_v_din0 = v_dbl ? din_eo0 :
                      (v_din_size == SZ_16) ? {v_din[15:0], v_din[15:0]} :
                      (v_din_size == SZ_32) ? v_din : {4{v_din[7:0]}};
    assign s_v_din1 = din_eo1;
    assign s_v_dqm0 = (v_din_size == SZ_32_E) ? 4'b1010 :
                      (v_din_size == SZ_32_O) ? 4'b0101 :
                      (v_din_size == SZ_32)   ? 4'b0000 :
                      (v_din_size == SZ_16)   ? (v_addr[1] ? 4'b0011 : 4'b1100) :
                      (v_addr[1:0] == 2'd0)   ? 4'b1110 :
                      (v_addr[1:0] == 2'd1)   ? 4'b1101 :
                      (v_addr[1:0] == 2'd2)   ? 4'b1011 : 4'b0111;
    assign s_v_dqm1 = (v_din_size == SZ_32_E) ? 4'b1010 : 4'b0101;

    // read data, as tnCart's sdram.sv
    wire [15:0] rd_even = {rd_q[23:16], rd_q[7:0]};
    wire [15:0] rd_odd  = {rd_q[31:24], rd_q[15:8]};
    wire [15:0] w0_even = {w0[23:16], w0[7:0]};
    wire [15:0] w0_odd  = {w0[31:24], w0[15:8]};
    wire [31:0] rd_plain = (v_addr[1:0] == 2'd0) ? rd_q :
                           (v_addr[1:0] == 2'd1) ? {8'h00, rd_q[31:8]} :
                           (v_addr[1:0] == 2'd2) ? {16'h0000, rd_q[31:16]} :
                                                   {24'h000000, rd_q[31:24]};

    assign a_busy = s_busy | v_rw_req | rf_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vst <= V_IDLE; v_second <= 1'b0; vr_q <= 1'b0; w0 <= 32'd0;
            v_dout <= 32'd0; v_ack_n <= 1'b1;
            r_cnt <= 11'd0; rf_hold <= 1'b0;
        end else begin
            vr_q <= s_v_data_ready;

            // refresh age: any refresh restarts it
            if (a_refresh || rf_issue)
                r_cnt <= 11'd0;
            else if (r_cnt != 11'h7FF)
                r_cnt <= r_cnt + 11'd1;

            // R: one clock of a_busy (rf_hold) before the command
            if (rf_hold)
                rf_hold <= 1'b0;
            else if (r_need && !s_busy && !a_cmd && (vst == V_IDLE) && !v_rw_req &&
                     (ph >= 5'd2) && (ph <= 5'd13) && (!cpu_block || r_urgent))
                rf_hold <= 1'b1;

            // V
            case (vst)
                V_IDLE: begin
                    if (v_take) begin
                        v_ack_n  <= 1'b0;
                        v_second <= 1'b0;
                        vst      <= v_we_n ? V_READ : V_ACK;
                    end else if (v_rf_req) begin
                        v_ack_n  <= 1'b0;
                        vst      <= V_ACK;
                    end
                end
                V_READ: if (vr_q) begin
                    if (v_dbl && !v_second) begin
                        w0       <= rd_q;
                        v_second <= 1'b1;
                    end else begin
                        v_dout <= (v_din_size == SZ_32_E) ? {rd_even, w0_even} :
                                  (v_din_size == SZ_32_O) ? {rd_odd,  w0_odd} : rd_plain;
                        v_ack_n <= 1'b1;
                        vst     <= V_IDLE;
                    end
                end
                V_ACK: begin
                    // a write or a refresh request: the core only needs to see
                    // RAM_ACK_n low for a clock
                    v_ack_n <= 1'b1;
                    vst     <= V_IDLE;
                end
                default: vst <= V_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
