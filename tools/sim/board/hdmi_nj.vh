// ============================================================================
// hdmi_nj.vh - HDMI of the fork on the board bench (run_board.sh hdmi).
//
// Included in tb_nj_board.v when it is compiled with -DWITH_HDMI. Then the
// video PLL is NOT held in reset: New Juice starts it, as on the board, once
// its modules are released after the MSX /RESET, and the whole HDMI chain
// runs (vu_meter, vu_screen, the debugger terminal, the hdmi transmitter).
//
// The verification receiver (../common/hdmi_rx_check.v, written from the
// HDMI / DVI / CEA-861 / IEC 60958 texts, nothing shared with the
// transmitter) takes the three 10-bit TMDS symbols at the input of the
// serializer and decodes video, packets and audio (the serializer itself is
// not simulated: its 135 MHz clock is held at 0). This file checks:
//
//   V1  every pixel on the cable is the pixel the design gave the
//       transmitter (by coordinate);
//   V2  each complete VU frame on the cable, written to build/<tag>_f<n>.ppm,
//       is pixel for pixel what ../vu/vu_check.py draws from the levels shown
//       in that frame (run_board.sh runs it after the simulation);
//   V3  the levels shown are the right ones: an independent model of the
//       meter (log-scale segments computed with integer arithmetic, the
//       ballistics of the vu_meter.v header) is fed from the SOURCES of the
//       six bars (FM and wave halves inside moonsound_nj, the samples HDMI
//       plays) and must give, frame after frame, the levels and peak marks
//       the screen draws. If a bar were fed from another signal, this fails
//       (run_board.sh hdmi runs two negative controls: the FM R bar fed from
//       wave R, and wave L and wave R swapped; the wave is panned so that
//       its two sides differ);
//   V4  with the debugger on (OUT 8Fh,57h, New Juice's software toggle) the
//       frame on the cable is the debugger terminal pixel for pixel (white on
//       black) and nothing of the VU meter;
//   A   the audio on the cable is, sample by sample and on its own channel,
//       what the transmitter took (44.1 kHz stereo, left differs from right);
//   P   720x480p geometry, ACR (N 6272, CTS 29988), channel status, AVI
//       (VIC 2, picture aspect "no data", as New Juice sends it), Audio
//       InfoFrame, and no protocol error (BCH, checksums, parity, TMDS codes).
//
// The copy of hdl-util/hdmi in New Juice has the same known deviations from
// CEA-861 as MoonTANG's (front porches of 15 px and 10 lines instead of 16
// and 9, a short control period): they are accepted here (ESTRICTO = 0), as
// in MoonTANG's hdmi_rx_hookup.vh, which this file adapts.
// ============================================================================

