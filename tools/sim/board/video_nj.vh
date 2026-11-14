// ============================================================================
// video_nj.vh - the picture of the V9990 fork on the board bench
// (run_board.sh video).
//
// Included in tb_nj_board.v when it is compiled with -DWITH_VIDEO. The video PLL
// is NOT held in reset: New Juice starts it, as on the board, once its modules
// are released, and the chain runs: tiny9990 -> upscan -> BOARD_REV1_TMDS_OUT.
// Gowin's DVI_TX_Top is a stub (tools/sim/common/dvi_tx_stub.v); what is looked
// at is the video where it enters it: I_rgb_vs / hs / de / r / g / b, sampled on
// the rising edge of I_rgb_clk (27 MHz), i.e. what a receiver would take.
//
// The Z80 programs B1 (256 x 212, 8 bpp, direct colour), palette entry 42 as
// the border (R#15 = 42), and writes through P#0 bands of rows with eight
// colour segments of 32 pixels (rows 0-1, 100-105 and 210-211; the rest of the
// VRAM is 0 = transparent = the backdrop colour). Two whole frames are
// measured (geometry, DE, HS, VS) and the second one is kept pixel by pixel.
// ============================================================================
`define DVI `V9.u_tmds.DVI_TX_Top_inst

reg         vc_en = 1'b0;
integer     vc_fr = 0;                       // VS rising edges seen since vc_en
reg         vc_hs_q = 1'b0, vc_vs_q = 1'b0, vc_de_q = 1'b0;
integer     vc_h = 0, vc_line = -1, vc_hs_run = 0, vc_de_run = 0, vc_de_at = 0;
integer     vc_hvalid = 0, vc_hc = 0;
// per frame (index = vc_fr, 1 and 2 are whole frames)
integer     fr_lines [0:7];
integer     fr_hmin [0:7], fr_hmax [0:7];            // dots between HS rising edges
integer     fr_hsmin [0:7], fr_hsmax [0:7];          // HS high, dots
integer     fr_defirst [0:7], fr_delast [0:7], fr_delines [0:7];
integer     fr_dewmin [0:7], fr_dewmax [0:7];        // DE high, dots
integer     fr_deatmin [0:7], fr_deatmax [0:7];      // dots from the HS rising edge to the DE rising edge
integer     fr_vshi [0:7];                           // dots with VS high
integer     fr_hlong [0:7];                          // lines that are not 855 dots
integer     fr_x [0:7];                              // X/Z seen on the video
localparam VC_CAP = 2;                              // the frame kept pixel by pixel
integer     vc_len [0:4799];                         // dots of each line: [frame * 600 + line]
reg [23:0]  vc_img [0:378000];                       // frame VC_CAP: [line * 720 + column]
integer     vc_i;
initial for (vc_i = 0; vc_i < 4800; vc_i = vc_i + 1) vc_len[vc_i] = 0;
initial for (vc_i = 0; vc_i < 8; vc_i = vc_i + 1) begin
    fr_lines[vc_i] = 0; fr_hmin[vc_i] = 100000; fr_hmax[vc_i] = 0; fr_hsmin[vc_i] = 100000; fr_hsmax[vc_i] = 0;
    fr_defirst[vc_i] = -1; fr_delast[vc_i] = -1; fr_delines[vc_i] = 0; fr_dewmin[vc_i] = 100000; fr_dewmax[vc_i] = 0;
    fr_deatmin[vc_i] = 100000; fr_deatmax[vc_i] = 0; fr_vshi[vc_i] = 0; fr_x[vc_i] = 0; fr_hlong[vc_i] = 0;
end

