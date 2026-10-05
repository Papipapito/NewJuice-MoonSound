// ============================================================================
// tb_arb.v - New Juice MoonSound fork: the SDRAM arbiter with the REAL chain.
//
//   Z80 (synthetic, real pin timing, debounce delay FE_NS)
//     -> CPU client (one command per memory cycle, like sdram_mapper)
//     -> sdram_command_adapter (New Juice, unchanged)  = client A
//   YMF278B engine (opl4_pcm + ymf278b) -> wave_sdram = client W
//   both -> nj_sdram_arb -> sdram.v (New Juice, unchanged) -> SDRAM model
//
// MODE 0 (traffic): 24 voices playing from the YRW801 area while the Z80 runs
//   M1/MR/MW cycles at TZ. Checks: no CPU command lost, every CPU read returns
//   the last value written to that word (shadow memory), every wave read
//   returns the SDRAM word at its translated address, CPU writes never land
//   outside their word; measures CPU latency (cmd_en -> ack), wave wait and
//   the engine output rate (samples produced / sample ticks).
// MODE 1 (refresh): after start-up the Z80 STOPS (no RFSH, no bus cycles) for
//   STOP_MS milliseconds, then reads every row of a test set. The SDRAM model
//   checks retention (64 ms). With NEG = 1 the arbiter's own refresh timer is
//   disabled: the model MUST report decayed rows (negative control).
//
// Clocks are generated from one time base so that 108, 54 and 36 MHz keep the
// phase relation of rpll_main (CLKOUT, CLKOUTD, CLKOUTD3).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_arb;
    parameter integer MODE      = 0;
    parameter integer NEG       = 0;          // 1 = own refresh disabled (control)
    parameter integer NSLOT     = 24;
    parameter integer FMT       = 3;          // 3 = mixed 8/12/16 bit
    parameter integer OCT       = 99;         // 99 = mixed pitch
    parameter integer FNUM      = 0;
    parameter integer MEAS_US   = 2000;
    parameter integer CPU_ON    = 1;
    parameter integer PCM_ON    = 1;
    parameter real    TZ        = 279.365;    // Z80 period (3.58 MHz)
    parameter real    FE_NS     = 120.0;      // New Juice bus debounce delay
    parameter integer PATTERN   = 0;          // 0 = M1,MR,MW  1 = M1,MR,MR  2 = M1 only
    parameter integer STOP_MS   = 70;
    parameter integer CPU_HINT  = 1;          // arbiter's CPU-read hint (0 = off, for comparison)

    // ------------------------------------------------------------------
    //  Clocks: step = 1/648 MHz; 108 = 6 steps, 54 = 12, 36 = 18
    // ------------------------------------------------------------------
    reg clk_108m = 1'b0, clk_54m = 1'b0, clk_eng = 1'b0;
    integer ph = 0;
    initial forever begin
        #(1.54321);
        ph = (ph + 1) % 36;
        if (ph % 3 == 0) clk_108m = ~clk_108m;
        if (ph % 6 == 0) clk_54m  = ~clk_54m;
        if (ph % 9 == 0) clk_eng  = ~clk_eng;
    end
    wire clk_sdram = ~clk_108m;

    reg por_n = 1'b0, bus_rst_n = 1'b0, eng_rst_n = 1'b0;

    // ------------------------------------------------------------------
    //  SDRAM: model + New Juice controller
    // ------------------------------------------------------------------
    wire [31:0] sd_dq; wire [10:0] sd_a; wire [1:0] sd_ba; wire [3:0] sd_dqm;
    wire sd_ncs, sd_nwe, sd_nras, sd_ncas, sd_clk, sd_cke;
    sdram_model #(.RET_CHECK(1)) sdram (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_ncs), .ras_n(sd_nras),
        .cas_n(sd_ncas), .we_n(sd_nwe), .addr(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq));
    wire s_rd, s_wr, s_ref; wire [22:0] s_addr; wire [15:0] s_din; wire [1:0] s_wdm;
    wire [15:0] s_dout; wire [31:0] s_dout32; wire s_dr, s_busy, s_en;
    sdram #(.FREQ(108_000_000), .CAS(5'd3), .T_WR(5'd3), .T_MRD(5'd2), .T_RP(5'd2), .T_RCD(5'd2), .T_RC(5'd7)) u_sd (
        .SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_nCS(sd_ncs), .SDRAM_nWE(sd_nwe),
        .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_CLK(sd_clk), .SDRAM_CKE(sd_cke), .SDRAM_DQM(sd_dqm),
        .clk(clk_108m), .clk_sdram(clk_sdram), .resetn(por_n),
        .rd(s_rd), .wr(s_wr), .refresh(s_ref), .addr(s_addr), .din(s_din), .wdm(s_wdm),
        .dout(s_dout), .dout32(s_dout32), .data_ready(s_dr), .busy(s_busy), .enabled(s_en));

    // ------------------------------------------------------------------
    //  Client A: the real adapter
    // ------------------------------------------------------------------
    reg rfsh_n = 1, m1_n = 1, mreq_n = 1, rd_n_b = 1, wr_n_b = 1;   // as seen in main_clk
    reg z_rfsh = 1, z_m1 = 1, z_mreq = 1, z_rd = 1, z_wr = 1;       // Z80 pins
    reg cmd_en = 0; reg [2:0] cmd = 3'b101; reg [20:0] cmd_addr = 0; reg [3:0] cmd_dqm = 4'b1110; reg [31:0] cmd_data = 0;
    wire [31:0] a_rdata; wire a_init, a_ack;
    wire a_rd, a_wr, a_ref; wire [22:0] a_addr; wire [15:0] a_din; wire [1:0] a_wdm;
    wire a_busy, a_dr;
    sdram_command_adapter u_ad (
        .clk(clk_108m), .reset_n(por_n), .debug_wait_n(1'b1),
        .rfsh_n(rfsh_n), .m1_n(m1_n), .merq_n(mreq_n), .iorq_n(1'b1), .rd_n(rd_n_b), .wr_n(wr_n_b),
        .cmd_en(cmd_en), .cmd(cmd), .cmd_addr(cmd_addr), .cmd_dqm(cmd_dqm), .cmd_data(cmd_data),
        .read_data(a_rdata), .init_done(a_init), .cmd_ack(a_ack),
        .rd(a_rd), .wr(a_wr), .refresh(a_ref), .addr(a_addr), .din(a_din), .wdm(a_wdm),
        .dout32(s_dout32), .data_ready(a_dr), .busy(a_busy), .enabled(s_en));

    // ------------------------------------------------------------------
    //  Client W: wave_sdram + PCM engine
    // ------------------------------------------------------------------
    wire wv_req, wv_we, wv_done; wire [21:0] wv_addr; wire [7:0] wv_wdata; wire [15:0] wv_dout;
    wire own_ref;
    // raw /SLTSL and /RD at the FPGA pins: the synthetic client treats every
    // memory cycle as one of this cartridge, so /SLTSL follows /MREQ (15 ns of
    // slot decoder and board buffer)
    wire pin_sltsl_n, pin_rd_n;
    assign #15 pin_sltsl_n = z_mreq | ~z_rfsh;
    assign #15 pin_rd_n    = z_rd;
    nj_sdram_arb #(.REFRESH_CYCLES(NEG ? 2047 : 842), .URGENT_CYCLES(NEG ? 2047 : 1350), .CPU_HINT(CPU_HINT)) u_arb (
        .clk(clk_108m), .rst_n(por_n),
        .a_rd(a_rd), .a_wr(a_wr), .a_refresh(a_ref), .a_addr(a_addr), .a_din(a_din), .a_wdm(a_wdm),
        .a_busy(a_busy), .a_data_ready(a_dr),
        .cpu_sltsl_n(pin_sltsl_n), .cpu_rd_n(pin_rd_n),
        .wv_req(wv_req), .wv_we(wv_we), .wv_addr(wv_addr), .wv_wdata(wv_wdata), .wv_dout(wv_dout), .wv_done(wv_done),
        .rom_write_en(1'b0),
        .s_rd(s_rd), .s_wr(s_wr), .s_refresh(s_ref), .s_addr(s_addr), .s_din(s_din), .s_wdm(s_wdm),
        .s_dout32(s_dout32), .s_data_ready(s_dr), .s_busy(s_busy), .own_refresh(own_ref));
    // control negativo: sin refresco propio (el contador se satura antes de llegar)
    initial if (NEG) begin
        #1; force u_arb.r_cnt = 11'd0;
    end

    wire        e_req, e_we, e_done_t;
    wire [21:0] e_addr; wire [7:0] e_wdata, e_rdata; wire [15:0] e_rword;
    wave_sdram u_wave (
        .clk_host(clk_54m), .rst_n(por_n), .req_toggle(1'b0), .we(1'b0), .addr(22'd0), .wdata(8'd0),
        .rdata(), .done_toggle(), .ready(),
        .clk_eng(clk_eng), .eng_req(e_req), .eng_we(e_we), .eng_addr(e_addr), .eng_wdata(e_wdata),
        .eng_rdata(e_rdata), .eng_rword(e_rword), .eng_done_t(e_done_t), .diag(),
        .clk_108m(clk_108m), .wv_req(wv_req), .wv_we(wv_we), .wv_addr(wv_addr), .wv_wdata(wv_wdata),
        .wv_dout(wv_dout), .wv_done(wv_done));

    reg        iorq_n = 1'b1, rd_n = 1'b1, wr_n = 1'b1;
    reg [7:0]  addr = 8'h00, din = 8'h00;
    wire signed [15:0] pcm_l, pcm_r;
    opl4_pcm #(.CE_INC(24'd588), .CE_MOD(24'd625), .RD_MIRROR(0)) u_pcm (
        .rst_n(bus_rst_n), .clk_host(clk_54m),
        .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .m1_n(1'b1), .addr(addr), .din(din),
        .wave_rd(), .wave_dout(), .wave_wait_n(), .wave_status(), .mix_fm(),
        .pcm_l(pcm_l), .pcm_r(pcm_r),
        .clk_eng(clk_eng), .eng_rst_n(eng_rst_n),
        .mem_req(e_req), .mem_we(e_we), .mem_addr(e_addr), .mem_wdata(e_wdata),
        .mem_rdata(e_rdata), .mem_rword(e_rword), .mem_done_t(e_done_t),
        .diag(), .dbg_tx(), .vid_diag(4'd0));
    integer ii_sl;
    initial begin
        #1;
        for (ii_sl = 0; ii_sl < 32; ii_sl = ii_sl + 1) begin
            u_pcm.sl_stride[ii_sl] = 3'd0; u_pcm.sl_hi[ii_sl] = 3'd0;
        end
    end

    // ------------------------------------------------------------------
    //  Memory contents: a distinct value in every 32-bit word
    // ------------------------------------------------------------------
    function [31:0] pat(input [20:0] w);
        pat = ({11'd0, w} * 32'h9E3779B1) ^ 32'h5A5A00FF;
    endfunction
    // wave byte b (YRW801 area) lives at SDRAM byte 0x200000 + b
    task setb(input [21:0] b, input [7:0] v);
        reg [31:0] w; reg [20:0] wi; reg [22:0] sb;
        begin sb = 23'h200000 + b; wi = sb[22:2]; w = sdram.mem[wi]; w[8*sb[1:0] +: 8] = v; sdram.mem[wi] = w; end
    endtask
    function integer fmt_of(input integer s); fmt_of = (FMT == 3) ? (s % 3) : FMT; endfunction
    function integer oct_of(input integer s); oct_of = (OCT == 99) ? ((s % 4) - 1) : OCT; endfunction
    function integer fnum_of(input integer s); fnum_of = (OCT == 99) ? ((s * 37) % 1024) : FNUM; endfunction

    // CPU word pool: 2048 words in the mapper area (0x000000-0x1FFFFF) and
    // 2048 in the MegaRAM area (0x400000-0x5FFFFF), spread over many rows
    reg [31:0] shadow [0:4095];
    function [20:0] pool_addr(input [11:0] i);
        pool_addr = i[11] ? (21'h100000 + {i[10:0], 8'h00} + {10'd0, i[10:0]} % 21'd251)
                          : (21'h000000 + {i[10:0], 8'h00} + {10'd0, i[10:0]} % 21'd241);
    endfunction

    integer k, t, f, endv, nend;
    reg [21:0] st;
    initial begin
        for (k = 0; k < (1<<21); k = k + 1) sdram.mem[k] = pat(k[20:0]);
        for (k = 0; k < 4096; k = k + 1) shadow[k] = pat(pool_addr(k[11:0]));
        for (t = 0; t < 24; t = t + 1) begin
            f  = fmt_of(t);
            st = 22'h010000 + t * 22'h010000;
            endv = (f == 0) ? 16'hFE00 : (f == 1) ? 16'hA900 : 16'h7F00;
            nend = (65536 - endv) & 16'hFFFF;
            setb(t*12+0, {f[1:0], st[21:16]}); setb(t*12+1, st[15:8]); setb(t*12+2, st[7:0]);
            setb(t*12+3, 8'h00); setb(t*12+4, 8'h00);
            setb(t*12+5, nend[15:8]); setb(t*12+6, nend[7:0]);
            setb(t*12+7, 8'h00); setb(t*12+8, 8'hF0); setb(t*12+9, 8'h00);
            setb(t*12+10, 8'h0F); setb(t*12+11, 8'h00);
        end
    end

    // ------------------------------------------------------------------
    //  OPL4 bus (clk_54m)
    // ------------------------------------------------------------------
    task wr(input [7:0] p, input [7:0] v);
        begin
            @(posedge clk_54m); addr <= p; din <= v;
            @(posedge clk_54m); iorq_n <= 1'b0; wr_n <= 1'b0;
            repeat (16) @(posedge clk_54m);
            iorq_n <= 1'b1; wr_n <= 1'b1;
            repeat (160) @(posedge clk_54m);
        end
    endtask
    task wv(input [7:0] r, input [7:0] v); begin wr(8'h7E, r); wr(8'h7F, v); end endtask

    // ------------------------------------------------------------------
    //  Synthetic Z80 (pins in real time, seen FE_NS later in main_clk)
    // ------------------------------------------------------------------
    reg cpu_run = 1'b0;
    reg d_rfsh = 1, d_m1 = 1, d_mreq = 1, d_rd = 1, d_wr = 1;
    always @(z_rfsh) d_rfsh <= #(FE_NS) z_rfsh;
    always @(z_m1)   d_m1   <= #(FE_NS) z_m1;
    always @(z_mreq) d_mreq <= #(FE_NS) z_mreq;
    always @(z_rd)   d_rd   <= #(FE_NS) z_rd;
    always @(z_wr)   d_wr   <= #(FE_NS) z_wr;
    always @(posedge clk_108m) begin
        rfsh_n <= d_rfsh; m1_n <= d_m1; mreq_n <= d_mreq; rd_n_b <= d_rd; wr_n_b <= d_wr;
    end
    task m1cyc; begin    // T1 T2 TW T3 T4 (the MSX adds one wait in M1)
        z_m1 = 0;
        #(0.5*TZ) begin z_mreq = 0; z_rd = 0; end
        #(2.5*TZ) begin z_mreq = 1; z_rd = 1; z_m1 = 1; z_rfsh = 0; end
        #(0.5*TZ) z_mreq = 0;
        #(1.0*TZ) z_mreq = 1;
        #(0.5*TZ) z_rfsh = 1;
    end endtask
    task mrcyc; begin
        #(0.5*TZ) begin z_mreq = 0; z_rd = 0; end
        #(2.0*TZ) begin z_mreq = 1; z_rd = 1; end
        #(0.5*TZ);
    end endtask
    task mwcyc; begin
        #(0.5*TZ) z_mreq = 0;
        #(1.0*TZ) z_wr = 0;
        #(1.0*TZ) begin z_mreq = 1; z_wr = 1; end
        #(0.5*TZ);
    end endtask
    initial begin
        wait (cpu_run);
        forever begin
            if (!cpu_run) wait (cpu_run);
            m1cyc;
            if (PATTERN == 0) begin mrcyc; mwcyc; end
            else if (PATTERN == 1) begin mrcyc; mrcyc; end
        end
    end

    // ------------------------------------------------------------------
    //  CPU client (one command per memory cycle, like sdram_mapper) + checks
    // ------------------------------------------------------------------
    reg seen = 1'b0, waiting = 1'b0, is_rd = 1'b0;
    reg [11:0] cur_i = 12'd0;
    reg [20:0] cur_w = 21'd0;
    reg [31:0] cur_d = 32'd0;
    reg [1:0]  cur_lane = 2'd0;
    integer n_drop = 0, n_bad_a = 0, n_bad_w = 0, n_chk_w = 0, n_chk_a = 0, n_xa = 0, n_wcpu = 0;
    reg [11:0] lfsr = 12'hACE;
    reg [31:0] dlfsr = 32'h12345678;
    reg meas = 1'b0;
    reg force_rd = 1'b0;              // MODE 1: reads only (row sweep)
    reg [11:0] sweep_i = 12'd0;
    reg sweep = 1'b0;
    integer lat_c = 0, cl_n = 0, cl_sum = 0, cl_max = 0, cl_min = 1<<30, cw_max = 0;
    integer cl_hist [0:63];
    integer hi;
    initial for (hi = 0; hi < 64; hi = hi + 1) cl_hist[hi] = 0;

    // a command while the adapter cannot queue it would be lost
    always @(posedge clk_108m) if (cmd_en && (u_ad.request_queued || u_ad.command_pending)) n_drop = n_drop + 1;

    always @(posedge clk_108m) begin
        cmd_en <= 1'b0;
        if (mreq_n) seen <= 1'b0;
        if (cpu_run && !mreq_n && rfsh_n && (!rd_n_b || !wr_n_b) && !seen && a_init) begin
            seen <= 1'b1; cmd_en <= 1'b1;
            is_rd <= !rd_n_b || force_rd;
            cmd <= (!rd_n_b || force_rd) ? 3'b101 : 3'b100;
            lfsr <= {lfsr[10:0], lfsr[11] ^ lfsr[10] ^ lfsr[9] ^ lfsr[3]};
            dlfsr <= {dlfsr[30:0], dlfsr[31] ^ dlfsr[21] ^ dlfsr[1] ^ dlfsr[0]};
            cur_i <= sweep ? sweep_i : lfsr;
            if (sweep) sweep_i <= sweep_i + 12'd1;
            cur_w <= pool_addr(sweep ? sweep_i : lfsr);
            cmd_addr <= pool_addr(sweep ? sweep_i : lfsr);
            cur_lane <= lfsr[1:0];
            cmd_dqm <= ~(4'b0001 << lfsr[1:0]);
            cmd_data <= {4{dlfsr[7:0]}};
            cur_d <= {4{dlfsr[7:0]}};
            waiting <= 1'b1; lat_c <= 0;
        end else if (waiting) begin
            lat_c <= lat_c + 1;
            if (a_ack) begin
                waiting <= 1'b0;
                if (is_rd) begin
                    n_chk_a = n_chk_a + 1;
                    if (^a_rdata === 1'bx) n_xa = n_xa + 1;
                    if (a_rdata !== shadow[cur_i]) begin
                        n_bad_a = n_bad_a + 1;
                        if (n_bad_a <= 5) $display("  BAD_CPU t=%0t word=%h got=%h exp=%h", $time, cur_w, a_rdata, shadow[cur_i]);
                    end
                end else begin
                    n_wcpu = n_wcpu + 1;
                    shadow[cur_i][8*cur_lane +: 8] = cur_d[7:0];
                end
                if (meas) begin
                    if (is_rd) begin
                        cl_n = cl_n + 1; cl_sum = cl_sum + lat_c + 1;
                        if (lat_c + 1 > cl_max) cl_max = lat_c + 1;
                        if (lat_c + 1 < cl_min) cl_min = lat_c + 1;
                        cl_hist[(lat_c+1) > 63 ? 63 : lat_c+1] = cl_hist[(lat_c+1) > 63 ? 63 : lat_c+1] + 1;
                    end else if (lat_c + 1 > cw_max) cw_max = lat_c + 1;
                end
            end
        end
    end

    // every wave read returns the SDRAM word at its translated address
    reg [20:0] w_word;
    always @(posedge clk_108m) if (wv_done && !wv_we && wv_req) begin
        if (u_arb.w_addr[22:20] == 3'b001 || u_arb.w_addr[22:19] == 4'b0111) begin
            n_chk_w = n_chk_w + 1;
            w_word = u_arb.w_addr[21:1];
            if (wv_dout !== (u_arb.w_half ? sdram.mem[w_word][31:16] : sdram.mem[w_word][15:0])) begin
                n_bad_w = n_bad_w + 1;
                if (n_bad_w <= 5) $display("  BAD_W t=%0t half=%h got=%h", $time, u_arb.w_addr, wv_dout);
            end
        end
    end

    // ------------------------------------------------------------------
    //  Instrumentation
    // ------------------------------------------------------------------
    integer     n_cyc = 0, n_stall = 0, n_req = 0;
    integer     lat = 0, lat_max = 0, lat_sum = 0, lat_n = 0, lat_min = 1<<30;
    reg         inop = 1'b0, seen_t = 1'b0;
    reg  [15:0] c_push0, c_tick0, c_rep0;
    integer     n_ref = 0, n_own = 0, n_wops = 0, n_aops = 0;
    always @(posedge clk_eng) if (meas) begin
        n_cyc = n_cyc + 1;
        if (u_pcm.stall) n_stall = n_stall + 1;
        if (e_req) begin n_req = n_req + 1; inop = 1'b1; lat = 0; seen_t = e_done_t; end
        else if (inop) begin
            lat = lat + 1;
            if (e_done_t != seen_t) begin
                inop = 1'b0; lat_n = lat_n + 1; lat_sum = lat_sum + lat;
                if (lat > lat_max) lat_max = lat;
                if (lat < lat_min) lat_min = lat;
            end
        end
    end
    integer wp = 0, wp_max = 0, wp_sum = 0, wp_n = 0;
    always @(posedge clk_108m) if (meas) begin
        if (s_ref) n_ref = n_ref + 1;
        if (own_ref) n_own = n_own + 1;
        if (u_arb.p_rd || u_arb.p_wr) n_wops = n_wops + 1;
        if (a_rd || a_wr) n_aops = n_aops + 1;
        if (u_arb.wst == 2'd1) wp = wp + 1;           // W_HAVE: waiting for the controller
        else if (wp != 0) begin wp_n = wp_n + 1; wp_sum = wp_sum + wp; if (wp > wp_max) wp_max = wp; wp = 0; end
    end

    // ------------------------------------------------------------------
    //  Test
    // ------------------------------------------------------------------
    integer errors = 0;
    task chk(input cond, input [1023:0] what);
        begin
            if (cond !== 1'b1) begin errors = errors + 1; $display("  [FAIL] %0s", what); end
            else $display("  [ok]   %0s", what);
        end
    endtask

    integer s, o, fn, n_stale0;
    real t0, t1, us, ticks, push, reps, ratio;
    reg [7:0] r38, r20;
    initial begin
        #200 por_n = 1'b1;
        #1000 bus_rst_n = 1'b1;
        wait (s_en);
        repeat (20) @(posedge clk_108m);
        eng_rst_n = (PCM_ON != 0);
        #2000;
        if (PCM_ON) begin
            wr(8'hC6, 8'h05); wr(8'hC7, 8'h03);
            wv(8'h02, 8'h00);
            for (s = 0; s < NSLOT; s = s + 1) begin
                o = oct_of(s); fn = fnum_of(s);
                r20 = {fn[6:0], 1'b0};
                r38 = {o[3:0], 1'b0, fn[9:7]};
                wv(8'h50 + s, 8'h00); wv(8'h20 + s, r20); wv(8'h38 + s, r38); wv(8'h08 + s, s[7:0]);
            end
            #300000;
            for (s = 0; s < NSLOT; s = s + 1) wv(8'h68 + s, 8'h80);
        end
        $display("CONFIG: MODE=%0d NEG=%0d FMT=%0d OCT=%0d CPU_ON=%0d PCM_ON=%0d TZ=%.2f (%.3f MHz) FE=%.0f PAT=%0d CPU_HINT=%0d",
                 MODE, NEG, FMT, OCT, CPU_ON, PCM_ON, TZ, 1000.0/TZ, FE_NS, PATTERN, CPU_HINT);

        if (MODE == 1) begin
            // ---------------- refresh with the Z80 stopped ----------------
            cpu_run = 1'b1; #200000;                  // some normal traffic first
            cpu_run = 1'b0; #2000;                    // the Z80 stops: no RFSH, no cycles
            n_stale0 = sdram.n_stale;
            $display("  Z80 parado durante %0d ms (PCM_ON=%0d)", STOP_MS, PCM_ON);
            t0 = $realtime; k = sdram.n_ref;
            #(STOP_MS * 1.0e6);
            $display("  refrescos durante la parada: %0d (%0.2f us de media), hueco maximo entre refrescos %0.2f us",
                     sdram.n_ref - k, ($realtime - t0) / 1000.0 / ((sdram.n_ref - k) > 0 ? (sdram.n_ref - k) : 1),
                     sdram.max_ref_gap / 1000.0);
            // the Z80 comes back and reads the whole pool, row after row
            force_rd = 1'b1; sweep = 1'b1; sweep_i = 12'd0;
            cpu_run = 1'b1;
            wait (sweep_i == 12'hFFF);
            #20000;
            $display("  filas caducadas (modelo): %0d | lecturas CPU %0d, erroneas %0d", sdram.n_stale, n_chk_a, n_bad_a);
            if (NEG) begin
                chk(sdram.n_stale > 0, "CONTROL NEGATIVO: sin el refresco propio el modelo detecta filas caducadas");
            end else begin
                chk(sdram.n_stale == 0, "con el Z80 parado la SDRAM se sigue refrescando (ninguna fila caducada)");
                chk(sdram.max_ref_gap < 15600.0, "nunca pasan 15,6 us sin refresco");
                chk(n_bad_a == 0, "las lecturas de la CPU tras la parada son correctas");
            end
            chk(sdram.n_err == 0, "el modelo de SDRAM no vio ordenes ilegales");
            $display("RESULTADO: %s (%0d errores)", errors == 0 ? "PASS" : "FAIL", errors);
            $finish;
        end

        // ---------------- MODE 0: traffic ----------------
        if (CPU_ON) cpu_run = 1'b1;
        #1500000;
        c_push0 = u_pcm.c_push; c_tick0 = u_pcm.c_tick; c_rep0 = u_pcm.c_rep;
        t0 = $realtime; meas = 1'b1;
        #(MEAS_US * 1000.0);
        meas = 1'b0; t1 = $realtime;
        cpu_run = 1'b0; #5000;
        us = (t1 - t0) / 1000.0;
        ticks = (u_pcm.c_tick - c_tick0) & 16'hFFFF; push = (u_pcm.c_push - c_push0) & 16'hFFFF;
        reps = (u_pcm.c_rep - c_rep0) & 16'hFFFF;
        ratio = (ticks > 0) ? push / ticks : 0.0;
        if (PCM_ON) begin
            $display("AUDIO : ticks=%0.0f producidas=%0.0f ratio=%.4f repeticiones=%0.0f", ticks, push, ratio, reps);
            $display("MOTOR : stall=%.2f%%  ops=%.3f Mops/s", 100.0*n_stall/(n_cyc>0?n_cyc:1), n_req/us);
            $display("LATENC: op W (mem_req->done) min/media/max = %0d / %.2f / %0d ciclos de 36 MHz = %.0f / %.0f / %.0f ns",
                lat_min, 1.0*lat_sum/(lat_n>0?lat_n:1), lat_max, lat_min*27.778, 27.778*lat_sum/(lat_n>0?lat_n:1), lat_max*27.778);
            $display("ARB   : espera W (W_HAVE) media/max = %.2f / %0d ciclos de 108 MHz (n=%0d)", 1.0*wp_sum/(wp_n>0?wp_n:1), wp_max, wp_n);
        end
        $display("CPU   : lecturas n=%0d cmd_en->ack min/media/max = %0d / %.2f / %0d ciclos (%.0f / %.0f / %.0f ns)  escritura max=%0d ciclos",
            cl_n, cl_min, 1.0*cl_sum/(cl_n>0?cl_n:1), cl_max, cl_min*9.259, 9.259*cl_sum/(cl_n>0?cl_n:1), cl_max*9.259, cw_max);
        $display("SDRAM : ops W=%.3f M/s  ops A=%.3f M/s  refrescos=%.3f M/s (propios %0d)  err_modelo=%0d caducadas=%0d",
            n_wops/us, n_aops/us, n_ref/us, n_own, sdram.n_err, sdram.n_stale);
        $display("DATOS : ordenes CPU perdidas=%0d  lecturas CPU=%0d (malas %0d, X %0d)  escrituras CPU=%0d  lecturas W=%0d (malas %0d)",
            n_drop, n_chk_a, n_bad_a, n_xa, n_wcpu, n_chk_w, n_bad_w);
        $write("HIST  :"); for (hi = 0; hi < 64; hi = hi + 1) if (cl_hist[hi] != 0) $write(" %0d:%0d", hi, cl_hist[hi]); $write("\n");
        chk(n_drop == 0, "ninguna orden de la CPU se pierde");
        chk(n_bad_a == 0 && n_xa == 0, "cada lectura de la CPU devuelve lo ultimo escrito en esa palabra");
        chk(n_bad_w == 0, "cada lectura de ondas devuelve la palabra de su direccion traducida");
        chk(sdram.n_err == 0 && sdram.n_stale == 0, "SDRAM sin ordenes ilegales ni filas caducadas");
        if (CPU_ON) chk(cl_n > 100, "hay trafico de CPU medido");
        $display("RESULTADO: %s (%0d errores)", errors == 0 ? "PASS" : "FAIL", errors);
        $finish;
    end
endmodule
`default_nettype wire
