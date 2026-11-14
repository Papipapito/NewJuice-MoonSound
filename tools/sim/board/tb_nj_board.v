// ============================================================================
// tb_nj_board.v - the WHOLE New Juice V9990 fork on a WonderTANG 2.0b/2.02b.
//
// The real top (src/top.v and everything in new-juice.gprj, converted with
// sv2v), Gowin's simulation primitives (rPLL, BUFG, DFF, ...), wired BY PIN
// NUMBER (wrapper generated from src/top.cst) to MoonTANG's board model
// (wt20x_board.v: multiplexed bus, transceiver, NPN /WAIT and /INT, I2S
// amplifier, SPI flash), the embedded SDRAM model with its retention check and
// a Z80 bus-functional model with Z80A timing at the slot.
//
// The V9990 (tiny9990, ports 60h-6Fh) has its VRAM in the SDRAM at byte
// 0x780000-0x7FFFFF. The flash holds a ramp where New Juice expects Nextor; no
// copyrighted ROM is used. DVI_TX_Top (Gowin's encrypted IP) is a stub: the
// video is looked at where it enters it (video_nj.vh).
//
// Simulation shortcuts (run_board.sh patches the converted netlist, the RTL is
// untouched): the automatic S1 pulse comes after 2000 clocks instead of 250 ms,
// the SDRAM start-up test covers 256 words instead of 64K, New Juice copies
// 2 KB of ROM instead of 160 KB, and the video PLL is held in reset except in
// the video mode (WITH_VIDEO). The VRAM is cleared through the model's memory
// before the start (the real chip's VRAM is undefined; here a display of X
// would hide what is checked).
//
// Bus timing at the slot pins: every read the bench makes is logged with the
// moments, counted from its /MREQ or /IORQ, at which the transceiver turns
// towards the slot (DATADIR), /BUSDIR falls, the data at the slot settles and
// /WAIT falls (`+cyclog=<file>`, one line per bus cycle).
//
// SHORT = 1 (negative controls): only boot, registers, VRAM and CPU traffic
// against the V9990 with its display on.
// ============================================================================
`timescale 1ns/1ps
`define V9 fpga.u_top.v9990_inst