always @(posedge `DVI.I_rgb_clk) if (vc_en) begin : vcap
    reg hs, vs, de, hs_rise, vs_rise;
    integer f;
    hs = `DVI.I_rgb_hs; vs = `DVI.I_rgb_vs; de = `DVI.I_rgb_de;
    hs_rise = hs && !vc_hs_q; vs_rise = vs && !vc_vs_q;
    if (^{hs, vs, de, `DVI.I_rgb_r, `DVI.I_rgb_g, `DVI.I_rgb_b} === 1'bx && vc_fr >= 1 && vc_fr <= 6) fr_x[vc_fr] = fr_x[vc_fr] + 1;
    if (hs_rise) begin
        if (vc_fr >= 1 && vc_fr <= 6 && vc_hvalid) begin
            if (vc_h + 1 < fr_hmin[vc_fr]) fr_hmin[vc_fr] = vc_h + 1;
            if (vc_h + 1 > fr_hmax[vc_fr]) fr_hmax[vc_fr] = vc_h + 1;
            if (vc_h + 1 != 855) fr_hlong[vc_fr] = fr_hlong[vc_fr] + 1;
            if (vc_line >= 0 && vc_line < 600) vc_len[vc_fr * 600 + vc_line] = vc_h + 1;
        end
        vc_hvalid = 1; vc_h = 0; vc_line = vc_line + 1; vc_hc = vc_hc + 1;
    end
    else vc_h = vc_h + 1;
    if (vs_rise) begin
        // as BOARD_REV1_TMDS_OUT counts (v_cnt): 0 at the VS edge, +1 at every HS edge after it. The
        // HS that rises in the very clock of this VS opens the new frame (it is not counted in the old one)
        if (vc_fr >= 1 && vc_fr <= 6) fr_lines[vc_fr] = vc_hc - (hs_rise ? 1 : 0);
        vc_hc = hs_rise ? 1 : 0;
        vc_line = 0;
        vc_fr = vc_fr + 1;
    end
    f = vc_fr;
    if (f >= 1 && f <= 6) begin
        if (vs) fr_vshi[f] = fr_vshi[f] + 1;
        if (hs) vc_hs_run = vc_hs_run + 1;
        else begin
            if (vc_hs_q) begin
                if (vc_hs_run < fr_hsmin[f]) fr_hsmin[f] = vc_hs_run;
                if (vc_hs_run > fr_hsmax[f]) fr_hsmax[f] = vc_hs_run;
            end
            vc_hs_run = 0;
        end
        if (de && !vc_de_q) begin
            vc_de_run = 0; vc_de_at = vc_h;
            fr_delines[f] = fr_delines[f] + 1;
            if (fr_defirst[f] < 0) fr_defirst[f] = vc_line;
            fr_delast[f] = vc_line;
            if (vc_h < fr_deatmin[f]) fr_deatmin[f] = vc_h;
            if (vc_h > fr_deatmax[f]) fr_deatmax[f] = vc_h;
        end
        if (de) begin
            if (f == VC_CAP && vc_line >= 0 && vc_line < 525 && vc_de_run < 720)
                vc_img[vc_line * 720 + vc_de_run] = {`DVI.I_rgb_r, `DVI.I_rgb_g, `DVI.I_rgb_b};
            vc_de_run = vc_de_run + 1;
        end
        else if (vc_de_q) begin
            if (vc_de_run < fr_dewmin[f]) fr_dewmin[f] = vc_de_run;
            if (vc_de_run > fr_dewmax[f]) fr_dewmax[f] = vc_de_run;
        end
    end
    vc_hs_q = hs; vc_vs_q = vs; vc_de_q = de;
end

// the colour of a B1 / 8 bpp byte as the core makes it (T9990_COLOR_DECODE, GGGRRRBB) and
// the video path widens it ({r5, r5[4:2]})
function [23:0] vc_dec8(input [7:0] b);
    reg [4:0] r5, g5, b5;
    begin
        g5 = {b[7:5], b[7:6]};       // the V9990's 8 bpp is G3 R3 B2
        r5 = {b[4:2], b[4:3]};
        b5 = {b[1:0], b[1:0], b[1] | b[0]};
        vc_dec8 = {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
    end
endfunction
function [7:0] vc_seg(input integer k);
    case (k)
        0: vc_seg = 8'hE0;  1: vc_seg = 8'h1C;  2: vc_seg = 8'h03;  3: vc_seg = 8'hFC;
        4: vc_seg = 8'hE3;  5: vc_seg = 8'h1F;  6: vc_seg = 8'hFF;  default: vc_seg = 8'h92;
    endcase
endfunction
function vc_near(input [23:0] x, input [23:0] y, input integer tol);
    integer dr, dg, db;
    begin
        dr = x[23:16] - y[23:16]; dg = x[15:8] - y[15:8]; db = x[7:0] - y[7:0];
        vc_near = (dr <= tol && dr >= -tol && dg <= tol && dg >= -tol && db <= tol && db >= -tol);
    end
endfunction

// one row of the pattern (row = VRAM row of 256 bytes), written through P#0
task vc_row(input integer row);
    integer c;
    begin
        vset_w(row * 256);
        for (c = 0; c < 256; c = c + 1) begin
            vo(4'd0, vc_seg(c / 32));
            vsh[row * 256 + c] = vc_seg(c / 32);
        end
    end
endtask

task video_test;
    integer r, fx, bad, l, c, tl, bl, ml, xl, xr, wd, ml_gap;
    reg [23:0] bc, px;
    reg [7:0] pr, pg, pb;
    reg found;
    begin
        $display("== V. imagen: V9990 en B1 con display, capturada a la entrada del DVI (stub) ==");
        // palette entry 42 = (21, 10, 27)
        vreg_w(13, 8'h00);                              // palette, address auto-increment
        vreg_w(14, 8'd42 << 2);                         // PLTA = 42, PLTP = R
        vo(4'd1, 8'h15); vo(4'd1, 8'h0A); vo(4'd1, 8'h1B);
        vreg_w(14, 8'd42 << 2);
        vi(4'd1); pr = rdv; vi(4'd1); pg = rdv; vi(4'd1); pb = rdv;
        ok(pr === 8'h15 && pg === 8'h0A && pb === 8'h1B, "P#1: la entrada 42 de la paleta se escribe y se relee (R=15h G=0Ah B=1Bh)");
        vreg_w(13, 8'h40);                              // PLTM = 01: 8 bpp is direct colour (RGB 3-3-2), the palette serves the border
        vreg_w(15, 8'd42);                              // border = palette 42
        vreg_w(6, 8'h82); vreg_w(7, 8'h00); vreg_w(17, 8'h00); vreg_w(18, 8'h00);
        vreg_w(8, 8'hC0);                               // display on, sprites off
        vc_row(0); vc_row(1);
        for (r = 100; r <= 105; r = r + 1) vc_row(r);
        vc_row(210); vc_row(211);
        $display("         pantalla programada y %0d bytes escritos por P#0 en t = %0.2f ms", 10 * 256, $realtime / 1.0e6);
        fork : pllw
            begin wait (fpga.u_top.sms_reset_n === 1'b1); disable pllw; end
            begin #40_000_000; disable pllw; end
        join
        ok(fpga.u_top.rpll_video_lock === 1'b1 && fpga.u_top.sms_reset_n === 1'b1,
           "el PLL de video engancha y el transmisor sale de reset");
        $display("         PLL de video enganchado y transmisor libre en t = %0.2f ms", $realtime / 1.0e6);
        vc_en = 1'b1;
        fork : framesw
            begin wait (vc_fr == 4); disable framesw; end
            begin #90_000_000; disable framesw; end
        join
        vc_en = 1'b0;
        $display("         capturados %0d flancos de VS; fin de la captura en t = %0.2f ms (cuadros 1 a 3 completos; el 2 punto a punto)", vc_fr, $realtime / 1.0e6);
        ok(vc_fr >= 4, "se capturan tres cuadros completos");
        for (r = 1; r <= 3; r = r + 1) begin
            $display("         cuadro %0d: %0d lineas; puntos por linea %0d..%0d (%0d lineas de otra longitud); HS %0d..%0d puntos; DE: %0d lineas (%0d a %0d), %0d..%0d puntos, empieza %0d..%0d puntos tras HS; VS alto %0d puntos (%0.2f lineas); X: %0d",
                     r, fr_lines[r], fr_hmin[r], fr_hmax[r], fr_hlong[r], fr_hsmin[r], fr_hsmax[r], fr_delines[r], fr_defirst[r], fr_delast[r],
                     fr_dewmin[r], fr_dewmax[r], fr_deatmin[r], fr_deatmax[r], fr_vshi[r], fr_vshi[r] / 855.0, fr_x[r]);
            if (r >= 2) ok(fr_lines[r] == 524, "cuadro NTSC: 524 lineas");
            if (r >= 2) ok(fr_hmin[r] == 855 && fr_hmax[r] <= 879 && fr_hlong[r] <= 1, "855 puntos de 27 MHz en todas las lineas salvo una por cuadro (la del VS), de 879 como mucho");
            if (r >= 2) ok(fr_hsmin[r] == 62 && fr_hsmax[r] == 62, "HS de 62 puntos");
            if (r >= 2) ok(fr_delines[r] == 480 && fr_defirst[r] == 35 && fr_delast[r] == 514, "DE en las lineas 35-514 (480)");
            if (r >= 2) ok(fr_dewmin[r] == 720 && fr_dewmax[r] == 720, "DE de 720 puntos en cada linea");
            if (r >= 2) ok(fr_vshi[r] == 2 * 855, "VS de 2 lineas");
            if (r >= 2) ok(fr_x[r] == 0, "ningun X ni Z en el video");
        end
        begin : dump
            integer fd, ll, cc, ff;
            fd = $fopen("build/video_frame.txt", "w");
            for (ff = 1; ff <= 3; ff = ff + 1)
                for (ll = 0; ll < 540; ll = ll + 1)
                    if (vc_len[ff * 600 + ll] != 855 && vc_len[ff * 600 + ll] != 0) $fdisplay(fd, "LEN frame %0d line %0d dots %0d", ff, ll, vc_len[ff * 600 + ll]);
            for (ll = 0; ll < 525; ll = ll + 1) begin
                $fwrite(fd, "P %0d", ll);
                for (cc = 0; cc < 720; cc = cc + 1) $fwrite(fd, " %06x", vc_img[ll * 720 + cc]);
                $fwrite(fd, "\n");
            end
            $fclose(fd);
        end
        // ---- border: first and last DE line, and the sides of the image rows
        bc = {8'hAD, 8'h52, 8'hDE};      // {21,10,27} -> {r5, r5[4:2]}...
        bad = 0;
        for (c = 0; c < 720; c = c + 1) begin
            if (c >= 10 && c < 705) begin
                if (!vc_near(vc_img[45 * 720 + c], bc, 2)) bad = bad + 1;
                if (!vc_near(vc_img[514 * 720 + c], bc, 2)) bad = bad + 1;
            end
        end
        $display("         borde: linea 45 y ultima linea de DE (1390 puntos), %0d fuera de la paleta programada %06x; primera linea de DE [35][360] = %06x, ultima [514][360] = %06x; columnas de borde de la linea 45: 0-1 = %06x, 2 = %06x, 712 = %06x, 719 = %06x", bad, bc, vc_img[35 * 720 + 360], vc_img[514 * 720 + 360], vc_img[45 * 720], vc_img[45 * 720 + 2], vc_img[45 * 720 + 712], vc_img[45 * 720 + 719]);
        ok(bad == 0, "los puntos del borde (linea 45 y ultima de DE, columnas 10-704) tienen el color de la paleta 42");
        // ---- the bands: lines that have something that is not the border at column 360
        tl = -1; bl = -1; ml = -1; ml_gap = -1;
        for (l = 45; l <= 514; l = l + 1)
            if (!vc_near(vc_img[l * 720 + 360], bc, 2)) begin
                if (tl < 0) tl = l;
                bl = l;
            end
        // the middle band: the first non-border line after a gap that follows the top band
        found = 1'b0;
        for (l = tl; l <= 514; l = l + 1) begin
            if (!found && vc_near(vc_img[l * 720 + 360], bc, 2)) found = 1'b1;
            else if (found && !vc_near(vc_img[l * 720 + 360], bc, 2) && ml < 0) ml = l;
        end
        $display("         bandas de pantalla (columna 360): la primera linea de imagen es la %0d, la banda 100-105 empieza en la %0d, la ultima es la %0d", tl, ml, bl);
        ok(tl >= 0 && ml >= 0, "se ven las bandas escritas por P#0");
        $display("         separacion arriba -> banda central: %0d lineas (esperado 2 x 100 = 200); arriba -> abajo: %0d (esperado 2 x 212 - 1 = 423)", ml - tl, bl - tl);
        ok((ml - tl) >= 197 && (ml - tl) <= 203, "la banda de las filas 100-105 esta 2 lineas de salida por fila de VRAM bajo la primera (+-3)");
        ok((bl - tl) >= 420 && (bl - tl) <= 426, "las filas 0 y 211 estan a 2 x 211 lineas una de otra (+-3)");
        // ---- one row of the middle band: segments and colours
        l = ml + 6;
        xl = -1; xr = -1;
        for (c = 10; c < 705; c = c + 1)
            if (!vc_near(vc_img[l * 720 + c], bc, 2)) begin if (xl < 0) xl = c; xr = c; end
        wd = xr - xl + 1;
        $display("         linea %0d (centro de la banda central): imagen de la columna %0d a la %0d (%0d puntos), bordes de %0d y %0d puntos", l, xl, xr, wd, xl, 719 - xr);
        ok(wd >= 600 && wd <= 720, "la imagen ocupa 600-720 de los 720 puntos (256 puntos de B1 escalados)");
        ok(((xl > 719 - xr) ? xl - (719 - xr) : (719 - xr) - xl) <= 12, "esta centrada (bordes izquierdo y derecho iguales +-12)");
        bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            px = vc_img[l * 720 + xl + ((2 * c + 1) * wd) / 16];
            if (!vc_near(px, vc_dec8(vc_seg(c)), 3)) begin
                bad = bad + 1;
                $display("         [info] tramo %0d: %06x, esperado %06x", c, px, vc_dec8(vc_seg(c)));
            end
        end
        ok(bad == 0, "los 8 tramos de color de la fila (ancho 1/8 cada uno) tienen su color en el centro, tras el escalado (+-3)");
        bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            // a run of constant colour: the middle fifth of the segment
            for (r = (c * wd) / 8 + wd / 32; r < ((c + 1) * wd) / 8 - wd / 32; r = r + 1)
                if (!vc_near(vc_img[l * 720 + xl + r], vc_dec8(vc_seg(c)), 3)) bad = bad + 1;
        end
        ok(bad == 0, "y el color es constante en todo el tramo salvo 1/16 en cada extremo");
        // the same row in the first and the last band keep their colours
        bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            if (!vc_near(vc_img[(tl + 1) * 720 + xl + ((2 * c + 1) * wd) / 16], vc_dec8(vc_seg(c)), 3)) bad = bad + 1;
            if (!vc_near(vc_img[(bl - 1) * 720 + xl + ((2 * c + 1) * wd) / 16], vc_dec8(vc_seg(c)), 3)) bad = bad + 1;
        end
        ok(bad == 0, "las filas 0-1 y 210-211 de la VRAM tienen los mismos colores en su sitio");
        ok(fr_x[2] == 0 && fr_x[3] == 0, "sin X en el video de los dos cuadros");
        $display("         ranuras de VRAM perdidas: %0d", lost_slots(0));
        ok(lost_slots(0) == 0, "ninguna ranura de VRAM perdida con el display encendido en B1");
        ok(sdram.n_err == 0 && sdram.n_stale == 0, "la SDRAM sin ordenes ilegales ni filas caducadas");
    end
endtask
