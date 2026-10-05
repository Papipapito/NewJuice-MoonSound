// ============================================================================
// moonsound_nj.sv - the MoonSound (OPL4) inside New Juice.
// Copyright (c) 2026 Albert "Papipapito", with Claude. GPL-3.0 (see NOTICE.md).
//
// What MoonTANG's moontang_core does, minus its own SDRAM controller: the wave
// memory leaves through the wv_* port (main_clk domain) to nj_sdram_arb, which
// shares New Juice's controller.
//   FM  (OPL3)   ports C4h-C7h   opl4fm.v  + gtaylormb opl3
//   PCM (YMF278B) ports 7Eh-7Fh  opl4_pcm.v + srg320 engine
//   wave memory                  wave_sdram.v (engine + YRW801 loader)
//   YRW801 loader                yrw801_loader.v + flash_rw.v, from SPI flash
//                                0x200000 once New Juice has loaded its ROMs
//
// Clocks (no new PLL, everything from rpll_main and therefore analysable):
//   clk_108m  main_clk (bus, wave port)
//   clk_54m   rpll_main CLKOUTD  = 108/2, in phase with main_clk (bus side)
//   clk_eng   rpll_main CLKOUTD3 = 108/3 = 36 MHz: PCM engine (its CE
//             averages 33.8688 MHz with ENG_CE_INC/ENG_CE_MOD = 588/625) and
//             the OPL3 FM core (opl3_pkg retuned to 36 MHz: 36e6/727 =
//             49.52 kHz, MoonSound 49.516 kHz). MoonTANG ran the FM from a
//             CLKDIV /4 of 108 MHz; here that CLKDIV's insertion delay gave
//             hold violations on the FM -> bus crossing, a PLL output does not.
//
// Resets:
//   por_reset_n  New Juice board reset (power-on, S1): memory chain, loader.
//                The wave memory survives an MSX /RESET, as in MoonTANG.
//   bus_reset_n  MSX /RESET: the OPL4 registers.
// ============================================================================
`default_nettype none

module moonsound_nj #(
    parameter [23:0] ENG_CE_INC   = 24'd588,        // 33.8688 / 36 MHz
    parameter [23:0] ENG_CE_MOD   = 24'd625,
    parameter [23:0] YRW_FLASH_BASE = 24'h200000,
    parameter [22:0] YRW_SIZE     = 23'h200000,
    parameter [31:0] YRW_SUM      = 32'h101FDA0E,   // sum of the 2 MB YRW801
    // New Juice has already used the flash when we take it over, so the
    // power-up wait of flash_rw is not needed (MoonTANG: 10M cycles).
    parameter [31:0] FLASH_STARTUP_WAIT = 32'd1000
) (
    input  wire        clk_108m,
    input  wire        clk_54m,
    input  wire        clk_eng,
    input  wire        lock_main,
    input  wire        sys_rst_n,        // New Juice board reset (main_clk)

    // ---- MSX bus as New Juice sees it (main_clk domain) ----
    input  wire        iorq_n,
    input  wire        rd_n,
    input  wire        wr_n,
    input  wire        m1_n,
    input  wire [7:0]  addr,
    input  wire [7:0]  din,
    input  wire        slot_reset_n,     // MSX /RESET (debounced)
    input  wire        slot_clk,         // MSX CLOCK pin (raw)

    output wire [7:0]  rd_data,
    output wire        rd_active,        // our read of C4-C7 / 7E-7F (bus alive)
    output wire        wait_n,           // /WAIT for IN 7Fh
    output wire        int_n,            // FM timer IRQ

    // ---- audio (clk_54m), FM + wave, saturated ----
    output reg  signed [15:0] mix_l = 16'sd0,
    output reg  signed [15:0] mix_r = 16'sd0,
    output reg  signed [15:0] mix_mono = 16'sd0,

    // ---- SPI flash, handed over by New Juice ----
    input  wire        flash_start,      // New Juice ROMs loaded (main_clk)
    output wire        flash_owned,      // 1 = these pins drive the flash
    output wire        mspi_cs,
    output wire        mspi_sclk,
    output wire        mspi_mosi,
    input  wire        mspi_miso,

    // ---- wave memory port (clk_108m) ----
    output wire        wv_req,
    output wire        wv_we,
    output wire [21:0] wv_addr,
    output wire [7:0]  wv_wdata,
    input  wire [15:0] wv_dout,
    input  wire        wv_done,
    output wire        rom_write_en,     // loader phase (clk_108m)

    // ---- status ----
    output wire        wl_done,          // YRW801 copied (or retries exhausted)
    output wire        wl_error,         // the copy failed
    output wire        wl_badimg         // copied, but it is not the YRW801
);

    // ------------------------------------------------------------------
    //  Resets
    // ------------------------------------------------------------------
    reg [3:0] por_sync = 4'd0;
    always @(posedge clk_54m or negedge sys_rst_n)
        if (!sys_rst_n) por_sync <= 4'd0;
        else            por_sync <= {por_sync[2:0], 1'b1};
    wire por_reset_n = por_sync[3];

    // bus signals: main_clk -> clk_54m (same PLL, in phase: one register)
    reg       s_iorq_n = 1'b1, s_rd_n = 1'b1, s_wr_n = 1'b1, s_m1_n = 1'b1;
    reg       s_reset_n = 1'b0;
    reg [7:0] s_addr = 8'd0, s_din = 8'd0;
    always @(posedge clk_54m) begin
        s_iorq_n  <= iorq_n;
        s_rd_n    <= rd_n;
        s_wr_n    <= wr_n;
        s_m1_n    <= m1_n;
        s_addr    <= addr;
        s_din     <= din;
        s_reset_n <= slot_reset_n;
    end

    reg [2:0] rst_sync = 3'd0;
    always @(posedge clk_54m or negedge por_reset_n)
        if (!por_reset_n) rst_sync <= 3'd0;
        else              rst_sync <= {rst_sync[1:0], s_reset_n};
    wire bus_reset_n = rst_sync[2];

    // ------------------------------------------------------------------
    //  FM (opl4fm) - C4h-C7h
    // ------------------------------------------------------------------
    wire        opl4fm_rd, opl4fm_wrd, opl4fm_int_n;
    wire [7:0]  opl4fm_dout, opl4fm_wdout;
    wire signed [15:0] opl4fm_wav, opl4fm_wav_l, opl4fm_wav_r;
    wire [1:0]  wave_status;

    opl4fm u_opl4fm (
        .rst_n(bus_reset_n), .clk_host(clk_54m), .clk_opl3(clk_eng),
        .iorq_n(s_iorq_n), .rd_n(s_rd_n), .wr_n(s_wr_n), .m1_n(s_m1_n),
        .addr(s_addr), .din(s_din), .wave_status(wave_status),
        .fm_rd(opl4fm_rd), .wave_rd(opl4fm_wrd), .dout(opl4fm_dout),
        .wave_dout(opl4fm_wdout), .pcm_out(opl4fm_wav),
        .pcm_out_l(opl4fm_wav_l), .pcm_out_r(opl4fm_wav_r), .int_n(opl4fm_int_n)
    );

    // ------------------------------------------------------------------
    //  PCM (opl4_pcm) - 7Eh-7Fh. IN 7Fh is served with /WAIT (RD_MIRROR=0).
    // ------------------------------------------------------------------
    wire        opl4pcm_rd, opl4pcm_wait_n;
    wire [7:0]  opl4pcm_dout;
    wire [5:0]  opl4_mixfm;
    wire signed [15:0] opl4pcm_l, opl4pcm_r;
    wire        weng_req, weng_we;
    wire [21:0] weng_addr;
    wire [7:0]  weng_wdata, weng_rdata;
    wire [15:0] weng_rword;
    wire        weng_done_t;

    opl4_pcm #(
        .CE_INC(ENG_CE_INC), .CE_MOD(ENG_CE_MOD), .RD_MIRROR(0)
    ) u_opl4pcm (
        .rst_n(bus_reset_n), .clk_host(clk_54m),
        .iorq_n(s_iorq_n), .rd_n(s_rd_n), .wr_n(s_wr_n), .m1_n(s_m1_n),
        .addr(s_addr), .din(s_din),
        .wave_rd(opl4pcm_rd), .wave_dout(opl4pcm_dout),
        .wave_wait_n(opl4pcm_wait_n), .wave_status(wave_status),
        .mix_fm(opl4_mixfm), .pcm_l(opl4pcm_l), .pcm_r(opl4pcm_r),
        .clk_eng(clk_eng), .eng_rst_n(bus_reset_n & wl_done),
        .mem_req(weng_req), .mem_we(weng_we), .mem_addr(weng_addr),
        .mem_wdata(weng_wdata), .mem_rdata(weng_rdata),
        .mem_rword(weng_rword), .mem_done_t(weng_done_t),
        .diag(), .dbg_tx(), .vid_diag(4'd0)
    );

    // ------------------------------------------------------------------
    //  Wave memory: engine + loader -> one port (wv_*) in clk_108m
    // ------------------------------------------------------------------
    wire        wl_req_toggle, wl_we, wl_done_toggle;
    wire [21:0] wl_addr;
    wire [7:0]  wl_wdata;

    wave_sdram u_wave (
        .clk_host(clk_54m), .rst_n(por_reset_n),
        .req_toggle(wl_req_toggle), .we(wl_we), .addr(wl_addr), .wdata(wl_wdata),
        .rdata(), .done_toggle(wl_done_toggle), .ready(),
        .clk_eng(clk_eng), .eng_req(weng_req), .eng_we(weng_we),
        .eng_addr(weng_addr), .eng_wdata(weng_wdata),
        .eng_rdata(weng_rdata), .eng_rword(weng_rword), .eng_done_t(weng_done_t),
        .diag(),
        .clk_108m(clk_108m),
        .wv_req(wv_req), .wv_we(wv_we), .wv_addr(wv_addr), .wv_wdata(wv_wdata),
        .wv_dout(wv_dout), .wv_done(wv_done)
    );

    // ------------------------------------------------------------------
    //  YRW801 loader. New Juice reads its ROMs from the flash first and
    //  keeps the CPU in /WAIT meanwhile; the YRW801 copy starts afterwards,
    //  in the background, with the CPU running. The hand-over is sticky
    //  until the next board reset.
    // ------------------------------------------------------------------
    reg [2:0] fs_sync = 3'd0;
    reg       owned = 1'b0;
    always @(posedge clk_54m or negedge por_reset_n)
        if (!por_reset_n) begin
            fs_sync <= 3'd0; owned <= 1'b0;
        end else begin
            fs_sync <= {fs_sync[1:0], flash_start};
            if (fs_sync[2]) owned <= 1'b1;
        end
    assign flash_owned = owned;

    wire [23:0] fl_addr;
    wire        fl_rd, fl_data_ready, fl_busy, fl_terminate;
    wire [7:0]  fl_dout;
    wire        wl_sum_ok;

    yrw801_loader #(
        .FLASH_BASE(YRW_FLASH_BASE), .WAVE_SIZE(YRW_SIZE), .EXPECTED_SUM(YRW_SUM)
    ) u_loader (
        .clk(clk_54m), .rst_n(por_reset_n), .start(owned),
        .flash_addr(fl_addr), .flash_rd(fl_rd), .flash_dout(fl_dout),
        .flash_data_ready(fl_data_ready), .flash_busy(fl_busy),
        .flash_terminate(fl_terminate),
        .wl_req_toggle(wl_req_toggle), .wl_we(wl_we), .wl_addr(wl_addr),
        .wl_wdata(wl_wdata), .wl_done_toggle(wl_done_toggle),
        .wl_done(wl_done), .wl_error(wl_error), .wl_sum_ok(wl_sum_ok),
        .wl_dbg_state()
    );
    assign wl_badimg = wl_done & ~wl_error & ~wl_sum_ok;

    flash #(.STARTUP_WAIT(FLASH_STARTUP_WAIT)) u_flash (
        .clk(clk_54m), .reset_n(por_reset_n),
        .SCLK(mspi_sclk), .CS(mspi_cs), .MISO(mspi_miso), .MOSI(mspi_mosi),
        .addr(fl_addr), .rd(fl_rd), .dout(fl_dout),
        .data_ready(fl_data_ready), .busy(fl_busy), .terminate(fl_terminate),
        .write_enable(1'b0), .write_din(8'd0), .write_addr(24'd0),
        .write_busy(), .write_terminate(1'b0), .write_counter()
    );

    // ROM area writable only while the loader runs (to the arbiter, 108 MHz)
    reg [1:0] rwe_sync = 2'b00;
    always @(posedge clk_108m or negedge sys_rst_n)
        if (!sys_rst_n) rwe_sync <= 2'b00;
        else            rwe_sync <= {rwe_sync[0], ~wl_done};
    assign rom_write_en = rwe_sync[1];

    // ------------------------------------------------------------------
    //  Back to the bus, with MoonTANG's live-bus guard: only touch the bus
    //  (data, /WAIT, /INT) while the slot clock runs and /RESET is high.
    // ------------------------------------------------------------------
    wire any_rd = opl4fm_rd | opl4pcm_rd;
    assign rd_data = opl4fm_rd ? opl4fm_dout : opl4pcm_dout;

    reg  [2:0]  ck_s = 3'b000;
    reg  [16:0] ck_win = 17'd0;
    reg  [6:0]  ck_edges = 7'd0;
    reg         ck_alive = 1'b0;
    always @(posedge clk_54m) begin
        ck_s   <= {ck_s[1:0], slot_clk};
        ck_win <= ck_win + 17'd1;
        if (ck_win == 17'd0) begin
            ck_alive <= ck_edges[6];
            ck_edges <= 7'd0;
        end else if ((ck_s[2] ^ ck_s[1]) && !ck_edges[6])
            ck_edges <= ck_edges + 7'd1;
    end
    wire bus_ok = ck_alive & bus_reset_n;
    // any_rd comes through two 54 MHz register stages, so on its own it would
    // let go of the bus (D0-D7, BUSDIR, DATADIR) 28-45 ns after New Juice's
    // own ports. Gating it with /RD and /IORQ (main_clk domain, the same ones
    // the New Juice ports decode) releases the bus at the same time as theirs.
    assign rd_active = any_rd & bus_ok & ~rd_n & ~iorq_n;
    assign wait_n    = opl4pcm_wait_n | ~bus_ok;
    assign int_n     = opl4fm_int_n   | ~bus_ok;

    // ------------------------------------------------------------------
    //  Mix (MoonTANG's): FM with the F8 attenuation, wave >> 1, saturated
    // ------------------------------------------------------------------
    wire signed [15:0] o4fm_sl = $signed(opl4fm_wav_l);
    wire signed [15:0] o4fm_sr = $signed(opl4fm_wav_r);
    wire signed [15:0] o4fm_bl = opl4_mixfm[0] ? (o4fm_sl >>> 1) + (o4fm_sl >>> 2) : o4fm_sl;
    wire signed [15:0] o4fm_br = opl4_mixfm[0] ? (o4fm_sr >>> 1) + (o4fm_sr >>> 2) : o4fm_sr;
    wire signed [15:0] o4fm_al = o4fm_bl >>> opl4_mixfm[2:1];
    wire signed [15:0] o4fm_ar = o4fm_br >>> opl4_mixfm[2:1];
    wire signed [15:0] fm_l = (opl4_mixfm[2:0] == 3'd7) ? 16'sd0 : o4fm_al;
    wire signed [15:0] fm_r = (opl4_mixfm[2:0] == 3'd7) ? 16'sd0 : o4fm_ar;
    wire signed [15:0] wave_l = opl4pcm_l >>> 1;
    wire signed [15:0] wave_r = opl4pcm_r >>> 1;

    function automatic signed [15:0] sat16(input signed [17:0] v);
        sat16 = (v >  18'sd32767) ? 16'sh7FFF :
                (v < -18'sd32768) ? 16'sh8000 : v[15:0];
    endfunction

    wire signed [17:0] mixL = {{2{fm_l[15]}}, fm_l} + {{2{wave_l[15]}}, wave_l};
    wire signed [17:0] mixR = {{2{fm_r[15]}}, fm_r} + {{2{wave_r[15]}}, wave_r};
    wire signed [18:0] mixS = {mixL[17], mixL} + {mixR[17], mixR};
    wire signed [17:0] mixM = mixS[18:1];

    always @(posedge clk_54m) begin
        mix_l    <= sat16(mixL);
        mix_r    <= sat16(mixR);
        mix_mono <= sat16(mixM);
    end

endmodule

`default_nettype wire