`ifndef HDMI_TAG
`define HDMI_TAG "hdmi"
`endif

    // ------------------------------------------------------------------
    //  Receiver
    // ------------------------------------------------------------------
    wire        hrx_hsync, hrx_vsync, hrx_de, hrx_en_cuadro, hrx_nuevo_cuadro, hrx_aud_valid;
    wire [3:0]  hrx_ctl;
    wire [23:0] hrx_rgb, hrx_aud_l, hrx_aud_r;
    wire [15:0] hrx_px, hrx_py;
    wire        hrx_rst = (fpga.u_top.sms_reset_n !== 1'b1);

    hdmi_rx_check #(.VERBOSE(1), .ESTRICTO(0)) rx (
        .clk_pixel (fpga.u_top.clk), .rst (hrx_rst),
        .tmds0 (fpga.u_top.hdmi_tmds_internal[ 9: 0]),
        .tmds1 (fpga.u_top.hdmi_tmds_internal[19:10]),
        .tmds2 (fpga.u_top.hdmi_tmds_internal[29:20]),
        .hsync (hrx_hsync), .vsync (hrx_vsync), .ctl (hrx_ctl),
        .de (hrx_de), .rgb (hrx_rgb), .px (hrx_px), .py (hrx_py), .en_cuadro (hrx_en_cuadro),
        .nuevo_cuadro (hrx_nuevo_cuadro),
        .aud_valid (hrx_aud_valid), .aud_l (hrx_aud_l), .aud_r (hrx_aud_r)
    );

    // ------------------------------------------------------------------
    //  What enters the transmitter, by coordinate. Read on the FALLING edge
    //  of the pixel clock: rgb is the pixel of the cx/cy of the cycle before.
    //  The debugger terminal pixel is kept apart, with the same timing.
    // ------------------------------------------------------------------
    reg [23:0] hrx_fb [0:720*480-1];
    reg        hrx_tt [0:720*480-1];
    reg [9:0]  hrx_cx = 10'h3FF, hrx_cy = 10'h3FF;
    always @(negedge fpga.u_top.clk) begin
        if (hrx_cx < 720 && hrx_cy < 480) begin
            hrx_fb[hrx_cy * 720 + hrx_cx] = {fpga.u_top.hdmi_red, fpga.u_top.hdmi_green, fpga.u_top.hdmi_blue};
            hrx_tt[hrx_cy * 720 + hrx_cx] = fpga.u_top.sms_debug_terminal_pixel;
        end
        hrx_cx = fpga.u_top.hdmi_x;
        hrx_cy = fpga.u_top.hdmi_y;
    end

    // ------------------------------------------------------------------
    //  Independent model of the meter (V3), on the meter's clock. The window
    //  boundary is the design's frame tick (one per video frame); everything
    //  else is computed here from the sources of the six bars.
    // ------------------------------------------------------------------
    wire [15:0] vr_src0 = fpga.u_top.moonsound_inst.fm_l;     // FM L, after F8h, as mixed
    wire [15:0] vr_src1 = fpga.u_top.moonsound_inst.fm_r;
    wire [15:0] vr_src2 = fpga.u_top.moonsound_inst.wave_l;   // wave L, as mixed
    wire [15:0] vr_src3 = fpga.u_top.moonsound_inst.wave_r;
    wire [15:0] vr_src4 = fpga.u_top.hdmi_mix_louder_sample;  // what HDMI plays, L
    wire [15:0] vr_src5 = fpga.u_top.hdmi_mix_louder_sample_right;
    wire [95:0] vr_src  = {vr_src5, vr_src4, vr_src3, vr_src2, vr_src1, vr_src0};

    function integer vr_mag(input [15:0] s);       // |s|, -32768 -> 32767
        begin
            if (!s[15])                vr_mag = s;
            else if (s == 16'h8000)    vr_mag = 32767;
            else                       vr_mag = 65536 - s;
        end
    endfunction
    function integer vr_segs(input integer m);     // 1.5 dB steps, 28 = full scale
        integer p, lv;
        begin
            if (m <= 0) vr_segs = 0;
            else begin
                p = 0;
                while ((1 << (p + 1)) <= m) p = p + 1;           // floor(log2 m)
                lv = 4 * p + (((m - (1 << p)) * 4) >> p);        // + quarter octaves
                vr_segs = (lv >= 32) ? lv - 31 : 0;
            end
        end
    endfunction

    integer vr_pk [0:5], vr_lvl [0:5], vr_hld [0:5], vr_tmr [0:5];
    integer vr_ch, vr_now, vr_m, vr_ntick = 0, vr_x = 0;
    reg     vr_odd = 1'b0;
    initial for (vr_ch = 0; vr_ch < 6; vr_ch = vr_ch + 1) begin
        vr_pk[vr_ch] = 0; vr_lvl[vr_ch] = 0; vr_hld[vr_ch] = 0; vr_tmr[vr_ch] = 0;
    end
    always @(posedge fpga.u_top.opl4_clk54) begin
        if (fpga.u_top.sms_reset_n === 1'b1 && ^vr_src === 1'bx) vr_x = vr_x + 1;   // while frames are measured
        if (fpga.u_top.vu_meter_inst.tick === 1'b1) begin
            for (vr_ch = 0; vr_ch < 6; vr_ch = vr_ch + 1) begin
                vr_now = vr_segs(vr_pk[vr_ch]);
                if (vr_now >= vr_lvl[vr_ch])                   vr_lvl[vr_ch] = vr_now;
                else if (vr_odd && vr_lvl[vr_ch] != 0)         vr_lvl[vr_ch] = vr_lvl[vr_ch] - 1;
                if (vr_now >= vr_hld[vr_ch]) begin
                    vr_hld[vr_ch] = vr_now; vr_tmr[vr_ch] = 45;
                end
                else if (vr_tmr[vr_ch] != 0)                   vr_tmr[vr_ch] = vr_tmr[vr_ch] - 1;
                else if (vr_odd && vr_hld[vr_ch] != 0)         vr_hld[vr_ch] = vr_hld[vr_ch] - 1;
                vr_pk[vr_ch] = vr_mag(vr_src[vr_ch*16 +: 16]);
            end
            vr_odd   = !vr_odd;
            vr_ntick = vr_ntick + 1;
        end
        else begin
            for (vr_ch = 0; vr_ch < 6; vr_ch = vr_ch + 1) begin
                vr_m = vr_mag(vr_src[vr_ch*16 +: 16]);
                if (vr_m > vr_pk[vr_ch]) vr_pk[vr_ch] = vr_m;
            end
        end
    end

    // ------------------------------------------------------------------
    //  Frames on the cable (V1, V2, V3, V4)
    // ------------------------------------------------------------------
    reg [23:0] hrx_fr [0:720*480-1];               // the frame being received
    integer hrx_pix_ok = 0, hrx_pix_mal = 0, hrx_npix = 0;
    integer hrx_nfr = 0, hrx_nvu = 0, hrx_ndbg = 0;
    integer hrx_lvl_mal = 0, hrx_st_mal = 0, hrx_dbg_mal = 0, hrx_dbg_white = 0, hrx_dbg_vu = 0, hrx_mixed = 0;
    integer hrx_k, hrx_fd, hrx_fl;
    reg [29:0] hrx_s_lvl, hrx_s_pk;
    reg [1:0]  hrx_s_rom;
    reg        hrx_s_msx, hrx_s_dbg, hrx_s_dbg_end;
    integer    hrx_e_lvl [0:5], hrx_e_hld [0:5];
    reg [8*64-1:0] hrx_name, hrx_path;
    reg [23:0] hrx_c;
    initial begin
        hrx_fl = $fopen({"build/", `HDMI_TAG, "_frames.txt"}, "w");
    end

    always @(negedge fpga.u_top.clk) if (hrx_de && hrx_en_cuadro) begin
        // V1: the pixel on the cable is the one the design sent
        if (hrx_px < 720 && hrx_py < 480 && hrx_rgb === hrx_fb[hrx_py * 720 + hrx_px])
            hrx_pix_ok = hrx_pix_ok + 1;
        else begin
            hrx_pix_mal = hrx_pix_mal + 1;
            if (hrx_pix_mal <= 4)
                $display("  [hdmi] pixel (%0d,%0d): recibido %06h, enviado %06h",
                         hrx_px, hrx_py, hrx_rgb, hrx_fb[hrx_py * 720 + hrx_px]);
        end
        // what the frame shows, sampled at its first pixel and in its middle:
        // the meter outputs only change in the vertical blanking
        if (hrx_px == 0 && hrx_py == 0) begin
            hrx_npix = 0;
            hrx_s_dbg = fpga.u_top.step_debug_enabled;
        end
        if (hrx_px < 720 && hrx_py < 480) begin
            hrx_fr[hrx_py * 720 + hrx_px] = hrx_rgb;
            hrx_npix = hrx_npix + 1;
            // V4 reference: the terminal pixel sent for this coordinate
            if (hrx_s_dbg && hrx_rgb !== {24{hrx_tt[hrx_py * 720 + hrx_px]}}) hrx_dbg_mal = hrx_dbg_mal + 1;
        end
        if (hrx_px == 0 && hrx_py == 240) begin
            hrx_s_lvl = fpga.u_top.vu_level;
            hrx_s_pk  = fpga.u_top.vu_peak;
            hrx_s_rom = fpga.u_top.vu_st_rom;
            hrx_s_msx = fpga.u_top.vu_st_msx;
            for (hrx_k = 0; hrx_k < 6; hrx_k = hrx_k + 1) begin
                hrx_e_lvl[hrx_k] = vr_lvl[hrx_k];
                hrx_e_hld[hrx_k] = vr_hld[hrx_k];
            end
        end
        // last pixel of the frame: the frame is complete
        if (hrx_px == 719 && hrx_py == 479) begin
            hrx_s_dbg_end = fpga.u_top.step_debug_enabled;
            hrx_nfr = hrx_nfr + 1;
            if (hrx_npix != 720 * 480 || hrx_s_dbg_end !== hrx_s_dbg) begin
                hrx_mixed = hrx_mixed + 1;
                $display("  [hdmi] cuadro %0d incompleto o con cambio de modo: %0d pixeles, depurador %b -> %b",
                         hrx_nfr, hrx_npix, hrx_s_dbg, hrx_s_dbg_end);
            end
            else if (!hrx_s_dbg) begin
                // V2: dump it for vu_check.py; V3: the levels shown are the model's
                hrx_nvu = hrx_nvu + 1;
                $sformat(hrx_name, "%0s_f%0d.ppm", `HDMI_TAG, hrx_nfr);
                $sformat(hrx_path, "build/%0s", hrx_name);
                hrx_fd = $fopen(hrx_path, "wb");
                $fwrite(hrx_fd, "P6\n720 480\n255\n");
                for (hrx_k = 0; hrx_k < 720 * 480; hrx_k = hrx_k + 1) begin
                    hrx_c = hrx_fr[hrx_k];
                    $fwrite(hrx_fd, "%c%c%c", hrx_c[23:16], hrx_c[15:8], hrx_c[7:0]);
                end
                $fclose(hrx_fd);
                $fdisplay(hrx_fl, "%0s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", hrx_name,
                          hrx_s_lvl[4:0], hrx_s_lvl[9:5], hrx_s_lvl[14:10], hrx_s_lvl[19:15], hrx_s_lvl[24:20], hrx_s_lvl[29:25],
                          hrx_s_pk[4:0],  hrx_s_pk[9:5],  hrx_s_pk[14:10],  hrx_s_pk[19:15],  hrx_s_pk[24:20],  hrx_s_pk[29:25],
                          hrx_s_rom, hrx_s_msx);
                $fflush(hrx_fl);
                $display("  [hdmi] cuadro %0d (vumetro) -> build/%0s: barras %0d %0d %0d %0d %0d %0d, picos %0d %0d %0d %0d %0d %0d, YRW801 %0d, MSX %0d",
                         hrx_nfr, hrx_name,
                         hrx_s_lvl[4:0], hrx_s_lvl[9:5], hrx_s_lvl[14:10], hrx_s_lvl[19:15], hrx_s_lvl[24:20], hrx_s_lvl[29:25],
                         hrx_s_pk[4:0],  hrx_s_pk[9:5],  hrx_s_pk[14:10],  hrx_s_pk[19:15],  hrx_s_pk[24:20],  hrx_s_pk[29:25],
                         hrx_s_rom, hrx_s_msx);
                $display("         modelo del medidor:            barras %0d %0d %0d %0d %0d %0d, picos %0d %0d %0d %0d %0d %0d",
                         hrx_e_lvl[0], hrx_e_lvl[1], hrx_e_lvl[2], hrx_e_lvl[3], hrx_e_lvl[4], hrx_e_lvl[5],
                         hrx_e_hld[0], hrx_e_hld[1], hrx_e_hld[2], hrx_e_hld[3], hrx_e_hld[4], hrx_e_hld[5]);
                for (hrx_k = 0; hrx_k < 6; hrx_k = hrx_k + 1)
                    if (hrx_s_lvl[hrx_k*5 +: 5] !== hrx_e_lvl[hrx_k] || hrx_s_pk[hrx_k*5 +: 5] !== hrx_e_hld[hrx_k])
                        hrx_lvl_mal = hrx_lvl_mal + 1;
                if (hrx_s_rom !== 2'd1 || hrx_s_msx !== 1'b1) hrx_st_mal = hrx_st_mal + 1;
            end
            else begin
                // V4: the debugger owns the frame
                hrx_ndbg = hrx_ndbg + 1;
                for (hrx_k = 0; hrx_k < 720 * 480; hrx_k = hrx_k + 1) begin
                    if (hrx_fr[hrx_k] === 24'hFFFFFF) hrx_dbg_white = hrx_dbg_white + 1;
                    else if (hrx_fr[hrx_k] !== 24'h000000) hrx_dbg_vu = hrx_dbg_vu + 1;
                end
                $display("  [hdmi] cuadro %0d (depurador): %0d pixeles blancos, %0d que no son blanco ni negro, %0d distintos del terminal",
                         hrx_nfr, hrx_dbg_white, hrx_dbg_vu, hrx_dbg_mal);
            end
            hrx_npix = 0;
        end
    end

    // ------------------------------------------------------------------
    //  Audio (A): what the transmitter takes on each rising edge of its audio
    //  clock, and what comes out of the receiver
    // ------------------------------------------------------------------
    localparam integer HRX_N = 16384;
    reg [15:0] hrx_tx_l [0:HRX_N-1], hrx_tx_r [0:HRX_N-1];
    reg [15:0] hrx_rx_l [0:HRX_N-1], hrx_rx_r [0:HRX_N-1];
    integer    hrx_n_tx = 0, hrx_n_rx = 0, hrx_bajos = 0, hrx_tx_x = 0, hrx_tx_on = -1;
    always @(posedge fpga.u_top.hdmi_audio_clk) if (hrx_n_tx < HRX_N) begin
        hrx_tx_l[hrx_n_tx] = fpga.u_top.hdmi_mix_sample;
        hrx_tx_r[hrx_n_tx] = fpga.u_top.hdmi_mix_sample_right;
        if (fpga.u_top.sms_reset_n === 1'b1 && hrx_tx_on < 0) hrx_tx_on = hrx_n_tx;
        if (fpga.u_top.sms_reset_n === 1'b1 && ^{fpga.u_top.hdmi_mix_sample, fpga.u_top.hdmi_mix_sample_right} === 1'bx)
            hrx_tx_x = hrx_tx_x + 1;
        hrx_n_tx = hrx_n_tx + 1;
    end
    always @(negedge fpga.u_top.clk) if (hrx_aud_valid && hrx_n_rx < HRX_N) begin
        hrx_rx_l[hrx_n_rx] = hrx_aud_l[23:8];
        hrx_rx_r[hrx_n_rx] = hrx_aud_r[23:8];
        if (hrx_aud_l[7:0] !== 8'h00 || hrx_aud_r[7:0] !== 8'h00) hrx_bajos = hrx_bajos + 1;
        hrx_n_rx = hrx_n_rx + 1;
    end

    // ------------------------------------------------------------------
    //  New Juice sources that stay X in Icarus after sv2v (SCC wave RAM, JT51
    //  tables, PSG, OPLL; see section J of tb_nj_board.v) would turn the whole
    //  HDMI mix into X. Here they are pinned to 0 from the start: this bench
    //  is about the OPL4, the meter and the picture.
    // ------------------------------------------------------------------
    initial begin
        // The serializer is not simulated: the receiver takes the 10-bit
        // symbols at its input, and its 135 MHz clock (used by nothing else)
        // would only slow the simulation down.
        force fpga.u_top.video_clk_135 = 1'b0;
        // New Juice's copy of hdl-util/hdmi has no initial value on this
        // output flip-flop (Gowin refuses one on an output port). On the FPGA
        // it starts at 0 like every flip-flop; in Icarus it would stay X and
        // no Audio Clock Regeneration packet would ever be sent.
        fpga.u_top.hdmi_inst.true_hdmi_output.packet_picker.audio_clock_regeneration_packet.clk_audio_counter_wrap = 1'b0;
        force fpga.u_top.scc_audio_sample = 16'sd0;
        force fpga.u_top.jt51_audio_sample = 16'sd0;
        force fpga.u_top.psg_audio_sample = 16'sd0;
        force fpga.u_top.opll_audio_sample = 16'sd0;
        force fpga.u_top.keyclick_audio_sample = 16'sd0;
    end

    // ------------------------------------------------------------------
    //  The test, after the MSX is on (section B of tb_nj_board.v)
    // ------------------------------------------------------------------
    integer hk, hi, hrx_k0, hrx_casan, hrx_mal, hrx_lr, hrx_amax, hrx_en_vuelo;
    realtime hrx_t0;
    task hdmi_test;
        begin
            $display("== H1. HDMI: New Juice arranca el PLL de video tras soltar sus modulos ==");
            fork : hv
                begin wait (fpga.u_top.sms_reset_n === 1'b1); disable hv; end
                begin #5_000_000; disable hv; end
            join
            ok(fpga.u_top.rpll_video_lock === 1'b1 && fpga.u_top.sms_reset_n === 1'b1,
               "el PLL de video engancha y el transmisor HDMI sale de reset");
            hrx_t0 = $realtime;
            $display("         HDMI en marcha en t = %0.2f ms", hrx_t0 / 1.0e6);

            $display("== H2. sonido: onda PCM a los dos lados (12 dB menos a la izquierda), FM solo a la izquierda ==");
            fm_w(1, 8'h05, 8'h03);                             // NEW + NEW2: OPL3 panning, wave part on
            wv_w(8'h20, 8'h00); wv_w(8'h38, 8'h00); wv_w(8'h50, 8'h01);
            wv_w(8'h08, 8'h00);
            polls = 0;
            io_rd(16'h00C4);
            while (rdv[1] && polls < 200) begin #20_000; io_rd(16'h00C4); polls = polls + 1; end
            ok(!rdv[1], "flag LD del status se limpia (cabecera leida de la SDRAM)");
            // key on, panpot 1: in this core (ymf278b_gowin.v) the left side
            // 12 dB down, so that wave L and wave R differ by 8 segments and a
            // swap of the two shows on the meter (run_board.sh hdmi checks it)
            wv_w(8'h68, 8'h81);
            fm_w(0, 8'h20, 8'h01); fm_w(0, 8'h23, 8'h01);
            fm_w(0, 8'h40, 8'h3F); fm_w(0, 8'h43, 8'h00);
            fm_w(0, 8'h60, 8'hF0); fm_w(0, 8'h63, 8'hF0);
            fm_w(0, 8'h80, 8'h00); fm_w(0, 8'h83, 8'h00);
            fm_w(0, 8'hC0, 8'h11);                             // left only
            fm_w(0, 8'hA0, 8'h44); fm_w(0, 8'hB0, 8'h32);
            $display("         sonando en t = %0.2f ms", $realtime / 1.0e6);

            // FM muted (F8h = 3Fh) before the first frame tick: the second
            // frame shows the FM bar falling and its peak mark held
            wait (fpga.u_top.hdmi_y >= 10'd400 && fpga.u_top.hdmi_y < 10'd480);
            ok(vr_ntick == 0, "todavia en el primer cuadro (antes del primer tick del medidor)");
            wv_w(8'hF8, 8'h3F);
            $display("         FM silenciada (F8h = 3Fh) en t = %0.2f ms, linea %0d", $realtime / 1.0e6, fpga.u_top.hdmi_y);

            // the debugger on right after the third tick (vertical blanking
            // of the design's frame 2): frame 3 is the terminal
            wait (vr_ntick >= 3);
            io_wr(16'h008F, 8'h57);
            #2_000;
            $display("         depurador (OUT 8Fh,57h) en t = %0.2f ms, linea %0d: enabled = %b",
                     $realtime / 1.0e6, fpga.u_top.hdmi_y, fpga.u_top.step_debug_enabled);
            ok(fpga.u_top.step_debug_enabled === 1'b1, "OUT 8Fh,57h enciende el depurador de New Juice");
            ok(fpga.u_top.hdmi_y >= 10'd480, "y lo hace en el borrado vertical (el cuadro siguiente es entero suyo)");

            fork : frames
                begin wait (hrx_nvu + hrx_ndbg + hrx_mixed >= 3); disable frames; end
                begin #60_000_000; disable frames; end
            join
            #1_000;

            $display("== H3. lo que llega por el cable (receptor de verificacion) ==");
            rx.informe;
            rx.comprobar_geometria(858, 525, 720, 480, 15, 62, 10, 6, 1, 1);
            rx.comprobar_acr(6272, 29988, 1);      // 44.1 kHz: 27 MHz / 612, both from the 27 MHz clock
            rx.comprobar_estado_canal(44100, 16);
            rx.comprobar_avi(2, 0);                 // VIC 2, aspect "no data" (M = 0), as New Juice sends it
            rx.comprobar_aif;
            rx.comprobar_presencia;

            hrx_k0 = -1; hrx_casan = 0;
            for (hk = 0; hk <= hrx_tx_on + 32 && hk < hrx_n_tx; hk = hk + 1) begin
                hrx_mal = 0;
                for (hi = 0; hi < hrx_n_rx && hk + hi < hrx_n_tx; hi = hi + 1)
                    if (hrx_rx_l[hi] !== hrx_tx_l[hk + hi] || hrx_rx_r[hi] !== hrx_tx_r[hk + hi]) hrx_mal = hrx_mal + 1;
                if (hrx_mal == 0) begin hrx_casan = hrx_casan + 1; if (hrx_k0 < 0) hrx_k0 = hk; end
            end
            hrx_lr = 0; hrx_amax = 0;
            for (hi = 0; hi < hrx_n_rx; hi = hi + 1) begin
                if (hrx_rx_l[hi] !== hrx_rx_r[hi]) hrx_lr = hrx_lr + 1;
                if (vr_mag(hrx_rx_l[hi]) > hrx_amax) hrx_amax = vr_mag(hrx_rx_l[hi]);
                if (vr_mag(hrx_rx_r[hi]) > hrx_amax) hrx_amax = vr_mag(hrx_rx_r[hi]);
            end
            hrx_en_vuelo = hrx_n_tx - (hrx_k0 + hrx_n_rx);
            $display("         video: %0d pixeles recibidos iguales a los enviados, %0d distintos; %0d cuadros enteros: %0d de vumetro, %0d de depurador",
                     hrx_pix_ok, hrx_pix_mal, hrx_nfr, hrx_nvu, hrx_ndbg);
            $display("         audio: tomadas %0d (la %0d, primera con el transmisor en marcha; %0d con X), recibidas %0d, la primera es la %0d, en camino %0d; %0d con L distinta de R, pico %0d",
                     hrx_n_tx, hrx_tx_on, hrx_tx_x, hrx_n_rx, hrx_k0, hrx_en_vuelo, hrx_lr, hrx_amax);
            $display("         medidor: %0d ticks de cuadro, %0d muestras con X en sus fuentes", vr_ntick, vr_x);

            ok(hrx_mixed == 0 && hrx_nvu == 2 && hrx_ndbg == 1,
               "HDMI: dos cuadros enteros de vumetro y despues uno entero de depurador");
            ok(hrx_pix_mal == 0 && hrx_pix_ok >= 3 * 720 * 480,
               "HDMI: cada pixel del cable es el que el diseno dio al transmisor");
            ok(vr_x == 0, "medidor: ninguna de sus seis fuentes lleva X");
            ok(hrx_lvl_mal == 0,
               "vumetro: las barras y marcas de pico que se pintan son las del modelo, alimentado desde las fuentes de cada barra");
            ok(hrx_st_mal == 0, "vumetro: estado YRW801 OK y MSX OK");
            ok(hrx_dbg_mal == 0 && hrx_dbg_vu == 0,
               "depurador activo: el cuadro es el terminal pixel a pixel (blanco y negro), nada del vumetro");
            ok(hrx_tx_x == 0, "HDMI: el transmisor no toma ninguna muestra con X");
            ok(hrx_casan == 1 && hrx_k0 >= 0 && hrx_n_rx > 1000,
               "HDMI: el audio del cable es, muestra a muestra y en su canal, el que se envio");
            ok(hrx_en_vuelo >= 0 && hrx_en_vuelo <= 12, "HDMI: ninguna muestra se queda atras");
            ok(hrx_lr > 100 && hrx_amax > 1000, "HDMI: hay sonido y la FM a la izquierda hace L distinta de R");
            ok(hrx_bajos == 0, "HDMI: los 8 bits bajos de cada muestra de 24 van a cero");
            ok(rx.n_err_total == 0, "HDMI: ningun error de protocolo (BCH, checksums, paridad, TMDS)");
            ok(rx.n_fallos_chk == 0, "HDMI: geometria, ACR, estado de canal e InfoFrames correctos");
            $fclose(hrx_fl);
        end
    endtask