module tb_nj_board;
    parameter integer QUIET = 0;
    parameter integer SHORT = 0;
    parameter integer LATONLY = 0;   // 1 = boot, registers, VRAM, mapper/MegaRAM/ROM set-up and the read latency of section L

    real TH = 139.6825;                       // half period of the MSX clock (3.58 MHz)
    // /MREQ and /RD fall tDL after the clock edge: 70 ns on a Z80A at 3.58 MHz;
    // on a turbo machine the CPU is faster (Z80H/R800-class), so the delay is
    // scaled with the half period (50 ns at 7.16 MHz, 60 ns at 5.37 MHz)
    function real tdl(input real th); tdl = (th < 80.0) ? 50.0 : (th < 100.0) ? 60.0 : 70.0; endfunction

    // ------------------------------------------------------------------
    //  The MSX
    // ------------------------------------------------------------------
    reg        msx_on = 1'b0;
    reg        psg_was_x = 1'b0, opll_was_x = 1'b0;
    reg [15:0] sat_pos, sat_neg;
    integer    spk_pos, spk_neg;
    reg        clk358 = 1'b0;
    always #(TH) if (msx_on) clk358 = ~clk358; else clk358 = 1'b0;

    reg [15:0] a       = 16'h0000;
    reg [7:0]  d_out   = 8'h00;
    reg        d_oe    = 1'b0;
    reg        mreq_n  = 1'b0, iorq_n = 1'b0, rd_n = 1'b0, wr_n = 1'b0;
    reg        reset_n = 1'b0, m1_n = 1'b0, rfsh_n = 1'b0;
    reg        sltsl_n = 1'b0;
    tri1 [7:0] s_d;
    assign     s_d = d_oe ? d_out : 8'hzz;
    tri1       s_wait_n, s_int_n;
    wire       s_busdir_n;

    // ------------------------------------------------------------------
    //  Board + FPGA
    // ------------------------------------------------------------------
    wire [88:1] pin;
    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [31:0] sd_dq;
    wire [10:0] sd_a;
    wire [1:0]  sd_ba;
    wire [3:0]  sd_dqm;

    GSR GSR (.GSRI(1'b1));

    // buttons S1/S2 released (pull-downs on the Tang), microSD absent (pull-ups)
    pulldown (pin[88]); pulldown (pin[87]);
    pullup (pin[82]); pullup (pin[84]);

    nj_pins fpga (
        .pin(pin),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_cas_n(sd_cas_n), .O_sdram_wen_n(sd_we_n),
        .IO_sdram_dq(sd_dq), .O_sdram_addr(sd_a), .O_sdram_ba(sd_ba), .O_sdram_dqm(sd_dqm)
    );

    sdram_model #(.RET_CHECK(1)) sdram (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .addr(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq)
    );

    // VRAM cleared (the model's memory is born X)
    integer ib;
    initial for (ib = 0; ib < 131072; ib = ib + 1) sdram.mem[21'h1E0000 + ib] = 32'd0;

    wire signed [15:0] spk, i2s_l, i2s_r;
    wire        i2s_frame, led, cart_drives_d;
    wt20x_board board (
        .pin(pin),
        .s_a(a), .s_d(s_d),
        .s_mreq_n(mreq_n), .s_iorq_n(iorq_n), .s_rd_n(rd_n), .s_wr_n(wr_n),
        .s_reset_n(reset_n), .s_m1_n(m1_n), .s_rfsh_n(rfsh_n),
        .s_cs1_n(1'b1), .s_cs2_n(1'b1), .s_cs12_n(1'b1),
        .s_sltsl_n(sltsl_n), .s_clock(clk358),
        .s_wait_n(s_wait_n), .s_int_n(s_int_n), .s_busdir_n(s_busdir_n),
        .spk(spk), .i2s_l(i2s_l), .i2s_r(i2s_r), .i2s_frame(i2s_frame),
        .led(led), .cart_drives_d(cart_drives_d)
    );

`ifndef WITH_VIDEO
    // the picture is not exercised here: keep the video PLL in reset
    // (run_board.sh video compiles with WITH_VIDEO: see video_nj.vh)
    initial force fpga.u_top.rpll_video_inst.reset = 1'b1;
`endif

    // ------------------------------------------------------------------
    //  Scoring
    // ------------------------------------------------------------------
    integer errors = 0, checks = 0;
    task fin;
        begin
            $display("== %0d comprobaciones, %0d errores ==", checks, errors);
            if (errors == 0) $display("RESULTADO: PASS");
            else             $display("RESULTADO: FAIL");
            $finish;
        end
    endtask
    task ok(input cond, input [1023:0] what);
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", what);
            end
            else if (!QUIET) $display("  [ok]   %0s", what);
        end
    endtask

    // ------------------------------------------------------------------
    //  Data bus watchdog: the board may drive D0-D7 only in a read cycle of
    //  this cartridge (an I/O read of one of its ports: 60h-6Fh and the mapper
    //  FCh-FFh, or a memory read with /SLTSL), with the MSX alive.
    // ------------------------------------------------------------------
    wire [7:0] port = a[7:0];
    wire io_ours = (port[7:4] == 4'h6) || (port[7:2] == 6'b111111);
    wire legit_rd = msx_on && reset_n && !rd_n &&
                    ((!iorq_n && m1_n && io_ours) || (!mreq_n && !sltsl_n));
    // With the MSX off every slot line sits at 0, so /RD = /SLTSL = 0 and New
    // Juice (unchanged, cd_demux.v) turns the transceiver towards the slot even
    // though it puts nothing on the bus. That is upstream behaviour, counted
    // apart as information; what must hold is that the FPGA never drives cd
    // and the V9990 never claims a read while the MSX is off.
    integer bad_drive = 0, nj_dir_off = 0, ours_off = 0;
    reg     drive_seen = 1'b0;
    always @(posedge cart_drives_d) if (!msx_on) nj_dir_off = nj_dir_off + 1;
    always @(posedge `V9.rd_active) if (!msx_on) ours_off = ours_off + 1;
    always @(posedge fpga.u_top.data_out_en) if (!msx_on) ours_off = ours_off + 1;
    always @(posedge cart_drives_d) if (msx_on) begin
        drive_seen = 1'b1;
        if (!legit_rd) begin
            bad_drive = bad_drive + 1;
            $display("  [FAIL %0t] the board drives D0-D7 outside one of its reads: A=%04x iorq=%b rd=%b mreq=%b sltsl=%b on=%b",
                     $time, a, iorq_n, rd_n, mreq_n, sltsl_n, msx_on);
        end
    end
    integer bad_busdir = 0;
    // /BUSDIR follows the drive for I/O reads (memory reads use /SLTSL instead)
    always @(cart_drives_d) #20 if (msx_on && cart_drives_d && !iorq_n && s_busdir_n !== 1'b0) begin
        bad_busdir = bad_busdir + 1;
        if (bad_busdir <= 5) $display("  [FAIL %0t] D0-D7 driven in an I/O read without /BUSDIR: A=%04x rd=%b m1=%b", $time, a, rd_n, m1_n);
    end

    // ------------------------------------------------------------------
    //  Bus timing at the slot pins, and the per-cycle log
    // ------------------------------------------------------------------
    // last moment the transceiver turned towards the slot, /BUSDIR fell, the
    // slot data changed and /WAIT fell (board outputs, after the board model)
    realtime t_dir_on = 0, t_bd_on = 0, t_sd_chg = 0, t_wait_on = 0, t_wait_off = 0;
    always @(posedge cart_drives_d) t_dir_on = $realtime;
    always @(negedge s_busdir_n)    t_bd_on = $realtime;
    always @(s_d)                   t_sd_chg = $realtime;
    always @(negedge s_wait_n)      t_wait_on = $realtime;
    always @(posedge s_wait_n)      t_wait_off = $realtime;
    // time of an event in this cycle counted from the strobe t0, -1 if none
    function real rel(input real t, input real t0); rel = (t >= t0) ? t - t0 : -1.0; endfunction
    // the data at the slot is settled from the later of its last change and
    // the moment the board starts driving it
    function real rel_data(input real t0);
        rel_data = cart_drives_d ? (((t_sd_chg > t_dir_on) ? t_sd_chg : t_dir_on) - t0) : -1.0;
    endfunction
    integer cyc_f = 0, cyc_n = 0;
    reg [1023:0] cyc_name;
    initial if ($value$plusargs("cyclog=%s", cyc_name)) cyc_f = $fopen(cyc_name, "w");
    // kind address data wait-states DATADIR BUSDIR data /WAIT, times in ns
    task cyc_log(input [8*8-1:0] kind, input [15:0] adr, input [7:0] v, input integer tw,
                 input real dr, input real bd, input real dt, input real wt);
        begin
            cyc_n = cyc_n + 1;
            if (cyc_f != 0)
                $fdisplay(cyc_f, "%0d %0s %04x %02x tw=%0d TH=%0.1f dir=%0.3f bd=%0.3f dat=%0.3f wt=%0.3f",
                          cyc_n, kind, adr, v, tw, TH, dr, bd, dt, wt);
        end
    endtask

    // ------------------------------------------------------------------
    //  Z80 bus cycles (Z80A timing)
    // ------------------------------------------------------------------
    integer  last_tw;
    realtime t_iorq, t_mreq;
    reg      wait_early, waiting;
    integer  setup_viol = 0, wait_rel_amb = 0;

    // /WAIT of P#0 and P#1 at the slot pins: counted from /IORQ to the falling
    // edge, and how long it stays down (falling edge to rising edge, NPN
    // turn-on 60 ns and turn-off 300 ns of the board included)
    integer  wn = 0, wn_none = 0;
    real     wl_max = 0, wl_min = 1.0e9, wd_max = 0, wd_min = 1.0e9, wd_sum = 0;
    task wstat_clear;
        begin wn = 0; wn_none = 0; wl_max = 0; wl_min = 1.0e9; wd_max = 0; wd_min = 1.0e9; wd_sum = 0; end
    endtask
    task wstat_rec(input [15:0] p);
        real lat, dur;
        begin
            if (p[7:4] == 4'h6 && p[3:0] < 4'd2) begin
                if (t_wait_on >= t_iorq && t_wait_off > t_wait_on) begin
                    lat = t_wait_on - t_iorq; dur = t_wait_off - t_wait_on;
                    wn = wn + 1; wd_sum = wd_sum + dur;
                    if (lat > wl_max) wl_max = lat;
                    if (lat < wl_min) wl_min = lat;
                    if (dur > wd_max) wd_max = dur;
                    if (dur < wd_min) wd_min = dur;
                end
                else wn_none = wn_none + 1;
            end
        end
    endtask

    task m1_fetch(input [15:0] pc, input [7:0] opcode);
        begin
            @(posedge clk358); #100 a = pc; m1_n = 1'b0;
            @(negedge clk358); #80 mreq_n = 1'b0; rd_n = 1'b0;
            @(posedge clk358); #60 d_out = opcode; d_oe = 1'b1;
            @(posedge clk358); #90 mreq_n = 1'b1; rd_n = 1'b1; m1_n = 1'b1;
            #20 d_oe = 1'b0; a = {8'h12, 8'h7F}; rfsh_n = 1'b0;
            @(negedge clk358); #80 mreq_n = 1'b0;
            @(posedge clk358);
            @(negedge clk358); #80 mreq_n = 1'b1;
            @(posedge clk358); #80 rfsh_n = 1'b1;
        end
    endtask

    task io_wait_states;
        begin
            @(posedge clk358);
            last_tw = 0; waiting = 1'b1;
            while (waiting) begin
                #(TH - 70.0) wait_early = s_wait_n;
                @(negedge clk358);
                if (wait_early !== s_wait_n) begin
                    if (wait_early === 1'b0 && s_wait_n === 1'b1) wait_rel_amb = wait_rel_amb + 1;
                    else begin
                        setup_viol = setup_viol + 1;
                        $display("  [FAIL %0t] /WAIT changed inside tS(WAIT) = 70 ns: %b -> %b (port %02x, %0.0f ns after /IORQ)",
                                 $time, wait_early, s_wait_n, a[7:0], $realtime - t_iorq);
                    end
                end
                if (s_wait_n === 1'b0) begin
                    last_tw = last_tw + 1;
                    @(posedge clk358);
                end
                else waiting = 1'b0;
            end
        end
    endtask

    task io_wr(input [15:0] p, input [7:0] v);
        begin
            m1_fetch(16'h4000, 8'hD3);
            @(posedge clk358); #110 a = p;
            @(negedge clk358); #100 d_out = v; d_oe = 1'b1;
            @(posedge clk358); #75 iorq_n = 1'b0; #5 wr_n = 1'b0; t_iorq = $realtime;
            io_wait_states;
            wstat_rec(p);
            cyc_log("IO_WR", p, v, last_tw, -1.0, -1.0, -1.0, rel(t_wait_on, t_iorq));
            @(posedge clk358);
            @(negedge clk358); #80 wr_n = 1'b1; iorq_n = 1'b1;
            #60 d_oe = 1'b0;
        end
    endtask

    reg [7:0] rdv, rd_early;
    reg       rd_driven;
    task io_rd(input [15:0] p);
        begin
            m1_fetch(16'h4002, 8'hDB);
            @(posedge clk358); #110 a = p;
            @(posedge clk358); #75 iorq_n = 1'b0; #10 rd_n = 1'b0; t_iorq = $realtime;
            io_wait_states;
            wstat_rec(p);
            @(posedge clk358);
            #(TH - 50.0) rd_early = s_d;
            @(negedge clk358);
            rdv = s_d; rd_driven = cart_drives_d;
            if (rd_driven && (rd_early !== rdv || ^rdv === 1'bx)) begin
                setup_viol = setup_viol + 1;
                $display("  [FAIL %0t] data unstable at the Z80 sample point: %02x -> %02x", $time, rd_early, rdv);
            end
            cyc_log("IO_RD", p, rdv, last_tw, rel(t_dir_on, t_iorq), rel(t_bd_on, t_iorq),
                    rel_data(t_iorq), rel(t_wait_on, t_iorq));
            #85 iorq_n = 1'b1; rd_n = 1'b1; t_rd_up = $realtime;
        end
    endtask

    // time from /RD going up to the board releasing D0-D7 and /BUSDIR
    realtime t_rd_up = 0, t_rel_d = 0, t_rel_bd = 0;
    always @(negedge cart_drives_d) if (msx_on) t_rel_d  = $realtime;
    always @(posedge s_busdir_n)    if (msx_on) t_rel_bd = $realtime;
    real rel_ours, rel_nj, rel_ours_in, rel_nj_in;
    // New Juice sees /RD through its bus debouncer, whose delay depends on
    // the phase of /RD against the 108 MHz clock; rel_in is measured from
    // the moment the design's own /RD (u_top.rd_n) goes up
    realtime t_rdn_in = 0;
    always @(posedge fpga.u_top.rd_n) if (msx_on) t_rdn_in = $realtime;
    task release_time(input [15:0] p, output real rel, output real rel_in);
        begin
            io_rd(p);
            #400;
            rel = ((t_rel_d > t_rel_bd) ? t_rel_d : t_rel_bd) - t_rd_up;
            rel_in = ((t_rel_d > t_rel_bd) ? t_rel_d : t_rel_bd) - t_rdn_in;
        end
    endtask

    // memory cycles to this cartridge's slot (/SLTSL follows /MREQ)
    // t_pin_max / t_dir_max: the same read seen at the slot pins (data
    // settled, transceiver turned), only for reads that return the right byte
    real     t_pin_max = 0, t_dir_max = 0, t_pin, t_dir;
    real     t_valid, t_valid_max;
    integer  dbg_rd = 0;
    reg [7:0] exp_rd;
    integer  mem_bad = 0;
    reg      rd_m1 = 1'b0;                        // 1 = mem_rd with /M1 low (an instruction fetch from the slot)
    integer  lt_n = 0, lt_f4 = 0, lt_f3 = 0, lt_f5 = 0, lt_nodata = 0;
    real     lt_max = 0;
    task lt_clear; begin lt_n = 0; lt_f4 = 0; lt_f3 = 0; lt_f5 = 0; lt_nodata = 0; lt_max = 0; mem_bad = 0; end endtask
    // moment the FPGA puts the expected byte on its cd pins during the read
    // (+8 ns of board: clock-to-pad and transceiver); the Z80 sample itself
    // is checked at the sample point, with alternating bytes so that a stale
    // value cannot pass for a good one
    always @(posedge fpga.u_top.main_clk)
        if (!mreq_n && !rd_n && !sltsl_n && t_valid > 1.0e8 &&
            fpga.u_top.data_out_en === 1'b1 && fpga.u_top.data_out === exp_rd)
            t_valid = $realtime - t_mreq + 8.0;
    task mem_wr(input [15:0 ] adr, input [7:0] v);
        begin
            m1_fetch(16'h0100, 8'h77);                 // LD (HL),A from the system ROM
            @(posedge clk358); #100 a = adr;
            @(negedge clk358); #70 mreq_n = 1'b0; t_mreq = $realtime; #20 sltsl_n = 1'b0; d_out = v; d_oe = 1'b1;
            @(negedge clk358); #70 wr_n = 1'b0;        // T2 falling
            @(posedge clk358);
            cyc_log("MEM_WR", adr, v, 0, -1.0, -1.0, -1.0, rel(t_wait_on, t_mreq));
            @(negedge clk358); #70 wr_n = 1'b1; mreq_n = 1'b1; #20 sltsl_n = 1'b1;
            #40 d_oe = 1'b0;
        end
    endtask
    task mem_rd(input [15:0] adr, input [7:0] expect_v);
        begin
            m1_fetch(16'h0100, 8'h7E);                 // LD A,(HL)
            exp_rd = expect_v; t_valid = 1.0e9;
            @(posedge clk358); #100 a = adr; if (rd_m1) m1_n = 1'b0;
            // /SLTSL follows 20 ns later (slot decoder); scheduled without
            // blocking so that the T2 edge is not missed at 7.16 MHz
            @(negedge clk358); #(tdl(TH)) mreq_n = 1'b0; rd_n = 1'b0; t_mreq = $realtime; sltsl_n <= #20 1'b0;
            @(posedge clk358);                        // T2
            @(posedge clk358);                        // T3
            #(TH - 30.0) rd_early = s_d;              // tS(D) = 30 ns (Z80A)
            @(negedge clk358);                        // T3 falling: the Z80 samples
            rdv = s_d; rd_driven = cart_drives_d;
            if (dbg_rd > 0) begin
                dbg_rd = dbg_rd - 1;
                $display("         [dbg] lectura %04x: /MREQ en %0.1f ns, muestreo a +%0.1f ns, dato %02x (antes %02x), esperado %02x, FPGA valido a +%0.1f ns",
                         adr, t_mreq, $realtime - t_mreq, rdv, rd_early, expect_v, t_valid);
            end
            if (rdv !== expect_v || rd_early !== rdv) begin
                mem_bad = mem_bad + 1;
                if (mem_bad <= 3) $display("         [info %0t] lectura de %04x: %02x (antes %02x), esperado %02x", $time, adr, rdv, rd_early, expect_v);
            end
            if (t_valid < 1.0e8 && t_valid > t_valid_max) t_valid_max = t_valid;
            t_pin = rel_data(t_mreq); t_dir = rel(t_dir_on, t_mreq);
            if (rdv === expect_v && rd_early === rdv) begin
                if (t_pin > t_pin_max) t_pin_max = t_pin;
                if (t_dir > t_dir_max) t_dir_max = t_dir;
            end
            cyc_log("MEM_RD", adr, rdv, 0, t_dir, rel(t_bd_on, t_mreq), t_pin, rel(t_wait_on, t_mreq));
            // settling of the data at the slot pins against what the Z80 allows: a normal read
            // 4 half periods after the clock edge before /MREQ, an M1 fetch 3 (Z80 alone) or 5
            // (with the wait state every MSX adds to M1), minus tDL and tS(D) = 30 ns
            if (t_pin >= 0) begin
                lt_n = lt_n + 1;
                if (t_pin > lt_max) lt_max = t_pin;
                if (t_pin > 4.0 * TH - tdl(TH) - 30.0) lt_f4 = lt_f4 + 1;
                if (t_pin > 3.0 * TH - tdl(TH) - 30.0) lt_f3 = lt_f3 + 1;
                if (t_pin > 5.0 * TH - tdl(TH) - 30.0) lt_f5 = lt_f5 + 1;
            end
            else lt_nodata = lt_nodata + 1;
            #70 mreq_n = 1'b1; rd_n = 1'b1; #20 sltsl_n = 1'b1; m1_n = 1'b1;
        end
    endtask

    // I/O read with the Z80's timing scaled to the clock (TH): /IORQ and /RD
    // tDL after T2 rises, /WAIT sampled when TW falls, data when T3 falls.
    // It only measures: a late /WAIT at 5.37 or 7.16 MHz is not a failure
    // here (it is reported), so it does not count in setup_viol.
    real io_dir, io_bd, io_dat, io_wt;
    integer io_tw;
    task io_rd_t(input [15:0] p);
        begin
            m1_fetch(16'h4002, 8'hDB);
            @(posedge clk358); #(tdl(TH)) a = p;                       // T1
            @(posedge clk358); #(tdl(TH)) iorq_n = 1'b0; rd_n = 1'b0;  // T2
            t_iorq = $realtime;
            @(posedge clk358);                                        // TW
            @(negedge clk358);
            io_tw = 1;
            while (s_wait_n === 1'b0) begin @(posedge clk358); @(negedge clk358); io_tw = io_tw + 1; end
            @(posedge clk358);                                        // T3
            @(negedge clk358);
            rdv = s_d; rd_driven = cart_drives_d;
            io_dir = rel(t_dir_on, t_iorq); io_bd = rel(t_bd_on, t_iorq);
            io_dat = rel_data(t_iorq); io_wt = rel(t_wait_on, t_iorq);
            wstat_rec(p);
            cyc_log("IO_RDT", p, rdv, io_tw, io_dir, io_bd, io_dat, io_wt);
            #(tdl(TH)) iorq_n = 1'b1; rd_n = 1'b1;
            #200;
        end
    endtask
    // the same for an OUT: the byte is on the bus from T1; /WAIT is looked at
    // when TW falls and the Z80 lets go of /WR after T3
    task io_wr_t(input [15:0] p, input [7:0] v);
        begin
            m1_fetch(16'h4000, 8'hD3);
            @(posedge clk358); #(tdl(TH)) a = p;                       // T1
            @(negedge clk358); d_out = v; d_oe = 1'b1;
            @(posedge clk358); #(tdl(TH)) iorq_n = 1'b0; wr_n = 1'b0;  // T2
            t_iorq = $realtime;
            @(posedge clk358);                                        // TW
            @(negedge clk358);
            io_tw = 1;
            while (s_wait_n === 1'b0) begin @(posedge clk358); @(negedge clk358); io_tw = io_tw + 1; end
            @(posedge clk358);                                        // T3
            @(negedge clk358);
            io_wt = rel(t_wait_on, t_iorq);
            wstat_rec(p);
            cyc_log("IO_WRT", p, v, io_tw, -1.0, -1.0, -1.0, io_wt);
            #(tdl(TH)) iorq_n = 1'b1; wr_n = 1'b1;
            #(tdl(TH)) d_oe = 1'b0;
            #200;
        end
    endtask

    function [7:0] sd_byte(input [22:0] sb);
        reg [31:0] w;
        begin w = sdram.mem[sb[22:2]]; sd_byte = w[8*sb[1:0] +: 8]; end
    endfunction

    task expect_silence(input [15:0] p, input [1023:0] what);
        begin
            drive_seen = 1'b0;
            io_rd(p);
            ok(!drive_seen && rdv === 8'hFF, what);
        end
    endtask

    // ------------------------------------------------------------------
    //  Clock measurement
    // ------------------------------------------------------------------
    task measure(input integer which, output real mhz);
        realtime t0, t1;
        integer  n;
        begin
            case (which)
                0: begin @(posedge fpga.u_top.main_clk); t0 = $realtime; for (n = 0; n < 200; n = n + 1) @(posedge fpga.u_top.main_clk); t1 = $realtime; end
                default: begin @(posedge pin[56]); t0 = $realtime; for (n = 0; n < 200; n = n + 1) @(posedge pin[56]); t1 = $realtime; end
            endcase
            mhz = 200.0 * 1000.0 / (t1 - t0);
        end
    endtask
    function near(input real v, input real target, input real tol);
        near = (v > target * (1.0 - tol)) && (v < target * (1.0 + tol));
    endfunction

    // I2S as the MAX98357A takes it (sampled on BCLK rising edges): the MSB
    // one BCLK after the LRCLK edge, the LSB on the next LRCLK edge. Mono =
    // both halves of a frame equal; every word must also be one of the last
    // mix snapshots taken for audio_drive (exact value, no shift or wrap).
    integer n_frames = 0;
    always @(i2s_frame) n_frames = n_frames + 1;
    reg        i2s_ws_q = 1'b0;
    reg [15:0] i2s_sh = 16'd0, i2s_first = 16'd0, i2s_word;
    integer    i2s_nb = 99, i2s_frames = 0, i2s_lr_bad = 0, i2s_val_bad = 0;
    reg [15:0] hold_h0 = 16'd0, hold_h1 = 16'd0, hold_h2 = 16'd0, hold_h3 = 16'd0;
    always @(fpga.u_top.audio_sample_hold) begin
        hold_h3 = hold_h2; hold_h2 = hold_h1; hold_h1 = hold_h0; hold_h0 = fpga.u_top.audio_sample_hold;
    end
    always @(posedge pin[56]) begin
        if (pin[55] !== i2s_ws_q) begin
            if (i2s_nb == 15) begin
                i2s_word = {i2s_sh[14:0], pin[54]};
                if (i2s_word !== hold_h0 && i2s_word !== hold_h1 && i2s_word !== hold_h2 && i2s_word !== hold_h3)
                    i2s_val_bad = i2s_val_bad + 1;
                if (i2s_ws_q === 1'b0) i2s_first = i2s_word;    // half with LRCLK low
                else begin
                    i2s_frames = i2s_frames + 1;
                    if (i2s_word !== i2s_first) i2s_lr_bad = i2s_lr_bad + 1;
                end
            end
            i2s_ws_q = pin[55];
            i2s_sh = 16'd0;
            i2s_nb = 0;
        end else if (i2s_nb < 15) begin
            i2s_sh = {i2s_sh[14:0], pin[54]};
            i2s_nb = i2s_nb + 1;
        end
    end

    // ------------------------------------------------------------------
    //  SDRAM accounting: every command that leaves the arbiter towards the
    //  controller by client (CPU through the adapter, V9990 through its port)
    //  against every WRITE the model sees by region. The V9990 owns the words
    //  from 0x1E0000 (byte 0x780000); the CPU never touches them.
    // ------------------------------------------------------------------
    integer n_cpu_rd = 0, n_cpu_wr = 0, n_cpu_hi = 0;       // CPU commands; hi = address in the VRAM area
    integer n_v_rd = 0, n_v_wr = 0, n_v_lo = 0;             // V9990 commands (words); lo = address outside the VRAM area
    integer n_pin_wr_lo = 0, n_pin_wr_hi = 0, n_pin_rd_hi = 0;
    always @(posedge fpga.u_top.main_clk) begin
        if (fpga.u_top.native_sdram_wr) begin
            n_cpu_wr = n_cpu_wr + 1;
            if (fpga.u_top.native_sdram_addr >= 23'h780000) n_cpu_hi = n_cpu_hi + 1;
        end
        if (fpga.u_top.native_sdram_rd) begin
            n_cpu_rd = n_cpu_rd + 1;
            if (fpga.u_top.native_sdram_addr >= 23'h780000) n_cpu_hi = n_cpu_hi + 1;
        end
        if (fpga.u_top.arb_s_v_wr) begin
            n_v_wr = n_v_wr + (fpga.u_top.arb_s_v_dbl ? 2 : 1);
            if (fpga.u_top.arb_s_v_addr[20:17] != 4'b1111) n_v_lo = n_v_lo + 1;
        end
        if (fpga.u_top.arb_s_v_rd) begin
            n_v_rd = n_v_rd + (fpga.u_top.arb_s_v_dbl ? 2 : 1);
            if (fpga.u_top.arb_s_v_addr[20:17] != 4'b1111) n_v_lo = n_v_lo + 1;
        end
    end
    always @(posedge sd_clk) if (sdram.cke && sdram.cmd == 4'b0100) begin
        if (sdram.widx >= 21'h1E0000) n_pin_wr_hi = n_pin_wr_hi + 1;
        else                          n_pin_wr_lo = n_pin_wr_lo + 1;
    end

    // ------------------------------------------------------------------
    //  V9990 on the Z80
    // ------------------------------------------------------------------
    // vsh: the byte each SDRAM position of the VRAM area (offset from 0x780000)
    // must hold, from what the Z80 wrote through P#0 (0 from the clear)
    reg [7:0] vsh [0:524287];
    integer   iv;
    initial for (iv = 0; iv < 524288; iv = iv + 1) vsh[iv] = 8'h00;
    // SDRAM offset of a VRAM byte address: Bx linear, P1 with the two VRAMs
    // interleaved (VRAM0 even, VRAM1 odd bytes)
    function [18:0] vmap(input [18:0] va, input p1);
        vmap = p1 ? {va[17:0], va[18]} : va;
    endfunction
    integer vbad = 0, vsdbad = 0;

    task vo(input [3:0] p, input [7:0] v); io_wr({8'h00, 4'h6, p}, v); endtask
    task vi(input [3:0] p); io_rd({8'h00, 4'h6, p}); endtask
    task vreg_w(input [5:0] r, input [7:0] v); begin vo(4'd4, {2'b00, r}); vo(4'd3, v); end endtask
    task vreg_r(input [5:0] r); begin vo(4'd4, {2'b00, r}); vi(4'd3); end endtask
    // VRAM write address R#0-R#2 and read address R#3-R#5 through P#4 + P#3
    // (the register number auto-increments on each P#3 write)
    task vset_w(input [18:0] va);
        begin vo(4'd4, 8'd0); vo(4'd3, va[7:0]); vo(4'd3, va[15:8]); vo(4'd3, {5'b00000, va[18:16]}); end
    endtask
    task vset_r(input [18:0] va);
        begin vo(4'd4, 8'd3); vo(4'd3, va[7:0]); vo(4'd3, va[15:8]); vo(4'd3, {5'b00000, va[18:16]}); end
    endtask
    function [7:0] vdat(input [7:0] seed, input integer j);
        vdat = seed + j * 37 + (j >> 8) * 11;
    endfunction
    task vwr_blk(input [18:0] va, input integer n, input [7:0] seed, input p1);
        integer j;
        begin
            vset_w(va);
            for (j = 0; j < n; j = j + 1) begin
                vo(4'd0, vdat(seed, j));
                vsh[vmap(va + j, p1)] = vdat(seed, j);
            end
        end
    endtask
    task vrd_blk(input [18:0] va, input integer n, input [7:0] seed);
        integer j;
        begin
            vset_r(va);
            for (j = 0; j < n; j = j + 1) begin
                vi(4'd0);
                if (rdv !== vdat(seed, j)) begin
                    vbad = vbad + 1;
                    if (vbad <= 4) $display("         [info %0t] VRAM %05x: leido %02x, esperado %02x", $time, va + j, rdv, vdat(seed, j));
                end
            end
        end
    endtask
    // the SDRAM holds what the Z80 wrote (backdoor)
    task vsd_chk(input [18:0] va, input integer n, input p1);
        integer j;
        begin
            for (j = 0; j < n; j = j + 1)
                if (sd_byte(23'h780000 + vmap(va + j, p1)) !== vsh[vmap(va + j, p1)]) begin
                    vsdbad = vsdbad + 1;
                    if (vsdbad <= 4) $display("         [info] SDRAM %06x: %02x, esperado %02x (VRAM %05x)",
                                              23'h780000 + vmap(va + j, p1), sd_byte(23'h780000 + vmap(va + j, p1)),
                                              vsh[vmap(va + j, p1)], va + j);
                end
        end
    endtask

    // ------------------------------------------------------------------
    //  The test
    // ------------------------------------------------------------------
    integer i, k, polls, n0, speed, nrd, nbad, ls0, cfg, m1;
    reg [8*14-1:0] cname;
    real    f, t_rst, t_resp, t_ready, t_core;
    reg [7:0] exp;
    reg      int_seen;
    reg [8*12-1:0] sname;
    reg [7:0] pgv [0:3];
    realtime t_int0, t_int1;

    // reset response: when the modules are released and the V9990's own reset ends
    realtime t_ready_rise = 0, t_core_rise = 0;
    always @(posedge fpga.u_top.cpu_modules_ready_reg) t_ready_rise = $realtime;
    always @(posedge `V9.core_reset_n) t_core_rise = $realtime;

    // STATUS.BD and STATUS.BX (P#5 bit 4, R#53-R#54) have no reset in the core: only the
    // SRCH command writes them. On the FPGA a register powers up at 0 (GSR); in Icarus it
    // would read X until a SRCH ran, so the bench gives them that power-up value.
    initial begin
        #1;
        `V9.u_vdp.STATUS.BD = 1'b0;
        `V9.u_vdp.STATUS.BX = 11'd0;
    end

    // VRAM slots lost by the core (its own assertion, T9990_RAM)
    function integer lost_slots; input dummy; lost_slots = `V9.u_vdp.u_ram.lost_slots; endfunction

`ifdef WITH_VIDEO
`include "video_nj.vh"
`endif

    // CPU against the V9990, display on: mapper, MegaRAM and VRAM interleaved
    // (page 2 -> subslots 3 and 2 by FFFFh). The mapper pages differ, so each
    // write has its own SDRAM byte for the final check.
    integer tr_bad, tr_k;
    reg [7:0] tr_d, tr_d2;
    task traffic(input integer n, input p1, input [7:0] seed);
        begin
            tr_bad = 0; mem_bad = 0; vbad = 0;
            // the VRAM block the Z80 reads while the rest goes on
            vwr_blk(19'h02000, n, seed, p1);
            vset_r(19'h02000);
            vset_w(19'h03000);
            mem_wr(16'hFFFF, 8'h20); mem_wr(16'h8000, 8'h05); io_rd(16'h008E);   // MegaRAM: RAM mode, bank 5
            for (tr_k = 0; tr_k < n; tr_k = tr_k + 1) begin
                tr_d = seed + tr_k * 13 + 8'h21;
                tr_d2 = seed ^ (tr_k * 29) ^ 8'h6B;
                // mapper, page pgv[k%4], offset 0x200 + 5k
                mem_wr(16'hFFFF, 8'h30); io_wr(16'h00FE, pgv[tr_k % 4]);
                mem_wr(16'h8200 + 5 * tr_k, tr_d);
                mem_rd(16'h8200 + 5 * tr_k, tr_d);
                // V9990 write and read through P#0
                vo(4'd0, tr_d2); vsh[vmap(19'h03000 + tr_k, p1)] = tr_d2;
                vi(4'd0);
                if (rdv !== vdat(seed, tr_k)) begin vbad = vbad + 1; if (vbad <= 4) $display("         [info %0t] VRAM leida %02x, esperado %02x (k=%0d)", $time, rdv, vdat(seed, tr_k), tr_k); end
                // MegaRAM bank 5 at 0x8100 + 3k
                mem_wr(16'hFFFF, 8'h20);
                mem_wr(16'h8100 + 3 * tr_k, tr_d2);
                mem_rd(16'h8100 + 3 * tr_k, tr_d2);
            end
            mem_wr(16'hFFFF, 8'h20); io_wr(16'h008E, 8'h00);      // MegaRAM back to paging mode
            mem_wr(16'hFFFF, 8'h30);
            // what each write left in the SDRAM
            nbad = 0;
            for (tr_k = 0; tr_k < n; tr_k = tr_k + 1) begin
                tr_d = seed + tr_k * 13 + 8'h21;
                tr_d2 = seed ^ (tr_k * 29) ^ 8'h6B;
                if (sd_byte({pgv[tr_k % 4], 14'd0} + 16'h0200 + 5 * tr_k) !== tr_d) nbad = nbad + 1;
                if (sd_byte(23'h400000 + 23'h2000 * 5 + 23'h0100 + 3 * tr_k) !== tr_d2) nbad = nbad + 1;
            end
            vsd_chk(19'h02000, n, p1);
            vsd_chk(19'h03000, n, p1);
        end
    endtask

    initial begin
        pgv[0] = 8'h05; pgv[1] = 8'h85; pgv[2] = 8'hFF; pgv[3] = 8'h3C;
        // ==============================================================
        $display("== A. arranque con el MSX APAGADO (lineas del slot a 0, sin reloj) ==");
        a = 16'h6565; m1_n = 1'b1;
        wait (fpga.u_top.rpll_main_lock === 1'b1);
        wait (fpga.u_top.board_reset_n === 1'b1);
        measure(0, f); ok(near(f, 108.0, 0.002), "main_clk = 108 MHz");
        fork : arranque
            begin wait (fpga.u_top.startup_test_passed === 1'b1); disable arranque; end
            begin #60_000_000; disable arranque; end
        join
        ok(fpga.u_top.startup_test_passed === 1'b1, "el test de arranque de la SDRAM de New Juice pasa (con el arbitro delante)");
        if (SHORT && fpga.u_top.startup_test_passed !== 1'b1) fin;      // negative control: no point in going on
        $display("         test de SDRAM superado en t = %0.2f ms", $realtime / 1.0e6);
        fork : roms
            begin wait (fpga.u_top.flash_rom_loaded === 1'b1); disable roms; end
            begin #20_000_000; disable roms; end
        join
        ok(fpga.u_top.flash_rom_loaded === 1'b1, "New Juice copia sus ROM de la flash");
        $display("         ROM de New Juice copiadas en t = %0.2f ms", $realtime / 1.0e6);
        #100_000;
        ok(ours_off == 0, "MSX apagado con IORQ=RD=0 en 65h: la FPGA no pone nada en el bus (ni el V9990 ni New Juice)");
        $display("         [info] con el MSX apagado New Juice gira el transceptor hacia el slot %0d veces (/RD=/SLTSL=0; comportamiento de New Juice sin cambios)", nj_dir_off);
        ok(`V9.wait_n === 1'b1 && `V9.int_n === 1'b1, "MSX apagado: el V9990 no pide /WAIT ni /INT");
        $display("         [info] /WAIT del slot con el MSX apagado: %b (New Juice lo mantiene hasta soltar sus modulos tras el /RESET; sin cambios)", s_wait_n);

        // ==============================================================
        $display("== B. el MSX se enciende; el V9990 responde ==");
        mreq_n = 1'b1; iorq_n = 1'b1; rd_n = 1'b1; wr_n = 1'b1; m1_n = 1'b1; rfsh_n = 1'b1;
        sltsl_n = 1'b1; a = 16'h0000; reset_n = 1'b0;
        msx_on = 1'b1;
        #500_000 reset_n = 1'b1; t_rst = $realtime;
        // the Z80 starts at once: write R#16 and read it back until the V9990 answers
        polls = 0; rdv = 8'h00;
        while (rdv !== 8'hA5 && polls < 400) begin
            vo(4'd4, 8'd16); vo(4'd3, 8'hA5); vo(4'd4, 8'd16); vi(4'd3);
            polls = polls + 1;
        end
        t_resp = $realtime - t_rst;
        ok(rdv === 8'hA5, "el V9990 contesta tras el /RESET (R#16 escrito y leido)");
        $display("         [cifra] /RESET del MSX suelto -> New Juice suelta sus modulos a +%0.2f us -> reset interno del V9990 libre a +%0.2f us -> primera lectura correcta de un registro a +%0.1f us (%0d intentos del Z80)",
                 (t_ready_rise - t_rst) / 1000.0, (t_core_rise - t_rst) / 1000.0, t_resp / 1000.0, polls);
        fork : vivo
            begin wait (fpga.u_top.cpu_modules_ready_reg === 1'b1); disable vivo; end
            begin #8_000_000; disable vivo; end
        join
        #100_000;
        ok(fpga.u_top.cpu_modules_ready_reg === 1'b1, "New Juice suelta sus modulos (MSX vivo)");
        vreg_w(16, 8'h00);
`ifdef PROBE
        #20_000;
        $display("PROBE TR=%b VR=%b HR=%b BD=%b EO=%b CE=%b BX=%h", `V9.u_vdp.STATUS.TR, `V9.u_vdp.STATUS.VR, `V9.u_vdp.STATUS.HR, `V9.u_vdp.STATUS.BD, `V9.u_vdp.STATUS.EO, `V9.u_vdp.STATUS.CE, `V9.u_vdp.STATUS.BX);
        $finish;
`endif

        // ==============================================================
        $display("== C. V9990: registros (P#4 + P#3), puertos 60h-6Fh, bus ==");
        begin : c_regs
            integer r, bad, tot; reg [7:0] rv;
            bad = 0; tot = 0;
            for (r = 10; r <= 27; r = r + 1) if (r != 13 && r != 14) begin
                vreg_w(r[5:0], 8'h35 + r * 7);
            end
            for (r = 10; r <= 27; r = r + 1) if (r != 13 && r != 14) begin
                vreg_r(r[5:0]); tot = tot + 1;
                if (rdv !== ((8'h35 + r * 7) & 8'hFF) || !rd_driven) bad = bad + 1;
            end
            ok(bad == 0, "R#10-R#12 y R#15-R#27: cada registro se relee tal como se escribio");
            // auto-increment on P#3 write and read; no increment with P#4 bit 6 (read)
            vo(4'd4, 8'd16); vo(4'd3, 8'h11); vo(4'd3, 8'h22); vo(4'd3, 8'h33); vo(4'd3, 8'h44);
            vo(4'd4, 8'd16); bad = 0;
            vi(4'd3); if (rdv !== 8'h11) bad = bad + 1;
            vi(4'd3); if (rdv !== 8'h22) bad = bad + 1;
            vi(4'd3); if (rdv !== 8'h33) bad = bad + 1;
            vi(4'd3); if (rdv !== 8'h44) bad = bad + 1;
            ok(bad == 0, "el numero de registro se autoincrementa en cada acceso a P#3 (R#16-R#19)");
            vo(4'd4, 8'd17 | 8'h40); vi(4'd3); rv = rdv; vi(4'd3);
            ok(rv === 8'h22 && rdv === 8'h22, "P#4 bit 6: sin autoincremento en lectura");
            for (r = 10; r <= 27; r = r + 1) if (r != 13 && r != 14) vreg_w(r[5:0], 8'h00);
            vi(4'd5);
            ok(rd_driven && rdv[3] === 1'b0 && ^rdv !== 1'bx, "P#5 (estado): contesta, bit 3 a 0");
            bad = 0;
            vi(4'd8);  if (!rd_driven || rdv !== 8'hFF) bad = bad + 1;
            vi(4'd11); if (!rd_driven || rdv !== 8'hFF) bad = bad + 1;
            vi(4'd15); if (!rd_driven || rdv !== 8'hFF) bad = bad + 1;
            vi(4'd4);  if (!rd_driven || rdv !== 8'hFF) bad = bad + 1;
            vi(4'd7);  if (!rd_driven || rdv !== 8'hFF) bad = bad + 1;
            ok(bad == 0, "P#4, P#7 y P#8-P#15 se leen como FFh (con la placa conduciendo)");
        end
        expect_silence(16'h005F, "IN 5Fh (no es del V9990): silencio");
        expect_silence(16'h0070, "IN 70h (no es del V9990): silencio");
        expect_silence(16'h007C, "IN 7Ch (OPLL, solo escritura): silencio");
        expect_silence(16'h00C4, "IN C4h (MoonSound ya no esta): silencio");
        // the bus is let go when the read ends, like New Juice's own ports
        release_time(16'h0065, rel_ours, rel_ours_in);
        release_time(16'h00FE, rel_nj, rel_nj_in);
        $display("         suelta D0-D7 y /BUSDIR %0.0f ns tras subir /RD en 65h, %0.0f ns tras el /RD interno (New Juice en su puerto FEh: %0.0f / %0.0f ns)",
                 rel_ours, rel_ours_in, rel_nj, rel_nj_in);
        ok(s_busdir_n === 1'b1 && !cart_drives_d && rel_ours < rel_nj + 60.0 && rel_ours < 300.0,
           "al acabar la lectura suelta el bus y /BUSDIR (en el slot, como mucho 60 ns despues que New Juice)");
        ok(rel_ours_in < rel_nj_in + 5.0,
           "y lo suelta a la vez que New Juice en sus puertos, contado desde su /RD interno (+-5 ns)");
`ifdef WITH_VIDEO
        video_test;
        fin;
`endif

        // ==============================================================
        $display("== E. VRAM por P#0: bitmap B1 de 8 bpp y modo P1, /WAIT, posicion en la SDRAM ==");
        vreg_w(8, 8'h00);                                       // display off
        vreg_w(6, 8'h82);                                       // B1, 8 bpp, 256 de ancho: DSPM = bitmap
        wstat_clear; vbad = 0; vsdbad = 0;
        vwr_blk(19'h00000, 64, 8'h11, 1'b0);
        vwr_blk(19'h12340, 256, 8'h4D, 1'b0);
        vwr_blk(19'h7FFC0, 64, 8'hA3, 1'b0);
        vwr_blk(19'h3FFF0, 48, 8'h2F, 1'b0);                    // across the 0x40000 boundary
        $display("         /WAIT de las escrituras por P#0 (%0d): cae a +%0.0f..%0.0f ns de /IORQ, dura %0.0f..%0.0f ns (media %0.0f); %0d sin /WAIT",
                 wn, wl_min, wl_max, wd_min, wd_max, wd_sum / (wn ? wn : 1), wn_none);
        ok(wn_none == 0 && wn > 0, "toda escritura por P#0 levanta /WAIT");
        ok(wl_max < 270.0, "el /WAIT de P#0 llega al pin antes del muestreo del Z80 a 3,58 MHz (270 ns tras /IORQ)");
        wstat_clear;
        vrd_blk(19'h00000, 64, 8'h11);
        vrd_blk(19'h12340, 256, 8'h4D);
        vrd_blk(19'h7FFC0, 64, 8'hA3);
        vrd_blk(19'h3FFF0, 48, 8'h2F);
        $display("         /WAIT de las lecturas por P#0 (%0d): cae a +%0.0f..%0.0f ns de /IORQ, dura %0.0f..%0.0f ns (media %0.0f); %0d sin /WAIT",
                 wn, wl_min, wl_max, wd_min, wd_max, wd_sum / (wn ? wn : 1), wn_none);
        ok(wn_none == 0 && wn > 0, "toda lectura por P#0 levanta /WAIT");
        ok(wl_max < 270.0, "(lectura) el /WAIT de P#0 llega al pin antes del muestreo del Z80 a 3,58 MHz");
        ok(vbad == 0, "B1: 432 bytes escritos por P#0 se leen de vuelta por R#3-R#5 + P#0 (inicio, mitad, tope 7FFFFh, cruce de 40000h)");
        vsd_chk(19'h00000, 64, 1'b0); vsd_chk(19'h12340, 256, 1'b0); vsd_chk(19'h7FFC0, 64, 1'b0); vsd_chk(19'h3FFF0, 48, 1'b0);
        ok(vsdbad == 0, "B1: los bytes estan en la SDRAM en 0x780000 + direccion de VRAM (backdoor)");
        ok(sd_byte(23'h7FFFFF) === vsh[19'h7FFFF], "el ultimo byte de la VRAM esta en 0x7FFFFF");
        // P1: VRAM0 and VRAM1 interleaved
        vreg_w(6, 8'h00); vbad = 0; vsdbad = 0;
        vwr_blk(19'h00100, 64, 8'h65, 1'b1);
        vwr_blk(19'h3FFE0, 64, 8'h9C, 1'b1);                    // across 0x40000 (even -> odd VRAM)
        vwr_blk(19'h7FFE0, 32, 8'h58, 1'b1);
        vrd_blk(19'h00100, 64, 8'h65);
        vrd_blk(19'h3FFE0, 64, 8'h9C);
        vrd_blk(19'h7FFE0, 32, 8'h58);
        ok(vbad == 0, "P1: 160 bytes escritos y leidos por P#0 (VRAM0/VRAM1 entrelazadas)");
        vsd_chk(19'h00100, 64, 1'b1); vsd_chk(19'h3FFE0, 64, 1'b1); vsd_chk(19'h7FFE0, 32, 1'b1);
        ok(vsdbad == 0, "P1: cada byte esta en la SDRAM en 0x780000 + {dir[17:0], dir[18]}");
        vreg_w(6, 8'h82);

        // ==============================================================
        $display("== J. CPU y V9990 a la vez: display encendido (B1, luego P1 con sprites), ranuras de VRAM ==");
        ls0 = lost_slots(0);
        vreg_w(15, 8'h07); vreg_w(7, 8'h00); vreg_w(8, 8'h80);   // backdrop, NTSC, display on
        vreg_w(9, 8'h01);                                         // IEV: the vertical interrupt (section K)
        wstat_clear;
        traffic(60, 1'b0, 8'h31);
        ok(mem_bad == 0, "B1 con display: todas las lecturas del mapper y de la MegaRAM devuelven lo escrito");
        ok(vbad == 0, "B1 con display: las lecturas de VRAM por P#0 devuelven lo escrito");
        ok(nbad == 0 && vsdbad == 0, "B1 con display: cada byte de CPU y de VRAM esta en su sitio de la SDRAM");
        $display("         /WAIT de P#0 con el display encendido (%0d accesos): cae a +%0.0f..%0.0f ns, dura %0.0f..%0.0f ns; %0d sin /WAIT",
                 wn, wl_min, wl_max, wd_min, wd_max, wn_none);
        ok(wl_max < 270.0, "con display, el /WAIT de P#0 llega a tiempo a 3,58 MHz");
        $display("         ranuras de VRAM perdidas hasta aqui: %0d", lost_slots(0) - ls0);
        ok(lost_slots(0) == ls0, "B1 con display: ninguna ranura de VRAM perdida (aserto de T9990_RAM)");
        vreg_w(6, 8'h00);                                         // P1: 64-bit interleaved accesses of the planes
        wstat_clear;
        traffic(60, 1'b1, 8'hC4);
        ok(mem_bad == 0, "P1 con display: todas las lecturas del mapper y de la MegaRAM devuelven lo escrito");
        ok(vbad == 0, "P1 con display: las lecturas de VRAM por P#0 devuelven lo escrito");
        ok(nbad == 0 && vsdbad == 0, "P1 con display: cada byte de CPU y de VRAM esta en su sitio de la SDRAM");
        $display("         /WAIT de P#0 en P1 con el display encendido (%0d accesos): cae a +%0.0f..%0.0f ns, dura %0.0f..%0.0f ns; %0d sin /WAIT",
                 wn, wl_min, wl_max, wd_min, wd_max, wn_none);
        ok(wl_max < 270.0, "en P1 con display, el /WAIT de P#0 llega a tiempo a 3,58 MHz");
        $display("         ranuras de VRAM perdidas hasta aqui: %0d", lost_slots(0) - ls0);
        ok(lost_slots(0) == ls0, "P1 con display: ninguna ranura de VRAM perdida");

        if (!SHORT) begin
        // ==============================================================
        if (!LATONLY) begin
        $display("== K. interrupcion vertical (R#9 = 01h) hasta /INT y su limpieza por P#6 ==");
        vo(4'd6, 8'h07); #2_000;                                  // flags of the traffic phase cleared
        ok(s_int_n === 1'b1, "OUT 66h,07h limpia los flags y /INT sube");
        int_seen = 1'b0;
        fork : espera_int
            begin @(negedge s_int_n); int_seen = 1'b1; t_int0 = $realtime; disable espera_int; end
            begin #25_000_000; disable espera_int; end
        join
        ok(int_seen, "/INT baja en el slot (VI de fin de cuadro, IEV en R#9)");
        vi(4'd6);
        ok(rdv[0] === 1'b1, "P#6: el flag VI esta puesto");
        vo(4'd6, 8'h01);
        #1_000;
        ok(s_int_n === 1'b1, "OUT 66h,01h limpia el flag y /INT sube");
        vi(4'd6);
        ok(rdv[2:0] === 3'b000, "P#6 se lee a 0 tras limpiarlo");
        #1_500_000;
        ok(s_int_n === 1'b1, "no vuelve a bajar hasta el cuadro siguiente (1,5 ms despues)");
        fork : espera_int2
            begin @(negedge s_int_n); t_int1 = $realtime; disable espera_int2; end
            begin #25_000_000; disable espera_int2; end
        join
        $display("         intervalo entre dos /INT: %0.3f ms (60,27 Hz esperado)", (t_int1 - t_int0) / 1.0e6);
        ok(near((t_int1 - t_int0) / 1.0e6, 16.59, 0.01), "el intervalo es un cuadro NTSC del V9990TANG (16,59 ms +-1 %)");
        vo(4'd6, 8'h01);
        vreg_w(9, 8'h00);
        #1_000;
        ok(s_int_n === 1'b1, "con IEV a 0 y el flag limpio /INT queda arriba");

        end // !LATONLY (K)
        // ==============================================================
        $display("== G. mapper de 4 MB (subslot 3): 256 paginas, SDRAM 0x000000-0x3FFFFF, sin espejo ==");
        mem_wr(16'hFFFF, 8'h30);                    // page 2 -> subslot 3
        io_wr(16'h00FE, 8'h85);
        mem_wr(16'h8123, 8'hC1);
        mem_wr(16'h8124, 8'hA5);
        io_wr(16'h00FE, 8'h05);
        mem_wr(16'h8123, 8'h5A);
        mem_wr(16'h8124, 8'hA5);
        io_wr(16'h00FE, 8'hFF);
        mem_wr(16'hBFFF, 8'h99);
        #20_000;
        ok(sd_byte(23'h214123) === 8'hC1, "pagina 85h, 8123h -> SDRAM 0x214123 (con 4 MB ya no hay espejo)");
        ok(sd_byte(23'h014123) === 8'h5A, "pagina 05h, 8123h -> SDRAM 0x014123, distinta de la 85h");
        ok(sd_byte(23'h3FFFFF) === 8'h99, "pagina FFh, BFFFh -> SDRAM 0x3FFFFF (el ultimo byte del mapper)");
        mem_bad = 0;
        io_wr(16'h00FE, 8'h85); mem_rd(16'h8123, 8'hC1); mem_rd(16'h8124, 8'hA5);
        io_wr(16'h00FE, 8'h05); mem_rd(16'h8123, 8'h5A);
        io_wr(16'h00FE, 8'hFF); mem_rd(16'hBFFF, 8'h99);
        ok(mem_bad == 0, "y las paginas 85h, 05h y FFh se releen sin mezclarse");
        io_wr(16'h00FE, 8'h05);
        io_rd(16'h00FE);
        ok(rd_driven && rdv === 8'h05, "IN FEh devuelve el registro del mapper");

        $display("== H. Super-MegaRAM (subslot 2) ==");
        mem_wr(16'hFFFF, 8'h20);                    // page 2 -> subslot 2
        mem_wr(16'h8000, 8'h05);                    // DDX: bank 2 = 5 (paging mode)
        io_rd(16'h008E);                            // RAM mode
        mem_wr(16'h8010, 8'hC3);
        #20_000;
        ok(sd_byte(23'h40A010) === 8'hC3, "MegaRAM banco 5, 8010h -> SDRAM 0x40A010");
        mem_rd(16'h8010, 8'hC3);
        ok(mem_bad == 0, "y se relee");
        io_wr(16'h008E, 8'h00);                     // back to paging mode
        mem_wr(16'hFFFF, 8'h30);

        $display("== H2. ROM de Nextor (subslot 0, copia en SDRAM 0x600000) ==");
        // FFFFh = 30h: page 1 -> subslot 0 (Nextor bank 0). The flash holds a
        // ramp there (byte = address[7:0]); New Juice copied its first 2 KB.
        mem_bad = 0;
        mem_rd(16'h4005, 8'h05);
        mem_rd(16'h4123, 8'h23);
        mem_rd(16'h47FF, 8'hFF);
        ok(mem_bad == 0, "lecturas de la ROM de Nextor (flash_roms) correctas");

        if (!LATONLY) begin
        // ==============================================================
        $display("== I. OPLL (7Ch/7Dh) ==");
        // user instrument 0: modulator muted, carrier MULT=1, AR=15, SL=0, RR=15
        io_wr(16'h007C, 8'h00); io_wr(16'h007D, 8'h21);
        io_wr(16'h007C, 8'h01); io_wr(16'h007D, 8'h21);
        io_wr(16'h007C, 8'h02); io_wr(16'h007D, 8'h3F);
        io_wr(16'h007C, 8'h03); io_wr(16'h007D, 8'h00);
        io_wr(16'h007C, 8'h04); io_wr(16'h007D, 8'hF0);
        io_wr(16'h007C, 8'h05); io_wr(16'h007D, 8'hF0);
        io_wr(16'h007C, 8'h06); io_wr(16'h007D, 8'h0F);
        io_wr(16'h007C, 8'h07); io_wr(16'h007D, 8'h0F);
        io_wr(16'h007C, 8'h30); io_wr(16'h007D, 8'h00);   // ch0: user instrument, volume max
        io_wr(16'h007C, 8'h10); io_wr(16'h007D, 8'h80);   // fnum low
        io_wr(16'h007C, 8'h20); io_wr(16'h007D, 8'h19);   // key on, block 4
        #1_000_000;
        ok(fpga.u_top.opll_enabled_impl.jt2413_inst.u_mmr.selreg === 8'h20 &&
           fpga.u_top.opll_enabled_impl.jt2413_inst.u_mmr.din_copy === 8'h19,
           "las escrituras en 7Ch/7Dh llegan al OPLL (registro 20h = 19h)");
        $display("         [info] salida del OPLL en la simulacion: %h (tras sv2v puede quedar en X en Icarus; la misma jt2413 suena en blocks/tb_opll.v)", fpga.u_top.opll_audio_sample);
        io_wr(16'h007C, 8'h20); io_wr(16'h007D, 8'h00);

        // ==============================================================
        $display("== I2. audio I2S (PSG, OPLL, SCC y click mezclados, MoonSound ya no esta) ==");
        // On the FPGA every RAM and register starts at 0; in Icarus some New
        // Juice sources (wave RAM of the SCC, JT49/JT2413 tables) stay X until they
        // are written, and one X turns the whole mix into X. Report and pin
        // them to 0 so that the mix -> I2S path can be checked.
        if (^fpga.u_top.scc_audio_sample === 1'bx) begin force fpga.u_top.scc_audio_sample = 16'sd0; $display("         [info] SCC en X en la simulacion: se fija a 0"); end
        if (^fpga.u_top.psg_audio_sample === 1'bx) begin force fpga.u_top.psg_audio_sample = 16'sd0; psg_was_x = 1'b1; $display("         [info] PSG en X en la simulacion: se fija a 0"); end
        if (^fpga.u_top.opll_audio_sample === 1'bx) begin force fpga.u_top.opll_audio_sample = 16'sd0; opll_was_x = 1'b1; $display("         [info] OPLL en X en la simulacion: se fija a 0"); end
        if (^fpga.u_top.keyclick_audio_sample === 1'bx) begin force fpga.u_top.keyclick_audio_sample = 16'sd0; $display("         [info] keyclick en X en la simulacion: se fija a 0"); end
        #100_000;
        n_frames = 0; i2s_frames = 0; i2s_lr_bad = 0; i2s_val_bad = 0;
        #3_000_000;
        $display("         tramas I2S=%0d, %0d con las dos mitades distintas, %0d palabras que no son la muestra de la mezcla", i2s_frames, i2s_lr_bad, i2s_val_bad);
        ok(n_frames > 130 && n_frames < 160, "tramas I2S a ~48 kHz (3 ms)");
        ok(i2s_frames > 130 && i2s_lr_bad == 0, "cada trama I2S lleva la misma muestra en sus dos mitades (mono)");
        ok(i2s_val_bad == 0, "en formato I2S (MAX98357A) cada palabra es exactamente la muestra de la mezcla");
        measure(1, f);
        $display("         BCLK = %0.4f MHz -> fs = %0.1f Hz", f, f * 1.0e6 / 32.0);
        ok(near(f, 1.542857, 0.002), "BCLK = 108 MHz / 70");
        // the mono mix saturates (PSG + OPLL well beyond full scale, both signs)
        force fpga.u_top.psg_audio_sample = 16'sh3000;
        force fpga.u_top.opll_audio_sample = 16'sh7000;
        #150_000;
        sat_pos = fpga.u_top.mixed_audio_sample; spk_pos = spk;
        force fpga.u_top.psg_audio_sample = -16'sh3000;
        force fpga.u_top.opll_audio_sample = -16'sh7000;
        #150_000;
        sat_neg = fpga.u_top.mixed_audio_sample; spk_neg = spk;
        $display("         mezcla mono saturada: +%h / -%h -> altavoz %0d / %0d", sat_pos, sat_neg, spk_pos, spk_neg);
        ok(sat_pos === 16'h7FFF && sat_neg === 16'h8000 && spk_pos == 32767 && spk_neg == -32768,
           "la mezcla del ampli satura en vez de dar la vuelta y llega asi por I2S");
        if (psg_was_x) force fpga.u_top.psg_audio_sample = 16'sd0; else release fpga.u_top.psg_audio_sample;
        if (opll_was_x) force fpga.u_top.opll_audio_sample = 16'sd0; else release fpga.u_top.opll_audio_sample;

        end // !LATONLY (I, I2)
        // ==============================================================
        $display("== L. latencia de las lecturas de memoria de la CPU (mapper, ROM, MegaRAM) con el V9990 parado, en B1 y en P1 ==");
        // Reads without /WAIT: the data must be settled at the slot pins before the Z80 samples.
        // Per configuration of the V9990 (display off, B1 with display, P1 with display and sprites) and
        // speed: 80 reads of the mapper (8123h/8124h) and the Nextor ROM (4005h/4123h) and 40 of the
        // MegaRAM (8010h), as normal reads and as M1 fetches (/M1 low). "fallan" = settled later than
        // the Z80 allows: 4 half periods after /MREQ's clock edge normally, 3 for a bare Z80 M1, 5 for an
        // MSX M1 (one wait state added), always minus tDL and the 30 ns of data set-up.
        for (cfg = 0; cfg < 3; cfg = cfg + 1) begin
            if (cfg == 0) begin vreg_w(8, 8'h00); vreg_w(6, 8'h82); cname = "V9990 parado "; end
            if (cfg == 1) begin vreg_w(6, 8'h82); vreg_w(8, 8'h80); cname = "B1 con imagen "; end
            if (cfg == 2) begin vreg_w(6, 8'h00); vreg_w(8, 8'h80); cname = "P1 con imagen "; end
            #200_000;
            for (speed = 0; speed < 3; speed = speed + 1) begin
                for (m1 = 0; m1 < 2; m1 = m1 + 1) begin
                    sname = (speed == 0) ? "3,58 MHz" : (speed == 1) ? "5,37 MHz" : "7,16 MHz";
                    rd_m1 = 1'b0; lt_clear;
                    TH = 139.6825; mem_wr(16'hFFFF, 8'h30); io_wr(16'h00FE, 8'h05);
                    rd_m1 = m1[0]; lt_clear;
                    TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413; #2_000;
                    for (nrd = 0; nrd < 40; nrd = nrd + 1) begin
                        mem_rd(nrd[0] ? 16'h8124 : 16'h8123, nrd[0] ? 8'hA5 : 8'h5A);
                        mem_rd(nrd[0] ? 16'h4123 : 16'h4005, nrd[0] ? 8'h23 : 8'h05);
                    end
                    rd_m1 = 1'b0;
                    TH = 139.6825; mem_wr(16'hFFFF, 8'h20); mem_wr(16'h8000, 8'h05); io_rd(16'h008E);
                    rd_m1 = m1[0];
                    TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413; #2_000;
                    for (nrd = 0; nrd < 40; nrd = nrd + 1) mem_rd(16'h8010, 8'hC3);
                    rd_m1 = 1'b0;
                    $display("         [lat] %0s %0s %0s: %0d lecturas, %0d con dato mal; dato asentado en el pin como muy tarde a +%0.1f ns tras /MREQ; margen %0.1f ns (normal) / %0.1f (M1 de Z80 solo) / %0.1f (M1 de MSX); fallan %0d / %0d / %0d",
                             cname, sname, m1 ? "M1    " : "normal", lt_n, mem_bad, lt_max,
                             4.0 * TH - tdl(TH) - 30.0 - lt_max, 3.0 * TH - tdl(TH) - 30.0 - lt_max, 5.0 * TH - tdl(TH) - 30.0 - lt_max,
                             lt_f4, lt_f3, lt_f5);
                    if (speed == 0 && !m1) ok(mem_bad == 0 && lt_f4 == 0, "a 3,58 MHz la lectura normal llega a tiempo (mapper, ROM y MegaRAM)");
                    if (speed == 0 &&  m1) ok(mem_bad == 0 && lt_f5 == 0, "a 3,58 MHz el M1 (con el wait state de MSX) llega a tiempo");
                    // 5.37 MHz is measured, not required: New Juice alone has
                    // +2..9 ns there and with the V9990 showing a picture the
                    // CPU waits for its VRAM access (docs/V9990.md, limits)
                    if (speed == 1) $display("  [info] a 5,37 MHz (medido, no exigido): fallan %0d lecturas normales y %0d con el M1 de MSX", lt_f4, lt_f5);
                    ok(lt_nodata == 0, "toda lectura de memoria de la medida tiene dato en el pin");
                    TH = 139.6825; io_wr(16'h008E, 8'h00); mem_wr(16'hFFFF, 8'h30);
                end
            end
            TH = 139.6825;
        end
        rd_m1 = 1'b0;
        vreg_w(6, 8'h00); vreg_w(8, 8'h80);
        if (LATONLY) begin
            ok(lost_slots(0) == 0, "ninguna ranura de VRAM perdida");
            ok(sdram.n_err == 0 && sdram.n_stale == 0, "la SDRAM sin ordenes ilegales ni filas caducadas");
            fin;
        end

        $display("== L2. Super-MegaRAM en modo LINEAR (linear_rom) ==");
        mem_wr(16'hFFFF, 8'h20);                    // page 2 -> subslot 2
        io_wr(16'h008F, 8'h02);                     // LINEAR: first 64 KB at 0000h-FFFFh
        mem_bad = 0;
        mem_rd(16'hA010, 8'hC3);                    // = SDRAM 0x40A010, written in H
        ok(mem_bad == 0, "LINEAR: A010h lee el byte de SDRAM 0x40A010");
        mem_wr(16'hFFFF, 8'h30);

        // ==============================================================
        $display("== M. /RESET del MSX: el V9990 se reinicia, la VRAM se conserva ==");
        vreg_w(10, 8'h5A); vreg_w(16, 8'h6D); vreg_r(10);
        ok(rdv === 8'h5A, "antes del /RESET, R#10 = 5Ah");
        reset_n = 1'b0; #500_000; reset_n = 1'b1; t_rst = $realtime;
        // it answers when R#10 reads 0 (reset value; the bus floats to FFh before)
        polls = 0; rdv = 8'hFF;
        while (rdv !== 8'h00 && polls < 400) begin
            vo(4'd4, 8'd10); vi(4'd3);
            polls = polls + 1;
        end
        t_resp = $realtime - t_rst;
        ok(rdv === 8'h00, "tras el /RESET el V9990 contesta y R#10 vale 0: sus registros se reinician");
        $display("         [cifra] /RESET suelto -> modulos a +%0.2f us -> reset interno del V9990 libre a +%0.2f us -> primera lectura correcta a +%0.1f us (%0d intentos)",
                 (t_ready_rise - t_rst) / 1000.0, (t_core_rise - t_rst) / 1000.0, t_resp / 1000.0, polls);
        vreg_r(16);
        ok(rdv === 8'h00, "R#16 tambien vuelve a 0");
        vreg_w(6, 8'h82); vbad = 0;
        vrd_blk(19'h12340, 256, 8'h4D);
        ok(vbad == 0, "y la VRAM sigue en la SDRAM tras el /RESET (256 bytes en 12340h)");
        mem_wr(16'hFFFF, 8'h20);                    // Super-MegaRAM back to DDX_SCC mode after the reset (as the real one)
        mem_wr(16'h9000, 8'h3F);                    // bank 2 = 3Fh: SCC at 9800h
        io_wr(16'h00FE, 8'h05);
        vreg_w(6, 8'h00); vreg_w(8, 8'h80);         // P1 with display again for the timing section

        // ==============================================================
        $display("== O. tiempos del bus en los pines del slot a 3,58 / 5,37 / 7,16 MHz (V9990 en P1 con display) ==");
        vwr_blk(19'h00200, 16, 8'h7E, 1'b1);
        for (speed = 0; speed < 3; speed = speed + 1) begin
            TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413;
            sname = (speed == 0) ? "3,58 MHz" : (speed == 1) ? "5,37 MHz" : "7,16 MHz";
            #20_000;
            // IN FEh (mapper register, New Juice): DATADIR, /BUSDIR and data
            begin : o_fe
                real mdr, mbd, mdt; integer bad;
                mdr = 0; mbd = 0; mdt = 0; bad = 0;
                for (i = 0; i < 20; i = i + 1) begin
                    io_rd_t(16'h00FE);
                    if (rdv !== 8'h05 || io_dir < 0 || io_bd < 0) bad = bad + 1;
                    if (io_dir > mdr) mdr = io_dir; if (io_bd > mbd) mbd = io_bd; if (io_dat > mdt) mdt = io_dat;
                end
                $display("         [bus] %0s IN FEh (mapper) x20: %0d mal; DATADIR +%0.1f, /BUSDIR +%0.1f, dato +%0.1f ns tras /IORQ; el Z80 muestrea a +%0.1f (margen del dato %0.1f ns)",
                         sname, bad, mdr, mbd, mdt, 5.0 * TH - tdl(TH), 5.0 * TH - tdl(TH) - 30.0 - mdt);
                if (speed == 0) ok(bad == 0, "IN FEh a 3,58 MHz con temporizacion de Z80: dato, DATADIR y /BUSDIR");
            end
            // IN 65h (V9990 status P#5) and IN 63h (a register): no /WAIT
            begin : o_65
                real mdr, mbd, mdt; integer bad;
                mdr = 0; mbd = 0; mdt = 0; bad = 0;
                for (i = 0; i < 20; i = i + 1) begin
                    io_rd_t(16'h0065);
                    if (!rd_driven || io_bd < 0 || io_wt >= 0 || rdv[3] !== 1'b0) bad = bad + 1;
                    if (io_dir > mdr) mdr = io_dir; if (io_bd > mbd) mbd = io_bd; if (io_dat > mdt) mdt = io_dat;
                end
                $display("         [bus] %0s IN 65h (V9990 estado) x20: %0d mal; DATADIR +%0.1f, /BUSDIR +%0.1f, dato +%0.1f ns tras /IORQ; el Z80 muestrea a +%0.1f (margen del dato %0.1f ns)",
                         sname, bad, mdr, mbd, mdt, 5.0 * TH - tdl(TH), 5.0 * TH - tdl(TH) - 30.0 - mdt);
                if (speed == 0) ok(bad == 0, "IN 65h a 3,58 MHz con temporizacion de Z80: la placa contesta con /BUSDIR, sin /WAIT");
                if (speed == 1) ok(mdt < 5.0 * TH - tdl(TH) - 30.0, "IN 65h a 5,37 MHz: el dato llega antes del muestreo del Z80");
            end
            // IN 60h (VRAM, held with /WAIT): /WAIT at the pin and the byte
            begin : o_60
                real mwt, mdt, mdr, mbd; integer bad, late, wrong;
                mwt = 0; mdt = 0; mdr = 0; mbd = 0; bad = 0; late = 0; wrong = 0;
                TH = 139.6825; #2_000;
                vset_r(19'h00200);
                TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413; #2_000;
                for (i = 0; i < 16; i = i + 1) begin
                    io_rd_t(16'h0060);
                    if (io_wt < 0) bad = bad + 1;
                    else if (io_wt > 3.0 * TH - tdl(TH) - 70.0) late = late + 1;
                    if (rdv !== vdat(8'h7E, i)) wrong = wrong + 1;
                    if (io_wt > mwt) mwt = io_wt; if (io_dat > mdt) mdt = io_dat; if (io_dir > mdr) mdr = io_dir; if (io_bd > mbd) mbd = io_bd;
                end
                $display("         [bus] %0s IN 60h (VRAM, P1 con display) x16: /WAIT a +%0.1f ns tras /IORQ como muy tarde; el Z80 lo muestrea a +%0.1f (margen %0.1f ns con tS(WAIT) = 70 ns); %0d tarde, %0d sin /WAIT, %0d bytes mal; dato +%0.1f ns, DATADIR +%0.1f, /BUSDIR +%0.1f",
                         sname, mwt, 3.0 * TH - tdl(TH), 3.0 * TH - tdl(TH) - 70.0 - mwt, late, bad, wrong, mdt, mdr, mbd);
                if (speed == 0) ok(bad == 0 && late == 0 && wrong == 0, "IN 60h a 3,58 MHz: /WAIT a tiempo y el byte de la VRAM es el bueno");
            end
            // OUT 60h: /WAIT at the pin
            begin : o_w60
                real mwt; integer bad, late;
                mwt = 0; bad = 0; late = 0;
                TH = 139.6825; #2_000;
                vset_w(19'h00300);
                TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413; #2_000;
                for (i = 0; i < 8; i = i + 1) begin
                    io_wr_t(16'h0060, 8'hC0 + i); vsh[vmap(19'h00300 + i, 1'b1)] = 8'hC0 + i;
                    if (io_wt < 0) bad = bad + 1;
                    else if (io_wt > 3.0 * TH - tdl(TH) - 70.0) late = late + 1;
                    if (io_wt > mwt) mwt = io_wt;
                end
                $display("         [bus] %0s OUT 60h (VRAM) x8: /WAIT a +%0.1f ns tras /IORQ como muy tarde; el Z80 lo muestrea a +%0.1f (margen %0.1f ns); %0d tarde, %0d sin /WAIT",
                         sname, mwt, 3.0 * TH - tdl(TH), 3.0 * TH - tdl(TH) - 70.0 - mwt, late, bad);
                if (speed == 0) ok(bad == 0 && late == 0, "OUT 60h a 3,58 MHz: /WAIT a tiempo");
                TH = 139.6825; #50_000;
                vsd_chk(19'h00300, 8, 1'b1);
            end
            // SCC wave RAM (IKASCC, clocked by the slot clock), no /WAIT
            begin : o_scc
                integer bad0;
                bad0 = mem_bad; t_pin_max = 0; t_dir_max = 0;
                // written at 3.58 MHz (mem_wr has Z80A delays), read at speed
                TH = 139.6825; #2_000;
                for (i = 0; i < 16; i = i + 1) mem_wr(16'h9800 + i, 8'h30 + i + speed * 16);
                TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413; #2_000;
                for (i = 0; i < 16; i = i + 1) mem_rd(16'h9800 + i, 8'h30 + i + speed * 16);
                $display("         [bus] %0s SCC (9800h) 16 escrituras + 16 lecturas: %0d mal; DATADIR +%0.1f, dato +%0.1f ns tras /MREQ; el Z80 muestrea a +%0.1f (margen %0.1f ns)",
                         sname, mem_bad - bad0, t_dir_max, t_pin_max, 4.0 * TH - tdl(TH), 4.0 * TH - tdl(TH) - 30.0 - t_pin_max);
                if (speed == 0) ok(mem_bad == bad0, "SCC a 3,58 MHz: se relee lo escrito, sin /WAIT");
            end
        end
        TH = 139.6825;
        end // !SHORT

        // ==============================================================
        $display("== N. salud general ==");
        vreg_w(8, 8'h00);
        #200_000;
        // final sweep: the whole VRAM area of the SDRAM holds what P#0 wrote
        // (and the clear), nothing of the CPU's
        begin : sweep
            integer w, bad; reg [31:0] mw; reg [7:0] eb;
            bad = 0;
            for (w = 0; w < 131072; w = w + 1) begin
                mw = sdram.mem[21'h1E0000 + w];
                if (mw[7:0]   !== vsh[4 * w])     bad = bad + 1;
                if (mw[15:8]  !== vsh[4 * w + 1]) bad = bad + 1;
                if (mw[23:16] !== vsh[4 * w + 2]) bad = bad + 1;
                if (mw[31:24] !== vsh[4 * w + 3]) bad = bad + 1;
            end
            $display("         barrido de 0x780000-0x7FFFFF: %0d bytes distintos de los que escribio el V9990", bad);
            ok(bad == 0, "toda la zona de VRAM de la SDRAM es lo que escribio el V9990 (nada de la CPU cae dentro)");
        end
        $display("         comandos a la SDRAM: CPU %0d lecturas + %0d escrituras (%0d con direccion >= 0x780000); V9990 %0d palabras leidas + %0d escritas (%0d fuera de su zona)",
                 n_cpu_rd, n_cpu_wr, n_cpu_hi, n_v_rd, n_v_wr, n_v_lo);
        $display("         escrituras vistas por la SDRAM: %0d por debajo de 0x780000, %0d en la zona de VRAM", n_pin_wr_lo, n_pin_wr_hi);
        ok(n_cpu_hi == 0, "ninguna orden de la CPU (mapper, MegaRAM, ROM) cae en la VRAM");
        ok(n_v_lo == 0, "ninguna orden del V9990 cae fuera de 0x780000-0x7FFFFF");
        ok(n_pin_wr_hi == n_v_wr, "las escrituras en la zona de VRAM de la SDRAM son exactamente las del V9990");
        ok(n_pin_wr_lo == n_cpu_wr, "las escrituras por debajo de 0x780000 son exactamente las de la CPU");
        $display("         ranuras de VRAM perdidas en toda la simulacion: %0d", lost_slots(0));
        ok(lost_slots(0) == 0, "ninguna ranura de VRAM perdida en toda la simulacion (T9990_RAM.lost_slots)");
        ok(bad_drive == 0, "la placa nunca condujo D0-D7 fuera de una lectura suya");
        ok(bad_busdir == 0, "/BUSDIR acompano siempre a la conduccion en E/S");
        ok(setup_viol == 0, "ningun dato cambio en la ventana de muestreo del Z80 en E/S y /WAIT nunca se activo dentro");
        ok(sdram.n_err == 0, "la SDRAM no vio ninguna orden ilegal");
        ok(sdram.n_stale == 0, "ninguna fila de la SDRAM caduco");
        $display("         SDRAM: %0d ACT, %0d RD, %0d WR, %0d REF en %0.1f ms; hueco maximo entre refrescos %0.2f us",
                 sdram.n_act, sdram.n_rd, sdram.n_wr, sdram.n_ref, $realtime / 1.0e6, sdram.max_ref_gap / 1000.0);
        fin;
    end

    initial begin
        #400_000_000;
        $display("RESULTADO: FAIL (timeout global, %0d errores hasta aqui)", errors);
        $finish;
    end
endmodule
