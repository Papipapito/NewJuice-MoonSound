// ============================================================================
// nj_sdram_arb.v - SDRAM arbiter for the New Juice MoonSound fork.
// Copyright (c) 2026 Albert "Papipapito", with Claude. GPL-3.0 (see NOTICE.md).
//
// Sits between New Juice's sdram_command_adapter (client A: CPU accesses and
// the Z80-paced refreshes) and its nand2mario controller (sdram.v), and adds:
//   W  the MoonSound wave memory port of wave_sdram.v (PCM engine + YRW801
//      loader), byte addressed, 4-phase handshake (wv_req level, wv_done pulse);
//   R  a refresh timer of its own. New Juice only refreshes after Z80 RFSH
//      cycles; if the Z80 stops (held /RESET, /WAIT from another cartridge)
//      nothing would refresh the SDRAM and the YRW801 copy would decay.
//
// Rules (all in clk = main_clk, 108 MHz):
//  - A is never refused: the adapter only issues a command after seeing
//    busy = 0, and while busy = 0 the controller is idle and this arbiter will
//    not issue anything in the same cycle.
//  - W and R first raise A's busy for a full cycle (HOLD) and only then issue,
//    with the controller idle and no A command in that cycle. So A and W/R
//    never collide on the controller pins.
//  - After every W/R operation busy drops for one cycle (GAP): a queued A
//    command always gets in before the next W/R. A waits at most one W/R op.
//  - Priority between W and R: W, unless the refresh is overdue (URGENT).
//  - data_ready reaches A only for A's own reads.
//  - CPU first (CPU_HINT = 1): New Juice serves the Z80 without /WAIT, so a
//    read must not queue behind a wave operation. /SLTSL and /RD straight
//    from the pins (two-flop synchronized) announce a memory read of this
//    cartridge some 8-13 clocks before New Juice's debounced bus issues its
//    command; from then on no new W/R operation starts until A has issued
//    that read (or after HINT_MAX clocks, if no SDRAM read follows). Any W
//    operation already running ends before A's command arrives.
//
// Wave address map (wave byte address b, 4 MB OPL4 space -> SDRAM bytes):
//   b 0x000000-0x1FFFFF (YRW801 ROM)  -> 0x200000-0x3FFFFF
//   b 0x200000-0x2FFFFF (1 MB RAM)    -> 0x700000-0x7FFFFF
//   b 0x300000-0x3FFFFF               -> nothing: reads FFh, writes dropped
//                                        (no mirror: size detection sees 1 MB)
//   Writes to the ROM area are only accepted while rom_write_en = 1 (the
//   loader phase); afterwards the ROM is read-only, as on a real OPL4.
// ============================================================================
`default_nettype none

module nj_sdram_arb #(
    parameter integer REFRESH_CYCLES = 842,   // 7.8 us at 108 MHz without any refresh
    parameter integer URGENT_CYCLES  = 1350,  // 12.5 us: R goes before W
    parameter         CPU_HINT       = 1,     // 1 = hold W/R back while a CPU read starts
    parameter integer HINT_MAX       = 40     // clocks the hint may hold them back
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- client A: New Juice sdram_command_adapter ----
    input  wire        a_rd,
    input  wire        a_wr,
    input  wire        a_refresh,
    input  wire [22:0] a_addr,
    input  wire [15:0] a_din,
    input  wire [1:0]  a_wdm,
    output wire        a_busy,
    output wire        a_data_ready,
    input  wire        cpu_sltsl_n,      // raw slot pins (asynchronous)
    input  wire        cpu_rd_n,

    // ---- client W: wave_sdram (byte address, 16-bit word back) ----
    input  wire        wv_req,
    input  wire        wv_we,
    input  wire [21:0] wv_addr,
    input  wire [7:0]  wv_wdata,
    output reg  [15:0] wv_dout,
    output reg         wv_done,
    input  wire        rom_write_en,     // 1 = loader phase (ROM area writable)

    // ---- controller (sdram.v) ----
    output wire        s_rd,
    output wire        s_wr,
    output wire        s_refresh,
    output wire [22:0] s_addr,
    output wire [15:0] s_din,
    output wire [1:0]  s_wdm,
    input  wire [31:0] s_dout32,
    input  wire        s_data_ready,
    input  wire        s_busy,

    // ---- status ----
    output wire        own_refresh       // pulse: this arbiter issued a refresh
);

    // ------------------------------------------------------------------
    //  W request capture and address translation
    // ------------------------------------------------------------------
    localparam [1:0] W_IDLE = 2'd0, W_HAVE = 2'd1, W_BUSY = 2'd2, W_LOW = 2'd3;
    reg [1:0]  wst;
    reg        w_we;
    reg        w_half;
    reg [22:0] w_addr;            // controller halfword address
    reg [15:0] w_din;
    reg [1:0]  w_wdm;

    wire       b_rom    = (wv_addr[21] == 1'b0);
    wire       b_ram    = (wv_addr[21:20] == 2'b10);
    wire       b_mapped = b_rom | b_ram;
    wire       b_drop   = !b_mapped || (wv_we && b_rom && !rom_write_en);
    wire [22:0] b_half_addr = b_rom ? {3'b001, wv_addr[20:1]}       // 0x100000 + b/2
                                    : {4'b0111, wv_addr[19:1]};     // 0x380000 + b/2

    // ------------------------------------------------------------------
    //  Refresh timer: cycles since the last refresh of ANY source
    // ------------------------------------------------------------------
    reg [10:0] r_cnt;
    wire       r_need   = (r_cnt >= REFRESH_CYCLES[10:0]);
    wire       r_urgent = (r_cnt >= URGENT_CYCLES[10:0]);

    // ------------------------------------------------------------------
    //  Arbiter
    // ------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_HOLD = 2'd1, S_RUN = 2'd2, S_GAP = 2'd3;
    reg [1:0]  st;
    reg        op_w;              // the operation in S_RUN belongs to W (else R)
    reg        p_rd, p_wr, p_ref; // issue pulses (one cycle)
    reg        saw_busy;

    wire a_cmd   = a_rd | a_wr | a_refresh;
    wire w_ready = (wst == W_HAVE);

    // ------------------------------------------------------------------
    //  CPU read hint
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst <= W_IDLE; w_we <= 1'b0; w_half <= 1'b0;
            w_addr <= 23'd0; w_din <= 16'd0; w_wdm <= 2'b11;
            wv_dout <= 16'd0; wv_done <= 1'b0;
            r_cnt <= 11'd0;
            st <= S_IDLE; op_w <= 1'b0;
            p_rd <= 1'b0; p_wr <= 1'b0; p_ref <= 1'b0; saw_busy <= 1'b0;
        end else begin
            p_rd <= 1'b0; p_wr <= 1'b0; p_ref <= 1'b0;
            wv_done <= 1'b0;

            // refresh age (a refresh issued by A or by us restarts it)
            if (a_refresh || p_ref)
                r_cnt <= 11'd0;
            else if (r_cnt != 11'h7FF)
                r_cnt <= r_cnt + 11'd1;

            // ---- W side ----
            case (wst)
                W_IDLE: if (wv_req) begin
                    if (b_drop) begin
                        // unmapped or protected: answer at once, no SDRAM cycle
                        wv_dout <= 16'hFFFF;
                        wv_done <= 1'b1;
                        wst     <= W_LOW;
                    end else begin
                        w_we   <= wv_we;
                        w_half <= wv_addr[1];
                        w_addr <= b_half_addr;
                        w_din  <= {wv_wdata, wv_wdata};
                        w_wdm  <= wv_addr[0] ? 2'b01 : 2'b10;
                        wst    <= W_HAVE;
                    end
                end
                W_LOW: if (!wv_req && !wv_done) wst <= W_IDLE;   // 4-phase release
                default: ;                                       // W_HAVE / W_BUSY: arbiter
            endcase

            // ---- arbiter ----
            case (st)
                S_IDLE, S_GAP: begin
                    if (st == S_IDLE && ((w_ready && !cpu_block) ||
                                         (r_need && (!cpu_block || r_urgent))))
                        st <= S_HOLD;          // busy to A from the next cycle on
                    else
                        st <= S_IDLE;
                end
                S_HOLD: begin
                    if (cpu_block && !r_urgent)
                        st <= S_IDLE;          // a CPU read is coming: let A in
                    else if (!s_busy && !a_cmd) begin
                        if (r_need && (r_urgent || !w_ready)) begin
                            p_ref <= 1'b1; op_w <= 1'b0;
                            saw_busy <= 1'b0; st <= S_RUN;
                        end else if (w_ready) begin
                            p_rd <= ~w_we; p_wr <= w_we; op_w <= 1'b1;
                            wst <= W_BUSY;
                            saw_busy <= 1'b0; st <= S_RUN;
                        end else
                            st <= S_IDLE;      // an A refresh made R unnecessary
                    end
                end
                S_RUN: begin
                    if (s_busy) saw_busy <= 1'b1;
                    if (op_w && !w_we) begin
                        if (s_data_ready) begin
                            wv_dout <= w_half ? s_dout32[31:16] : s_dout32[15:0];
                            wv_done <= 1'b1;
                            wst <= W_LOW;
                            st  <= S_GAP;
                        end
                    end else if (saw_busy && !s_busy) begin
                        if (op_w) begin
                            wv_done <= 1'b1;
                            wst <= W_LOW;
                        end
                        st <= S_GAP;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    //  Controller pins. A's command pulses can only appear while st is
    //  S_IDLE/S_GAP/first cycle of S_HOLD, never together with p_*.
    // ------------------------------------------------------------------
    wire sel_w = (st == S_RUN) && op_w;     // W owns addr/din/wdm while running
    assign s_rd      = a_rd | p_rd;
    assign s_wr      = a_wr | p_wr;
    assign s_refresh = a_refresh | p_ref;
    assign s_addr    = (p_rd | p_wr | sel_w) ? w_addr : a_addr;
    assign s_din     = (p_rd | p_wr | sel_w) ? w_din  : a_din;
    assign s_wdm     = (p_rd | p_wr | sel_w) ? w_wdm  : a_wdm;

    assign a_busy       = s_busy | (st == S_HOLD) | (st == S_RUN);
    assign a_data_ready = s_data_ready & ~sel_w;
    assign own_refresh  = p_ref;

endmodule

`default_nettype wire
