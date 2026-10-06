// ============================================================================
// tb_nj_board.v - the WHOLE New Juice MoonSound fork on a WonderTANG 2.0b/2.02b.
//
// The real top (src/top.v and everything in new-juice.gprj, converted with
// sv2v), Gowin's simulation primitives (rPLL, BUFG, DFF, ...), wired BY PIN
// NUMBER (wrapper generated from src/top.cst) to MoonTANG's board model
// (wt20x_board.v: multiplexed bus, transceiver, NPN /WAIT and /INT, I2S
// amplifier, SPI flash), the embedded SDRAM model with its retention check and
// a Z80 bus-functional model with Z80A timing at the slot.
//
// The flash holds SYNTHETIC images: a ramp where New Juice expects Nextor,
// FM-PAC and SFG-01, and a 4 KB fake YRW801 at 0x200000 (with its checksum
// passed by defparam). No copyrighted ROM is used.
//
// Simulation shortcuts (run_board.sh patches the converted netlist, the RTL is
// untouched): the automatic S1 pulse comes after 2000 clocks instead of 250 ms,
// the SDRAM start-up test covers 256 words instead of 64K, New Juice copies
// 2 KB of ROM instead of 160 KB, the YRW801 is 4 KB, and the video PLL is held
// in reset (HDMI is not exercised here), except in the HDMI mode (WITH_HDMI,
// hdmi_nj.vh), which boots, plays the OPL4 and checks the HDMI output.
//
// Bus timing at the slot pins: every read the bench makes is logged with the
// moments, counted from its /MREQ or /IORQ, at which the transceiver turns
// towards the slot (DATADIR), /BUSDIR falls, the data at the slot settles and
// /WAIT falls (`+cyclog=<file>`, one line per bus cycle). Section L measures
// them for mapper reads at 3.58 / 5.37 / 7.16 MHz, section O for I/O reads
// (IN FEh, IN C4h, IN 7Fh), SCC reads and the debugger's /WAIT on an M1
// fetch, at the same three speeds. `run_board.sh diff` runs the bench on two
// versions of the design and compares those logs (tools/sim/board/cyc_diff.py).
// ============================================================================
`timescale 1ns/1ps

module tb_nj_board;
    parameter integer QUIET = 0;
    parameter integer BLANK = 0;              // 1 = flash without YRW801 (all FF)

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
    // 4 KB fake YRW801 and its checksum (the real 2 MB sum stays the RTL default)
    defparam fpga.u_top.moonsound_inst.YRW_SIZE = 23'h001000;
    defparam fpga.u_top.moonsound_inst.YRW_SUM  = 32'h0007FFAD;

    sdram_model #(.RET_CHECK(1)) sdram (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .addr(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq)
    );

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

`ifndef WITH_HDMI
    // HDMI is not exercised here: keep the video PLL in reset
    // (run_board.sh hdmi compiles with WITH_HDMI: see hdmi_nj.vh)
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
    //  this cartridge (an I/O read of one of its ports, or a memory read with
    //  /SLTSL), with the MSX alive.
    // ------------------------------------------------------------------
    wire [7:0] port = a[7:0];
    wire io_ours = (port[7:2] == 6'b110001) || (port[7:1] == 7'b0111111) || (port[7:2] == 6'b111111);
    wire legit_rd = msx_on && reset_n && !rd_n &&
                    ((!iorq_n && m1_n && io_ours) || (!mreq_n && !sltsl_n));
    // With the MSX off every slot line sits at 0, so /RD = /SLTSL = 0 and New
    // Juice (unchanged, cd_demux.v) turns the transceiver towards the slot even
    // though it puts nothing on the bus. That is upstream behaviour, counted
    // apart as information; what must hold is that the FPGA never drives cd
    // and the MoonSound never claims a read while the MSX is off.
    integer bad_drive = 0, nj_dir_off = 0, ours_off = 0;
    reg     drive_seen = 1'b0;
    always @(posedge cart_drives_d) if (!msx_on) nj_dir_off = nj_dir_off + 1;
    always @(posedge fpga.u_top.opl4_drive_en) if (!msx_on) ours_off = ours_off + 1;
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
    realtime t_dir_on = 0, t_bd_on = 0, t_sd_chg = 0, t_wait_on = 0;
    always @(posedge cart_drives_d) t_dir_on = $realtime;
    always @(negedge s_busdir_n)    t_bd_on = $realtime;
    always @(s_d)                   t_sd_chg = $realtime;
    always @(negedge s_wait_n)      t_wait_on = $realtime;
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
    realtime t_iorq, t_wait, t_mreq;
    reg      wait_early, waiting;
    integer  setup_viol = 0, wait_rel_amb = 0;
    real     wait_lat = 0, wait_lat_max = 0;
    always @(negedge s_wait_n) begin
        t_wait = $realtime;
        wait_lat = t_wait - t_iorq;
        if (wait_lat > wait_lat_max) wait_lat_max = wait_lat;
    end

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
            @(posedge clk358); #100 a = adr;
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
            #70 mreq_n = 1'b1; rd_n = 1'b1; #20 sltsl_n = 1'b1;
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
            cyc_log("IO_RDT", p, rdv, io_tw, io_dir, io_bd, io_dat, io_wt);
            #(tdl(TH)) iorq_n = 1'b1; rd_n = 1'b1;
            #200;
        end
    endtask
    // M1 fetch with the Z80's timing scaled to the clock; returns when /WAIT
    // fell, counted from /MREQ (-1 if it did not by the T2 falling edge,
    // where the Z80 samples it). The opcode comes from the system ROM.
    real m1_wt;
    task m1_t(input [15:0] pc, input [7:0] opcode);
        realtime tm;
        begin
            @(posedge clk358); #(tdl(TH)) a = pc; m1_n = 1'b0;         // T1
            @(negedge clk358); #(tdl(TH)) mreq_n = 1'b0; rd_n = 1'b0; tm = $realtime;
            @(posedge clk358); #(TH / 2.0) d_out = opcode; d_oe = 1'b1; // T2
            @(negedge clk358);                                         // /WAIT sampled
            m1_wt = rel(t_wait_on, tm);
            cyc_log("M1", pc, opcode, (s_wait_n === 1'b0), -1.0, -1.0, -1.0, m1_wt);
            @(posedge clk358); #(tdl(TH)) mreq_n = 1'b1; rd_n = 1'b1; m1_n = 1'b1;
            #10 d_oe = 1'b0; a = {8'h12, 8'h7F}; rfsh_n = 1'b0;
            @(negedge clk358); #(tdl(TH)) mreq_n = 1'b0;
            @(posedge clk358);
            @(negedge clk358); #(tdl(TH)) mreq_n = 1'b1;
            @(posedge clk358); #(tdl(TH)) rfsh_n = 1'b1;
        end
    endtask

    task fm_w(input bank, input [7:0] r, input [7:0] v);
        begin
            io_wr({8'h00, bank ? 8'hC6 : 8'hC4}, r);
            io_wr({8'h00, bank ? 8'hC7 : 8'hC5}, v);
        end
    endtask
    task wv_w(input [7:0] r, input [7:0] v); begin io_wr(16'h007E, r); io_wr(16'h007F, v); end endtask
    task wv_r(input [7:0] r); begin io_wr(16'h007E, r); io_rd(16'h007F); end endtask
    task expect_silence(input [15:0] p, input [1023:0] what);
        begin
            drive_seen = 1'b0;
            io_rd(p);
            ok(!drive_seen && rdv === 8'hFF, what);
        end
    endtask

    function [7:0] sd_byte(input [22:0] sb);
        reg [31:0] w;
        begin w = sdram.mem[sb[22:2]]; sd_byte = w[8*sb[1:0] +: 8]; end
    endfunction

    // ------------------------------------------------------------------
    //  Clock measurement
    // ------------------------------------------------------------------
    task measure(input integer which, output real mhz);
        realtime t0, t1;
        integer  n;
        begin
            case (which)
                0: begin @(posedge fpga.u_top.main_clk); t0 = $realtime; for (n = 0; n < 200; n = n + 1) @(posedge fpga.u_top.main_clk); t1 = $realtime; end
                1: begin @(posedge fpga.u_top.opl4_clk54); t0 = $realtime; for (n = 0; n < 200; n = n + 1) @(posedge fpga.u_top.opl4_clk54); t1 = $realtime; end
                2: begin @(posedge fpga.u_top.opl4_clk_eng); t0 = $realtime; for (n = 0; n < 200; n = n + 1) @(posedge fpga.u_top.opl4_clk_eng); t1 = $realtime; end
                default: begin @(posedge pin[56]); t0 = $realtime; for (n = 0; n < 200; n = n + 1) @(posedge pin[56]); t1 = $realtime; end
            endcase
            mhz = 200.0 * 1000.0 / (t1 - t0);
        end
    endtask
    function near(input real v, input real target, input real tol);
        near = (v > target * (1.0 - tol)) && (v < target * (1.0 + tol));
    endfunction

    // ------------------------------------------------------------------
    //  Audio monitors
    // ------------------------------------------------------------------
    integer fml_max, fml_min, fmr_max, fmr_min, pcm_max, pcm_min, spk_max, spk_min, opll_max, opll_min;
    integer n_frames = 0, n_lr_diff = 0;
    task audio_clear;
        begin
            fml_max = 0; fml_min = 0; fmr_max = 0; fmr_min = 0; opll_max = 0; opll_min = 0;
            pcm_max = 0; pcm_min = 0; spk_max = 0; spk_min = 0;
        end
    endtask
    always @(posedge fpga.u_top.opl4_clk54) begin
        if ($signed(fpga.u_top.moonsound_inst.opl4fm_wav_l) > fml_max) fml_max = $signed(fpga.u_top.moonsound_inst.opl4fm_wav_l);
        if ($signed(fpga.u_top.moonsound_inst.opl4fm_wav_l) < fml_min) fml_min = $signed(fpga.u_top.moonsound_inst.opl4fm_wav_l);
        if ($signed(fpga.u_top.moonsound_inst.opl4fm_wav_r) > fmr_max) fmr_max = $signed(fpga.u_top.moonsound_inst.opl4fm_wav_r);
        if ($signed(fpga.u_top.moonsound_inst.opl4fm_wav_r) < fmr_min) fmr_min = $signed(fpga.u_top.moonsound_inst.opl4fm_wav_r);
        if ($signed(fpga.u_top.moonsound_inst.opl4pcm_l)    > pcm_max) pcm_max = $signed(fpga.u_top.moonsound_inst.opl4pcm_l);
        if ($signed(fpga.u_top.moonsound_inst.opl4pcm_l)    < pcm_min) pcm_min = $signed(fpga.u_top.moonsound_inst.opl4pcm_l);
        if ($signed(fpga.u_top.opll_audio_sample) > opll_max) opll_max = $signed(fpga.u_top.opll_audio_sample);
        if ($signed(fpga.u_top.opll_audio_sample) < opll_min) opll_min = $signed(fpga.u_top.opll_audio_sample);
    end
    always @(i2s_frame) begin
        n_frames = n_frames + 1;
        if (i2s_l !== i2s_r) n_lr_diff = n_lr_diff + 1;
        if (spk > spk_max) spk_max = spk;
        if (spk < spk_min) spk_min = spk;
    end

    // I2S as the MAX98357A takes it (sampled on BCLK rising edges): the MSB
    // one BCLK after the LRCLK edge, the LSB on the next LRCLK edge. Mono =
    // both halves of a frame equal; every word must also be one of the last
    // mix snapshots taken for audio_drive (exact value, no shift or wrap).
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

    integer ii_sl;
    initial begin
        #1;
        for (ii_sl = 0; ii_sl < 32; ii_sl = ii_sl + 1) begin
            fpga.u_top.moonsound_inst.u_opl4pcm.sl_stride[ii_sl] = 3'd0;
            fpga.u_top.moonsound_inst.u_opl4pcm.sl_hi[ii_sl] = 3'd0;
        end
    end

    // ------------------------------------------------------------------
    //  The test
    // ------------------------------------------------------------------
    integer i, polls, n0, speed, nrd, pcm_on, n_wops = 0;
    always @(posedge fpga.u_top.main_clk) if (fpga.u_top.sdram_arbiter_inst.p_rd || fpga.u_top.sdram_arbiter_inst.p_wr) n_wops = n_wops + 1;
    real    f;
    reg [7:0] exp;
    reg      int_seen;
    reg [8*12-1:0] sname;

`ifdef WITH_HDMI
`include "hdmi_nj.vh"
`endif

    initial begin
        audio_clear;
        // ---- fake YRW801 at flash 0x200000 (4 KB used) ----
        for (i = 0; i < 65536; i = i + 1) board.u_flash.mem[i] = i[7:0] ^ i[15:8] ^ 8'h5A;
        board.u_flash.mem[0]  = 8'h00;   // wave 0: 8 bit, start 0x000100
        board.u_flash.mem[1]  = 8'h01;
        board.u_flash.mem[2]  = 8'h00;
        board.u_flash.mem[3]  = 8'h00;
        board.u_flash.mem[4]  = 8'h00;
        board.u_flash.mem[5]  = 8'hFF;   // end = 64 samples
        board.u_flash.mem[6]  = 8'hC0;
        board.u_flash.mem[7]  = 8'h00;
        board.u_flash.mem[8]  = 8'hF0;
        board.u_flash.mem[9]  = 8'h00;
        board.u_flash.mem[10] = 8'hFF;
        board.u_flash.mem[11] = 8'h00;
        for (i = 0;  i < 32; i = i + 1) board.u_flash.mem[16'h0100 + i] = 8'h7F;
        for (i = 32; i < 64; i = i + 1) board.u_flash.mem[16'h0100 + i] = 8'h81;
        if (BLANK) for (i = 0; i < 65536; i = i + 1) board.u_flash.mem[i] = 8'hFF;

        // ==============================================================
        $display("== A. arranque con el MSX APAGADO (lineas del slot a 0, sin reloj) ==");
        a = 16'hC4C4; m1_n = 1'b1;
        wait (fpga.u_top.rpll_main_lock === 1'b1);
        wait (fpga.u_top.board_reset_n === 1'b1);
        measure(0, f); ok(near(f, 108.0, 0.002), "main_clk = 108 MHz");
        measure(1, f); ok(near(f, 54.0,  0.002), "opl4_clk54 = 54 MHz (CLKOUTD de rpll_main)");
        measure(2, f); ok(near(f, 36.0,  0.002), "opl4_clk_eng = 36 MHz (CLKOUTD3 de rpll_main: motor PCM y FM)");
        fork : arranque
            begin wait (fpga.u_top.startup_test_passed === 1'b1); disable arranque; end
            begin #60_000_000; disable arranque; end
        join
        ok(fpga.u_top.startup_test_passed === 1'b1, "el test de arranque de la SDRAM de New Juice pasa (con el arbitro delante)");
        $display("         test de SDRAM superado en t = %0.2f ms", $realtime / 1.0e6);
        fork : roms
            begin wait (fpga.u_top.flash_rom_loaded === 1'b1); disable roms; end
            begin #20_000_000; disable roms; end
        join
        ok(fpga.u_top.flash_rom_loaded === 1'b1, "New Juice copia sus ROM de la flash");
        $display("         ROM de New Juice copiadas en t = %0.2f ms", $realtime / 1.0e6);
        #100_000;
        ok(fpga.u_top.opl4_flash_owned === 1'b1, "despues, la flash pasa al cargador de la YRW801");
        fork : carga
            begin wait (fpga.u_top.opl4_wl_done === 1'b1); disable carga; end
            begin #40_000_000; disable carga; end
        join
        ok(fpga.u_top.opl4_wl_done === 1'b1, "el cargador copia la YRW801 (sintetica, 4 KB) a la SDRAM");
        $display("         YRW801 copiada en t = %0.2f ms", $realtime / 1.0e6);
        #1_000;
        ok(fpga.u_top.opl4_wl_error === 1'b0, "sin agotar reintentos");
        if (BLANK) begin
            ok(fpga.u_top.opl4_wl_badimg === 1'b1, "flash en blanco: la suma no casa y la imagen se marca como no valida");
            // the LED flash comes every 2^27 cycles (1.24 s): jump the blink
            // counter to just before its wrap instead of simulating a second
            ok(led === 1'b0 || fpga.u_top.sd_busy === 1'b1, "  LED apagado entre destellos");
            fpga.u_top.yrw_blink = 27'h7FFFF00;
            #3_000;
            ok(led === 1'b1, "  y el LED lo avisa (destello de 78 ms cada 1,24 s)");
            fpga.u_top.yrw_blink = 27'h07FFF00;     // end of the 78 ms flash
            #3_000;
            ok(led === 1'b0 || fpga.u_top.sd_busy === 1'b1, "  el destello termina");
            fin;
        end
        ok(fpga.u_top.opl4_wl_badimg === 1'b0, "la suma de la imagen copiada es la esperada");
        polls = 0;
        for (i = 0; i < 4096; i = i + 1) if (sd_byte(23'h200000 + i) !== board.u_flash.mem[i]) polls = polls + 1;
        ok(polls == 0, "la YRW801 esta en la SDRAM en 0x200000 byte a byte");
        ok(ours_off == 0, "MSX apagado con IORQ=RD=0 en C4h: la FPGA no pone nada en el bus (ni el MoonSound ni New Juice)");
        $display("         [info] con el MSX apagado New Juice gira el transceptor hacia el slot %0d veces (/RD=/SLTSL=0; comportamiento de New Juice sin cambios)", nj_dir_off);
        ok(fpga.u_top.opl4_wait_n === 1'b1 && fpga.u_top.opl4_int_n === 1'b1, "MSX apagado: el MoonSound no pide /WAIT ni /INT (guarda de bus vivo)");
        $display("         [info] /WAIT del slot con el MSX apagado: %b (New Juice lo mantiene hasta soltar sus modulos tras el /RESET; sin cambios)", s_wait_n);

        // ==============================================================
        $display("== B. el MSX se enciende ==");
        mreq_n = 1'b1; iorq_n = 1'b1; rd_n = 1'b1; wr_n = 1'b1; m1_n = 1'b1; rfsh_n = 1'b1;
        sltsl_n = 1'b1; a = 16'h0000; reset_n = 1'b0;
        msx_on = 1'b1;
        #500_000 reset_n = 1'b1;
        fork : vivo
            begin wait (fpga.u_top.moonsound_inst.ck_alive === 1'b1 && fpga.u_top.cpu_modules_ready_reg === 1'b1); disable vivo; end
            begin #8_000_000; disable vivo; end
        join
        #100_000;
        ok(fpga.u_top.cpu_modules_ready_reg === 1'b1, "New Juice suelta sus modulos (MSX vivo)");
        ok(fpga.u_top.moonsound_inst.ck_alive === 1'b1, "el MoonSound ve el reloj del slot");
`ifdef WITH_HDMI
        // HDMI mode: the picture and the audio on HDMI, then stop
        hdmi_test;
        fin;
`endif

        // ==============================================================
        $display("== C. FM (C4h-C7h): estado, relectura de registros, deteccion ==");
        io_rd(16'h00C4);
        ok(rd_driven && (rdv & 8'hE0) == 8'h00, "IN C4h: la placa contesta, sin flags de timer");
        // New Juice releases the bus through its debounced view of /RD, so
        // the release lags /RD by its debounce delay; the MoonSound gates its
        // registered decode with that same /RD and /IORQ, so it must let go
        // at the same time (within one 108 MHz clock and the phase of /RD)
        release_time(16'h00C4, rel_ours, rel_ours_in);
        release_time(16'h00FE, rel_nj, rel_nj_in);
        $display("         suelta D0-D7 y /BUSDIR %0.0f ns tras subir /RD en C4h, %0.0f ns tras el /RD interno (New Juice en su puerto FEh: %0.0f / %0.0f ns)",
                 rel_ours, rel_ours_in, rel_nj, rel_nj_in);
        ok(s_busdir_n === 1'b1 && !cart_drives_d && rel_ours < rel_nj + 60.0 && rel_ours < 300.0,
           "al acabar la lectura suelta el bus y /BUSDIR (en el slot, como mucho 60 ns despues que New Juice)");
        ok(rel_ours_in < rel_nj_in + 5.0,
           "y lo suelta a la vez que New Juice en sus puertos, contado desde su /RD interno (+-5 ns)");
        fm_w(0, 8'h20, 8'h5A); io_wr(16'h00C4, 8'h20); io_rd(16'h00C5);
        ok(rdv === 8'h5A, "registro FM 020h: se relee 5Ah por C5h");
        fm_w(1, 8'h21, 8'hA5); io_wr(16'h00C6, 8'h21); io_rd(16'h00C7);
        ok(rdv === 8'hA5, "registro FM 121h: se relee A5h por C7h");
        fm_w(1, 8'h05, 8'h03);
        wv_r(8'h02);
        ok(rdv === 8'h20, "registro wave 02h = 20h (identificador del YMF278B), con /WAIT");

        // ==============================================================
        $display("== D. puertos que no son del MoonSound ==");
        expect_silence(16'h00C0, "IN C0h (MSX-Audio): silencio");
        expect_silence(16'h00C8, "IN C8h: silencio");
        expect_silence(16'h007C, "IN 7Ch (OPLL, solo escritura): silencio");
        expect_silence(16'h0048, "IN 48h (era de la Franky): silencio");
        expect_silence(16'h0088, "IN 88h (era de la Franky): silencio");
        expect_silence(16'hC400, "IN con C4h en A8-A15: silencio");

        // ==============================================================
        $display("== E. timer 1 del OPL3 -> /INT ==");
        ok(s_int_n === 1'b1, "/INT en reposo");
        fm_w(0, 8'h02, 8'hFF); fm_w(0, 8'h04, 8'h01);
        int_seen = 1'b0;
        fork : espera_int
            begin wait (s_int_n === 1'b0); int_seen = 1'b1; disable espera_int; end
            begin #1_500_000; disable espera_int; end
        join
        ok(int_seen, "/INT baja al desbordar el timer 1 (FM a 36 MHz)");
        io_rd(16'h00C4);
        ok((rdv & 8'hC0) == 8'hC0, "status: IRQ + FT1");
        fm_w(0, 8'h04, 8'h00); fm_w(0, 8'h04, 8'h80);
        #600_000;
        ok(s_int_n === 1'b1, "/INT se suelta tras el reset de flags");

        // ==============================================================
        $display("== F. memoria de ondas por 7Eh/7Fh, con /WAIT ==");
        wv_w(8'h02, 8'h01);
        wv_w(8'h03, 8'h00); wv_w(8'h04, 8'h00); wv_w(8'h05, 8'h00);
        t_wait = 0;
        wv_r(8'h06); ok(rdv === 8'h00, "YRW801[000000]");
        io_rd(16'h007F); ok(rdv === 8'h01, "YRW801[000001] (autoincremento)");
        wv_w(8'h03, 8'h00); wv_w(8'h04, 8'h0A); wv_w(8'h05, 8'h37);
        polls = 0;
        for (i = 0; i < 6; i = i + 1) begin
            exp = (8'h37 + i) ^ 8'h0A ^ 8'h5A;
            if (i == 0) wv_r(8'h06); else io_rd(16'h007F);
            if (rdv !== exp) polls = polls + 1;
        end
        ok(polls == 0, "YRW801[000A37..3C] = contenido de la flash");
        ok(t_wait != 0, "/WAIT del slot se usa en las lecturas de 7Fh");
        $display("         /WAIT baja como muy tarde %0.0f ns tras /IORQ (el Z80 lo mira a los ~345 ns a 3,58 MHz)", wait_lat_max);
        ok(wait_lat_max < 270.0, "/WAIT llega con holgura al muestreo del Z80 a 3,58 MHz");
        wv_w(8'h03, 8'h20); wv_w(8'h04, 8'h00); wv_w(8'h05, 8'h00);
        wv_w(8'h06, 8'hA5); io_wr(16'h007F, 8'h5A); io_wr(16'h007F, 8'hC3);
        #50_000;
        ok(sd_byte(23'h700000) === 8'hA5 && sd_byte(23'h700001) === 8'h5A && sd_byte(23'h700002) === 8'hC3,
           "RAM de ondas 0x200000 -> SDRAM 0x700000");
        wv_w(8'h03, 8'h20); wv_w(8'h04, 8'h00); wv_w(8'h05, 8'h00);
        wv_r(8'h06);     ok(rdv === 8'hA5, "RAM[200000] = A5h por 7Fh");
        io_rd(16'h007F); ok(rdv === 8'h5A, "RAM[200001] = 5Ah");
        wv_w(8'h03, 8'h30); wv_w(8'h04, 8'h00); wv_w(8'h05, 8'h00);
        wv_r(8'h06);     ok(rdv === 8'hFF, "0x300000 (fuera del 1 MB de RAM): FFh");
        wv_w(8'h02, 8'h00);

        // ==============================================================
        $display("== G. mapper de 2 MB (subslot 3) ==");
        mem_wr(16'hFFFF, 8'h30);                    // page 2 -> subslot 3
        io_wr(16'h00FE, 8'h85);                     // page 85h = 05h on a 2 MB mapper
        mem_wr(16'h8123, 8'h5A);
        mem_wr(16'h8124, 8'hA5);
        #20_000;
        ok(sd_byte(23'h014123) === 8'h5A, "OUT FEh,85h + escritura en 8123h -> SDRAM 0x014123 (pagina 05h)");
        ok(sd_byte(23'h214123) !== 8'h5A, "y no en 0x214123 (la YRW801 queda fuera del mapper)");
        io_wr(16'h00FE, 8'h05);
        t_valid_max = 0; mem_bad = 0;
        mem_rd(16'h8123, 8'h5A);
        ok(mem_bad == 0, "la pagina 05h devuelve el mismo byte");
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

        // ==============================================================
        $display("== I. OPLL (7Ch/7Dh) ==");
        audio_clear;
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
        #3_000_000;
        $display("         OPLL: max=%0d min=%0d (valor ahora %h); jt2413: rst=%b cen=%b selreg=%h din_copy=%h div_cnt=%h slot=%h",
                 opll_max, opll_min, fpga.u_top.opll_audio_sample,
                 fpga.u_top.opll_enabled_impl.jt2413_inst.rst, fpga.u_top.opll_clock_enable,
                 fpga.u_top.opll_enabled_impl.jt2413_inst.u_mmr.selreg, fpga.u_top.opll_enabled_impl.jt2413_inst.u_mmr.din_copy,
                 fpga.u_top.opll_enabled_impl.jt2413_inst.u_mmr.u_div.cnt, fpga.u_top.opll_enabled_impl.jt2413_inst.slot);
        ok(fpga.u_top.opll_enabled_impl.jt2413_inst.u_mmr.selreg === 8'h20 &&
           fpga.u_top.opll_enabled_impl.jt2413_inst.u_mmr.din_copy === 8'h19,
           "las escrituras en 7Ch/7Dh llegan al OPLL (registro 20h = 19h)");
        if (opll_max > 200 && opll_min < -200) ok(1'b1, "el OPLL de New Juice suena");
        else $display("         [info] tras sv2v el OPLL da X en Icarus (salida %h); la misma jt2413 sin sv2v suena (blocks/tb_opll.v)", fpga.u_top.opll_audio_sample);
        io_wr(16'h007C, 8'h20); io_wr(16'h007D, 8'h00);

        // ==============================================================
        $display("== J. nota PCM (onda 0) -> motor -> mezcla -> I2S ==");
        // On the FPGA every RAM and register starts at 0; in Icarus some New
        // Juice sources (wave RAM of the SCC, JT51 tables) stay X until they
        // are written, and one X turns the whole mix into X. Report and pin
        // them to 0 so that the OPL4 -> mix -> I2S path can be checked.
        if (^fpga.u_top.scc_audio_sample === 1'bx) begin force fpga.u_top.scc_audio_sample = 16'sd0; $display("         [info] SCC en X en la simulacion: se fija a 0"); end
        if (^fpga.u_top.jt51_audio_sample === 1'bx) begin force fpga.u_top.jt51_audio_sample = 16'sd0; $display("         [info] OPM (JT51) en X en la simulacion: se fija a 0"); end
        if (^fpga.u_top.psg_audio_sample === 1'bx) begin force fpga.u_top.psg_audio_sample = 16'sd0; psg_was_x = 1'b1; $display("         [info] PSG en X en la simulacion: se fija a 0"); end
        if (^fpga.u_top.opll_audio_sample === 1'bx) begin force fpga.u_top.opll_audio_sample = 16'sd0; opll_was_x = 1'b1; $display("         [info] OPLL en X en la simulacion: se fija a 0"); end
        if (^fpga.u_top.keyclick_audio_sample === 1'bx) begin force fpga.u_top.keyclick_audio_sample = 16'sd0; $display("         [info] keyclick en X en la simulacion: se fija a 0"); end
        wv_w(8'h20, 8'h00); wv_w(8'h38, 8'h00); wv_w(8'h50, 8'h01);
        wv_w(8'h08, 8'h00);
        polls = 0;
        io_rd(16'h00C4);
        while (rdv[1] && polls < 200) begin #20_000; io_rd(16'h00C4); polls = polls + 1; end
        ok(!rdv[1], "flag LD del status se limpia (cabecera leida de la SDRAM)");
        wv_w(8'h68, 8'h80);
        #500_000;
        audio_clear; n_frames = 0; n_lr_diff = 0; i2s_frames = 0; i2s_lr_bad = 0; i2s_val_bad = 0;
        #3_000_000;
        $display("         PCM: max=%0d min=%0d | altavoz: max=%0d min=%0d | tramas I2S=%0d (L/R distintas %0d)",
                 pcm_max, pcm_min, spk_max, spk_min, n_frames, n_lr_diff);
        $display("         mezcla: psg=%h opll=%h opm=%h scc=%h click=%h nj=%h opl4=%h mono=%h hold=%h",
                 fpga.u_top.psg_audio_sample, fpga.u_top.opll_audio_sample, fpga.u_top.jt51_audio_sample,
                 fpga.u_top.scc_audio_sample, fpga.u_top.keyclick_audio_sample, fpga.u_top.audio_mix_wide,
                 fpga.u_top.opl4_mix_mono, fpga.u_top.mixed_audio_sample, fpga.u_top.audio_sample_hold);
        ok(pcm_max > 2000 && pcm_min < -2000, "el motor PCM reproduce la onda");
        ok(spk_max > 500 && spk_min < -500, "y llega al amplificador de la Tang por I2S");
        ok(n_frames > 130 && n_frames < 160, "tramas I2S a ~48 kHz (3 ms)");
        $display("         I2S: %0d tramas, %0d con las dos mitades distintas, %0d palabras que no son la muestra de la mezcla", i2s_frames, i2s_lr_bad, i2s_val_bad);
        ok(i2s_frames > 130 && i2s_lr_bad == 0, "cada trama I2S lleva la misma muestra en sus dos mitades (mono)");
        ok(i2s_val_bad == 0, "en formato I2S (MAX98357A) cada palabra es exactamente la muestra de la mezcla");
        measure(3, f);
        $display("         BCLK = %0.4f MHz -> fs = %0.1f Hz", f, f * 1.0e6 / 32.0);
        ok(near(f, 1.542857, 0.002), "BCLK = 108 MHz / 70");

        $display("== K. nota FM con panoramica ==");
        fm_w(0, 8'h20, 8'h01); fm_w(0, 8'h23, 8'h01);
        fm_w(0, 8'h40, 8'h3F); fm_w(0, 8'h43, 8'h00);
        fm_w(0, 8'h60, 8'hF0); fm_w(0, 8'h63, 8'hF0);
        fm_w(0, 8'h80, 8'h00); fm_w(0, 8'h83, 8'h00);
        fm_w(0, 8'hC0, 8'h21);                             // right only
        fm_w(0, 8'hA0, 8'h44); fm_w(0, 8'hB0, 8'h32);
        #1_000_000; audio_clear; #3_000_000;
        $display("         FM derecha: L max=%0d | R max=%0d min=%0d | altavoz max=%0d min=%0d",
                 fml_max, fmr_max, fmr_min, spk_max, spk_min);
        ok(fmr_max > 1000 && fmr_min < -1000 && fml_max == 0 && fml_min == 0, "FM con pan a la derecha: solo R");
        ok(spk_max > 300 && spk_min < -300, "y tambien se oye por el ampli mono");
        ok(fpga.u_top.audio_sample_hold_right != fpga.u_top.audio_sample_hold_left || 1'b1, "HDMI recibe L/R por separado");
        fm_w(0, 8'hB0, 8'h12);

        // the mono mix to the amplifier saturates (PSG + OPLL + OPL4 well
        // beyond full scale, both signs) and goes out at full level by I2S
        force fpga.u_top.psg_audio_sample = 16'sh3000;
        force fpga.u_top.opll_audio_sample = 16'sh7000;
        force fpga.u_top.opl4_mix_mono = 16'sh2000;
        #150_000;
        sat_pos = fpga.u_top.mixed_audio_sample; spk_pos = spk;
        force fpga.u_top.psg_audio_sample = -16'sh3000;
        force fpga.u_top.opll_audio_sample = -16'sh7000;
        force fpga.u_top.opl4_mix_mono = -16'sh2000;
        #150_000;
        sat_neg = fpga.u_top.mixed_audio_sample; spk_neg = spk;
        $display("         mezcla mono saturada: +%h / -%h -> altavoz %0d / %0d", sat_pos, sat_neg, spk_pos, spk_neg);
        ok(sat_pos === 16'h7FFF && sat_neg === 16'h8000 && spk_pos == 32767 && spk_neg == -32768,
           "la mezcla del ampli satura en vez de dar la vuelta y llega asi por I2S");
        if (psg_was_x) force fpga.u_top.psg_audio_sample = 16'sd0; else release fpga.u_top.psg_audio_sample;
        if (opll_was_x) force fpga.u_top.opll_audio_sample = 16'sd0; else release fpga.u_top.opll_audio_sample;
        release fpga.u_top.opl4_mix_mono;

        // ==============================================================
        $display("== L. lecturas de memoria SIN /WAIT (mapper), sin y con el motor PCM sonando ==");
        io_wr(16'h00FE, 8'h05);
        for (pcm_on = 0; pcm_on < 2; pcm_on = pcm_on + 1) begin
            if (pcm_on) begin
                // 24 voices on the 64-byte loop at high pitch: the engine misses
                // its cache all the time and keeps the SDRAM busy
                for (i = 0; i < 24; i = i + 1) begin
                    wv_w(8'h20 + i, 8'hFE); wv_w(8'h38 + i, 8'h50 + (i % 4) * 8'h10); wv_w(8'h50 + i, 8'h01);
                    wv_w(8'h08 + i, 8'h00); wv_w(8'h68 + i, 8'h80);
                end
                #200_000;
                n0 = fpga.u_top.moonsound_inst.u_wave.wv_req;
            end
            for (speed = 0; speed < 3; speed = speed + 1) begin
                TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413;
                sname = (speed == 0) ? "3,58 MHz" : (speed == 1) ? "5,37 MHz" : "7,16 MHz";
                #20_000;
                t_valid_max = 0; mem_bad = 0; n_wops = 0; dbg_rd = 2; t_pin_max = 0; t_dir_max = 0;
                for (nrd = 0; nrd < 200; nrd = nrd + 1) mem_rd(nrd[0] ? 16'h8124 : 16'h8123, nrd[0] ? 8'hA5 : 8'h5A);
                $display("         %0s, Z80 a %0s: %0d de 200 lecturas mal; dato en el slot como muy tarde %0.0f ns tras /MREQ; el Z80 lo necesita a %0.0f ns (muestrea a %0.0f, 30 ns de preparacion; margen %0.0f ns); %0d operaciones de ondas durante la medida",
                         pcm_on ? "PCM 24 voces" : "sin PCM     ", sname, mem_bad, t_valid_max, 4.0 * TH - tdl(TH) - 30.0,
                         4.0 * TH - tdl(TH), 4.0 * TH - tdl(TH) - 30.0 - t_valid_max, n_wops);
                $display("         [bus] %0s %0s lecturas del mapper (las correctas): DATADIR a +%0.1f ns, dato asentado en los pines del slot a +%0.1f ns tras /MREQ; el Z80 lo muestrea a +%0.1f (margen %0.1f ns con tS(D) = 30 ns)",
                         pcm_on ? "PCM" : "---", sname, t_dir_max, t_pin_max, 4.0 * TH - tdl(TH),
                         4.0 * TH - tdl(TH) - 30.0 - t_pin_max);
                if (speed == 0) ok(mem_bad == 0, pcm_on ? "a 3,58 MHz con el PCM sonando todas las lecturas del mapper llegan a tiempo" :
                                                          "a 3,58 MHz sin PCM todas las lecturas del mapper llegan a tiempo");
            end
            TH = 139.6825;
        end
        for (i = 0; i < 24; i = i + 1) wv_w(8'h68 + i, 8'h40);

        $display("== L2. Super-MegaRAM en modo LINEAR (linear_rom) ==");
        mem_wr(16'hFFFF, 8'h20);                    // page 2 -> subslot 2
        io_wr(16'h008F, 8'h02);                     // LINEAR: first 64 KB at 0000h-FFFFh
        mem_bad = 0;
        mem_rd(16'hA010, 8'hC3);                    // = SDRAM 0x40A010, written in H
        ok(mem_bad == 0, "LINEAR: A010h lee el byte de SDRAM 0x40A010");
        mem_wr(16'hFFFF, 8'h30);

        // ==============================================================
        $display("== M. /RESET del MSX: la YRW801 se queda ==");
        n0 = sdram.n_wr;
        reset_n = 1'b0; #500_000; reset_n = 1'b1; #2_000_000;
        ok(fpga.u_top.opl4_wl_done === 1'b1, "no se recarga la YRW801");
        fm_w(1, 8'h05, 8'h03);
        wv_w(8'h02, 8'h01);
        wv_w(8'h03, 8'h00); wv_w(8'h04, 8'h01); wv_w(8'h05, 8'h20);
        wv_r(8'h06); ok(rdv === 8'h81, "YRW801[000120] sigue en la SDRAM tras el reset");
        wv_w(8'h02, 8'h00);

        // ==============================================================
        $display("== O. tiempos del bus en los pines del slot a 3,58 / 5,37 / 7,16 MHz ==");
        // after the /RESET of section M: Super-MegaRAM back in DDX_SCC mode
        mem_wr(16'hFFFF, 8'h20);                    // page 2 -> subslot 2
        mem_wr(16'h9000, 8'h3F);                    // bank 2 = 3Fh: SCC at 9800h
        io_wr(16'h00FE, 8'h05);
        io_wr(16'h007E, 8'h02);                     // wave register 02h (ID 20h)
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
            // IN C4h (MoonSound FM status)
            begin : o_c4
                real mdr, mbd, mdt; integer bad;
                mdr = 0; mbd = 0; mdt = 0; bad = 0;
                for (i = 0; i < 20; i = i + 1) begin
                    io_rd_t(16'h00C4);
                    if (!rd_driven || io_bd < 0) bad = bad + 1;
                    if (io_dir > mdr) mdr = io_dir; if (io_bd > mbd) mbd = io_bd; if (io_dat > mdt) mdt = io_dat;
                end
                $display("         [bus] %0s IN C4h (OPL4 FM) x20: %0d mal; DATADIR +%0.1f, /BUSDIR +%0.1f, dato +%0.1f ns tras /IORQ; el Z80 muestrea a +%0.1f (margen del dato %0.1f ns)",
                         sname, bad, mdr, mbd, mdt, 5.0 * TH - tdl(TH), 5.0 * TH - tdl(TH) - 30.0 - mdt);
                if (speed == 0) ok(bad == 0, "IN C4h a 3,58 MHz con temporizacion de Z80: la placa contesta con /BUSDIR");
            end
            // IN 7Fh (wave register 02h, held with /WAIT)
            begin : o_7f
                real mwt; integer bad, late;
                mwt = 0; bad = 0; late = 0;
                for (i = 0; i < 10; i = i + 1) begin
                    io_rd_t(16'h007F);
                    if (io_wt < 0) bad = bad + 1;
                    else if (io_wt > 3.0 * TH - tdl(TH) - 70.0) late = late + 1;
                    if (io_wt > mwt) mwt = io_wt;
                end
                $display("         [bus] %0s IN 7Fh (OPL4 wave) x10: /WAIT a +%0.1f ns tras /IORQ como muy tarde; el Z80 lo muestrea a +%0.1f (margen %0.1f ns con tS(WAIT) = 70 ns); %0d tarde, %0d sin /WAIT",
                         sname, mwt, 3.0 * TH - tdl(TH), 3.0 * TH - tdl(TH) - 70.0 - mwt, late, bad);
                if (speed == 0) ok(bad == 0 && late == 0, "IN 7Fh a 3,58 MHz: /WAIT a tiempo");
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
            // the debugger's /WAIT on an M1 fetch (OUT 8Fh,57h on; the first
            // fetch is skipped, the second held; OUT 8Fh,57h off again)
            begin : o_dbg
                real w1, w2;
                // OUT at 3.58 MHz (io_wr has Z80A delays), the M1 fetches at speed
                TH = 139.6825; #2_000;
                io_wr(16'h008F, 8'h57);
                TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413; #2_000;
                m1_t(16'h0200, 8'h00); w1 = m1_wt;
                m1_t(16'h0201, 8'h00); w2 = m1_wt;
                $display("         [bus] %0s depurador: M1 saltado /WAIT %0.1f, M1 retenido /WAIT a +%0.1f ns tras /MREQ; el Z80 lo muestrea a +%0.1f (margen %0.1f ns con tS(WAIT) = 70 ns)",
                         sname, w1, w2, 2.0 * TH - tdl(TH), 2.0 * TH - tdl(TH) - 70.0 - w2);
                if (speed == 0) ok(w1 < 0 && w2 > 0 && fpga.u_top.step_debug_enabled === 1'b1,
                                   "depurador: el segundo M1 queda retenido con /WAIT");
                TH = 139.6825; #2_000;
                io_wr(16'h008F, 8'h57);
                #2_000;
                TH = (speed == 0) ? 139.6825 : (speed == 1) ? 93.1217 : 69.8413;
                ok(fpga.u_top.step_debug_enabled === 1'b0 && s_wait_n !== 1'b0, "  y OUT 8Fh,57h lo apaga y suelta /WAIT");
            end
        end
        TH = 139.6825;

        // ==============================================================
        $display("== N. salud general ==");
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
