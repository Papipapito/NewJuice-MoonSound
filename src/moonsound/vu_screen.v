// ============================================================================
// vu_screen.v - generador de pantalla del vumetro.                 (MoonTANG)
//
// 720x480p (VIC 2/3, reloj de pixel 27 MHz, 858x525 totales), pensado para
// verse en 16:9. Todo lo que se pinta queda dentro del margen de seguridad
// del 5 % (x 36..684, y 24..456):
//
//     MOONTANG  MOONSOUND OPL4                    titulo x4 + subtitulo x2
//     ------------------------------------------  separador
//     FM    L  [][][][][][][][][][][][][][][][]   seis barras de 28 segmentos
//           R  [][][][][][][][][][][][][][][][]   (verde / amarillo / rojo)
//     WAVE  L  ...
//           R  ...
//     OUT   L  ...
//           R  ...
//                 -36         -24      -12  0 DB  regla (1,5 dB por segmento)
//     YRW801 OK               MSX OK              estado
//     MOONTANG 2026-10-04                         pie
//
// ----------------------------------------------------------------------------
//  Cadencia
// ----------------------------------------------------------------------------
//  El modulo hdmi entrega cx/cy y espera el `rgb` de ese pixel UN ciclo
//  despues. La fuente (font8x8) es sincrona, asi que hay que ir por delante.
//  TODAS las capas (texto, barras, separador) siguen el mismo camino, de modo
//  que salen alineadas por construccion:
//
//     ciclo n    cx = c      se decide (combinacional) el pixel xd = c + 2
//     ciclo n+1  cx = c+1    registros "R": describen el pixel c + 2
//                            (texto: caracter y fila -> direccion de la fuente)
//     ciclo n+2  cx = c+2    registros "P" + bits de la fuente: pixel c + 2
//     ciclo n+3  cx = c+3    rgb = pixel c + 2          (= cx - 1, lo pedido)
//
//  El adelanto no da la vuelta al final de linea: xd recorre 2..859 y los
//  pixeles 0 y 1 de cada linea salen siempre con el color de fondo. No importa
//  porque no hay nada a la izquierda de x = 36.
//
// ----------------------------------------------------------------------------
//  Texto
// ----------------------------------------------------------------------------
//  No hay RAM de pantalla. Cada linea de barrido cae en una "fila de texto"
//  (trow) que tiene hasta cuatro elementos ordenados de izquierda a derecha;
//  la tabla `it` da, para {trow, slot}, donde empieza el siguiente elemento,
//  que cadena es, cuanto mide, su escala (x1, x2, x4) y su color. Cuando xd
//  llega al principio del elemento arranca un contador que recorre sus
//  caracteres; no hacen falta restas ni divisiones por pixel y cada elemento
//  puede estar en cualquier x e y.
//
//  Los glifos de font8x8 dejan en blanco la columna 0 y la fila 7. Por eso los
//  textos que van pegados al margen izquierdo empiezan su celda un pixel de
//  fuente antes (la TINTA es la que queda en x = 48), el subtitulo comparte
//  linea base con el titulo y las letras L/R estan centradas con su barra
//  contando solo la tinta.
//
//  `level` y `peak` solo cambian en el borrado vertical y se usan tal cual.
//
// ----------------------------------------------------------------------------
//  New Juice MoonSound fork (Albert "Papipapito" with Claude, GPL-3.0)
// ----------------------------------------------------------------------------
//  From MoonTANG 5400f15, with two changes; with the default parameters the
//  picture is still pixel for pixel MoonTANG's (checked with MoonTANG's own
//  bench, tools/sim/vu in MoonTANG):
//   - the title, the subtitle and the footer are parameters (TITLE/SUB/FOOT
//     and their lengths), so New Juice can say what it is without a second
//     copy of this module. The subtitle starts 28 px after the title, as
//     before, and the fixed strings come first in STR. Element lengths are
//     6 bits (footer up to 63 characters);
//   - STR and the table of text elements (`it`) are ROMs in block RAM
//     instead of logic (about 200 LUTs less, the New Juice chip is full).
//     The STR read takes one clock, so the text goes one pixel further ahead
//     (xt = cx + 3) and its R registers pass through one more stage ("Q")
//     before meeting the font bits; bars and separator keep xd = cx + 2. All
//     layers still come out aligned. The `it` ROM is addressed by {trow,
//     slot, st_rom, st_msx} and answers one clock later: `slot` moves on
//     when an element starts and the next one is always further right, and
//     `trow` changes at the start of the line, far left of any text.
// ============================================================================
`default_nettype none

module vu_screen #(
    parameter [8*10-1:0] BUILD = "2026-10-04",  // 10 caracteres, se pinta en el pie
    parameter integer    TITLE_N = 8,           // titulo, x4
    parameter [8*TITLE_N-1:0] TITLE = "MOONTANG",
    parameter integer    SUB_N = 14,            // subtitulo, x2
    parameter [8*SUB_N-1:0] SUB = "MOONSOUND OPL4",
    parameter integer    FOOT_N = 19,           // pie, x1
    parameter [8*FOOT_N-1:0] FOOT = {"MOONTANG ", BUILD}
) (
    input  wire        clk,      // reloj de pixel, 27 MHz
    input  wire        rst_n,
    input  wire [9:0]  cx,       // columna 0..857 (visible 0..719), del modulo hdmi
    input  wire [9:0]  cy,       // fila    0..524 (visible 0..479)
    output reg  [23:0] rgb,      // {R,G,B}; valido UN ciclo de reloj despues de cx/cy
    input  wire [29:0] level,    // 6 barras x 5 bits: segmentos encendidos, 0..28
    input  wire [29:0] peak,     // 6 marcas de pico x 5 bits: 0 = sin marca, n = segmento n
    input  wire [1:0]  st_rom,   // 0 = cargando la YRW801, 1 = OK, 2 = error, 3 = no es la YRW801
    input  wire        st_msx    // 1 = reloj del MSX presente
);

    // ------------------------------------------------------------------
    // Geometria (pixeles)
    // ------------------------------------------------------------------
    localparam [9:0] H_ACT  = 10'd720;
    localparam [9:0] V_ACT  = 10'd480;

    localparam [9:0] X_L    = 10'd48;           // margen izquierdo (tinta)
    localparam [9:0] X_R    = 10'd672;          // fin del separador

    // celdas de texto: la tinta empieza una columna de fuente mas a la derecha
    localparam [9:0] X_TIT  = X_L - 10'd4;      // "MOONTANG", x4
    // subtitulo, x2: 28 px despues del titulo (MoonTANG: 328)
    localparam [9:0] X_SUB  = X_TIT + TITLE_N * 32 + 28;
    localparam [9:0] X_GRP  = X_L - 10'd2;      // "FM" / "WAVE" / "OUT", x2
    localparam [9:0] X_LR   = 10'd136;          // "L" / "R", x2
    localparam [9:0] X_ST1  = X_L - 10'd2;      // "YRW801", x2
    localparam [9:0] X_ST1V = X_ST1 + 10'd112;  //   su valor (7 celdas despues)
    localparam [9:0] X_ST2  = 10'd400;          // "MSX", x2
    localparam [9:0] X_ST2V = X_ST2 + 10'd64;   //   su valor (4 celdas despues)
    localparam [9:0] X_FT   = X_L - 10'd1;      // pie, x1

    // barras: 28 segmentos de 16 px con 2 px de hueco
    localparam [9:0] X_BAR  = 10'd168;          // segmento 1
    localparam [4:0] NSEG   = 5'd28;
    localparam [4:0] PITCH  = 5'd18;
    localparam [9:0] BAR_H  = 10'd24;

    // regla en dB, x1: centrada bajo los segmentos 4, 12 y 20, y con la tinta
    // de "0 DB" acabando donde acaba el segmento 28
    localparam [9:0] X_DB36 = X_BAR + 10'd3  * 10'd18 + 10'd8 - 10'd12;   // 218
    localparam [9:0] X_DB24 = X_BAR + 10'd11 * 10'd18 + 10'd8 - 10'd12;   // 362
    localparam [9:0] X_DB12 = X_BAR + 10'd19 * 10'd18 + 10'd8 - 10'd12;   // 506
    localparam [9:0] X_DB0  = X_BAR + 10'd28 * 10'd18 - 10'd2 - 10'd31;   // 639

    localparam [9:0] Y_TIT  = 10'd40;           // x4: 40..71
    localparam [9:0] Y_SUB  = 10'd54;           // x2: 54..69, misma linea base
    localparam [9:0] Y_SEP  = 10'd88;           // 2 px
    localparam [9:0] Y_B0   = 10'd112;          // FM L
    localparam [9:0] Y_B1   = 10'd144;          // FM R
    localparam [9:0] Y_B2   = 10'd200;          // WAVE L
    localparam [9:0] Y_B3   = 10'd232;          // WAVE R
    localparam [9:0] Y_B4   = 10'd288;          // OUT L
    localparam [9:0] Y_B5   = 10'd320;          // OUT R
    localparam [9:0] LBL_DY = 10'd5;            // rotulo x2 centrado en la barra
    localparam [9:0] Y_L0   = Y_B0 + LBL_DY;
    localparam [9:0] Y_L1   = Y_B1 + LBL_DY;
    localparam [9:0] Y_L2   = Y_B2 + LBL_DY;
    localparam [9:0] Y_L3   = Y_B3 + LBL_DY;
    localparam [9:0] Y_L4   = Y_B4 + LBL_DY;
    localparam [9:0] Y_L5   = Y_B5 + LBL_DY;
    localparam [9:0] Y_DB   = 10'd352;          // x1
    localparam [9:0] Y_ST   = 10'd392;          // x2
    localparam [9:0] Y_FT   = 10'd440;          // x1

    // ------------------------------------------------------------------
    // Colores
    // ------------------------------------------------------------------
    localparam [23:0] C_BG    = 24'h06080E;     // fondo
    localparam [23:0] C_SEP   = 24'h2A3550;     // separador
    localparam [23:0] C_OFF_G = 24'h0A2410;     // segmento apagado
    localparam [23:0] C_OFF_Y = 24'h2A2608;
    localparam [23:0] C_OFF_R = 24'h2A0C08;
    localparam [23:0] C_ON_G  = 24'h20E040;     // segmento encendido
    localparam [23:0] C_ON_Y  = 24'hF0D020;
    localparam [23:0] C_ON_R  = 24'hF03020;
    localparam [23:0] C_PK_G  = 24'hB0FFC0;     // marca de pico
    localparam [23:0] C_PK_Y  = 24'hFFF8A0;
    localparam [23:0] C_PK_R  = 24'hFFA090;

    // colores de texto (indice de 3 bits)
    localparam [2:0] T_TITLE = 3'd0;            // E8F0FF
    localparam [2:0] T_CYAN  = 3'd1;            // 5CC8E8
    localparam [2:0] T_LABEL = 3'd2;            // B8C4D8
    localparam [2:0] T_SCALE = 3'd3;            // 8894A8
    localparam [2:0] T_GREEN = 3'd4;            // 20E040
    localparam [2:0] T_RED   = 3'd5;            // F03020
    localparam [2:0] T_YELL  = 3'd6;            // F0D020
    localparam [2:0] T_GREY  = 3'd7;            // 687488

    // Rango limitado. 720x480p es un formato CE: el televisor toma el RGB como
    // 16..235 (16 = negro, 235 = blanco) y todo lo que baja de 16 lo ve negro.
    // Los colores de arriba son los de diseño, en 0..255; a la salida van
    // escalados a 16..235. Con los de diseño tal cual, el fondo y los segmentos
    // apagados (canales de 06h a 2Ah) se quedaban negros en una tele.
    // Son constantes: la cuenta la hace la sintesis, no genera logica.
    function [7:0] lim8;
        input [7:0] c;
        begin
            lim8 = 8'd16 + (c * 16'd219 + 16'd127) / 16'd255;
        end
    endfunction
    function [23:0] lim;
        input [23:0] c;
        begin
            lim = {lim8(c[23:16]), lim8(c[15:8]), lim8(c[7:0])};
        end
    endfunction

    // paleta completa: 0..15 lo que hay debajo del texto, 16..23 el texto
    function [23:0] pal;
        input [4:0] i;
        begin
            case (i)
                5'd1:    pal = lim(C_SEP);
                5'd4:    pal = lim(C_OFF_G);
                5'd5:    pal = lim(C_OFF_Y);
                5'd6:    pal = lim(C_OFF_R);
                5'd8:    pal = lim(C_ON_G);
                5'd9:    pal = lim(C_ON_Y);
                5'd10:   pal = lim(C_ON_R);
                5'd12:   pal = lim(C_PK_G);
                5'd13:   pal = lim(C_PK_Y);
                5'd14:   pal = lim(C_PK_R);
                5'd16:   pal = lim(24'hE8F0FF);
                5'd17:   pal = lim(24'h5CC8E8);
                5'd18:   pal = lim(24'hB8C4D8);
                5'd19:   pal = lim(24'h8894A8);
                5'd20:   pal = lim(C_ON_G);
                5'd21:   pal = lim(C_ON_R);
                5'd22:   pal = lim(C_ON_Y);
                5'd23:   pal = lim(24'h687488);
                default: pal = lim(C_BG);
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Cadenas. Direccion = posicion del caracter; 128 en total.
    // ------------------------------------------------------------------
    // fijas primero; despues titulo, subtitulo y pie (parametros)
    localparam [6:0] S_FM   = 7'd0;     // "FM"
    localparam [6:0] S_WAVE = 7'd2;     // "WAVE"
    localparam [6:0] S_OUT  = 7'd6;     // "OUT"
    localparam [6:0] S_L    = 7'd9;     // "L"
    localparam [6:0] S_R    = 7'd10;    // "R"
    localparam [6:0] S_DB36 = 7'd11;    // "-36"
    localparam [6:0] S_DB24 = 7'd14;    // "-24"
    localparam [6:0] S_DB12 = 7'd17;    // "-12"
    localparam [6:0] S_DB0  = 7'd20;    // "0 DB"
    localparam [6:0] S_YRW  = 7'd24;    // "YRW801"
    localparam [6:0] S_OK   = 7'd30;    // "OK"
    localparam [6:0] S_ERR  = 7'd32;    // "ERROR"
    localparam [6:0] S_DOTS = 7'd37;    // "..."
    localparam [6:0] S_MSX  = 7'd40;    // "MSX"
    localparam [6:0] S_DASH = 7'd43;    // "--"
    localparam [6:0] S_BAD  = 7'd45;    // "NO VALIDA"
    localparam integer N_FIX = 54;
    localparam [6:0] S_TIT  = N_FIX;
    localparam [6:0] S_SUB  = N_FIX + TITLE_N;
    localparam [6:0] S_FOOT = N_FIX + TITLE_N + SUB_N;
    localparam integer N_USED = N_FIX + TITLE_N + SUB_N + FOOT_N;   // <= 128
    localparam [5:0] L_TIT  = TITLE_N;
    localparam [5:0] L_SUB  = SUB_N;
    localparam [5:0] L_FOOT = FOOT_N;    // <= 63

    // la concatenacion queda ajustada a la derecha; se lleva a la izquierda
    // (caracter 0 = byte de arriba). Lo que sobra son ceros (= espacio).
    localparam [8*128-1:0] STR_R = {
        "FM", "WAVE", "OUT", "L", "R",
        "-36", "-24", "-12", "0 DB",
        "YRW801", "OK", "ERROR", "...", "MSX", "--", "NO VALIDA",
        TITLE, SUB, FOOT
    };
    localparam [8*128-1:0] STR = STR_R << (8 * (128 - N_USED));

    // ------------------------------------------------------------------
    // Pixel que se decide en este ciclo
    // ------------------------------------------------------------------
    wire [9:0] xd    = cx + 10'd2;
    wire [9:0] xt    = cx + 10'd3;          // texto: un pixel mas adelante (ROM de STR)
    wire       line0 = (cx == 10'd0);       // principio de linea (xd = 2, xt = 3)

    // ------------------------------------------------------------------
    // Fila de texto de esta linea (solo depende de cy)
    // ------------------------------------------------------------------
    localparam [3:0] R_NONE = 4'd0,
                     R_TIT  = 4'd1,     // titulo solo
                     R_TIT2 = 4'd2,     // titulo + subtitulo
                     R_FML  = 4'd3,
                     R_FMR  = 4'd4,
                     R_WVL  = 4'd5,
                     R_WVR  = 4'd6,
                     R_OUL  = 4'd7,
                     R_OUR  = 4'd8,
                     R_DB   = 4'd9,
                     R_ST   = 4'd10,
                     R_FT   = 4'd11;

    function in_y;                      // y0 <= y < y0 + h
        input [9:0] y;
        input [9:0] y0;
        input [9:0] h;
        begin
            in_y = (y >= y0) && (y < y0 + h);
        end
    endfunction

    reg [3:0] trow;
    always @* begin
        if      (in_y(cy, Y_SUB, 10'd16)) trow = R_TIT2;
        else if (in_y(cy, Y_TIT, 10'd32)) trow = R_TIT;
        else if (in_y(cy, Y_L0,  10'd16)) trow = R_FML;
        else if (in_y(cy, Y_L1,  10'd16)) trow = R_FMR;
        else if (in_y(cy, Y_L2,  10'd16)) trow = R_WVL;
        else if (in_y(cy, Y_L3,  10'd16)) trow = R_WVR;
        else if (in_y(cy, Y_L4,  10'd16)) trow = R_OUL;
        else if (in_y(cy, Y_L5,  10'd16)) trow = R_OUR;
        else if (in_y(cy, Y_DB,  10'd8))  trow = R_DB;
        else if (in_y(cy, Y_ST,  10'd16)) trow = R_ST;
        else if (in_y(cy, Y_FT,  10'd8))  trow = R_FT;
        else                              trow = R_NONE;
    end

    // ------------------------------------------------------------------
    // Tabla de elementos de texto: el `slot`-esimo de la fila `trow`
    //   {x0[9:0], cadena[6:0], largo[5:0], escala[1:0], y0[4:0], color[2:0]}
    //   escala: 0 = x1, 1 = x2, 2 = x4.  y0 = los 5 bits bajos de su y.
    //   x0 = 1023 -> no hay mas elementos (xt nunca llega).
    //   Los valores de la linea de estado dependen de st_rom / st_msx.
    // ------------------------------------------------------------------
    function [32:0] it_ent;
        input [3:0] tr;
        input [1:0] sl;
        input [1:0] sro;
        input       smx;
        reg   [6:0] sr_str;
        reg   [5:0] sr_len;
        reg   [2:0] sr_col;
        reg   [6:0] sm_str;
        reg   [2:0] sm_col;
        begin
            case (sro)
                2'd0:    begin sr_str = S_DOTS; sr_len = 6'd3; sr_col = T_YELL;  end
                2'd1:    begin sr_str = S_OK;   sr_len = 6'd2; sr_col = T_GREEN; end
                2'd3:    begin sr_str = S_BAD;  sr_len = 6'd9; sr_col = T_RED;   end
                default: begin sr_str = S_ERR;  sr_len = 6'd5; sr_col = T_RED;   end
            endcase
            sm_str = smx ? S_OK    : S_DASH;
            sm_col = smx ? T_GREEN : T_GREY;
            case ({tr, sl})
                {R_TIT,  2'd0},
                {R_TIT2, 2'd0}: it_ent = {X_TIT,  S_TIT,  L_TIT,  2'd2, Y_TIT[4:0], T_TITLE};
                {R_TIT2, 2'd1}: it_ent = {X_SUB,  S_SUB,  L_SUB,  2'd1, Y_SUB[4:0], T_CYAN};

                {R_FML,  2'd0}: it_ent = {X_GRP,  S_FM,   6'd2,   2'd1, Y_L0[4:0],  T_LABEL};
                {R_FML,  2'd1}: it_ent = {X_LR,   S_L,    6'd1,   2'd1, Y_L0[4:0],  T_LABEL};
                {R_FMR,  2'd0}: it_ent = {X_LR,   S_R,    6'd1,   2'd1, Y_L1[4:0],  T_LABEL};
                {R_WVL,  2'd0}: it_ent = {X_GRP,  S_WAVE, 6'd4,   2'd1, Y_L2[4:0],  T_LABEL};
                {R_WVL,  2'd1}: it_ent = {X_LR,   S_L,    6'd1,   2'd1, Y_L2[4:0],  T_LABEL};
                {R_WVR,  2'd0}: it_ent = {X_LR,   S_R,    6'd1,   2'd1, Y_L3[4:0],  T_LABEL};
                {R_OUL,  2'd0}: it_ent = {X_GRP,  S_OUT,  6'd3,   2'd1, Y_L4[4:0],  T_LABEL};
                {R_OUL,  2'd1}: it_ent = {X_LR,   S_L,    6'd1,   2'd1, Y_L4[4:0],  T_LABEL};
                {R_OUR,  2'd0}: it_ent = {X_LR,   S_R,    6'd1,   2'd1, Y_L5[4:0],  T_LABEL};

                {R_DB,   2'd0}: it_ent = {X_DB36, S_DB36, 6'd3,   2'd0, Y_DB[4:0],  T_SCALE};
                {R_DB,   2'd1}: it_ent = {X_DB24, S_DB24, 6'd3,   2'd0, Y_DB[4:0],  T_SCALE};
                {R_DB,   2'd2}: it_ent = {X_DB12, S_DB12, 6'd3,   2'd0, Y_DB[4:0],  T_SCALE};
                {R_DB,   2'd3}: it_ent = {X_DB0,  S_DB0,  6'd4,   2'd0, Y_DB[4:0],  T_SCALE};

                {R_ST,   2'd0}: it_ent = {X_ST1,  S_YRW,  6'd6,   2'd1, Y_ST[4:0],  T_LABEL};
                {R_ST,   2'd1}: it_ent = {X_ST1V, sr_str, sr_len, 2'd1, Y_ST[4:0],  sr_col};
                {R_ST,   2'd2}: it_ent = {X_ST2,  S_MSX,  6'd3,   2'd1, Y_ST[4:0],  T_LABEL};
                {R_ST,   2'd3}: it_ent = {X_ST2V, sm_str, 6'd2,   2'd1, Y_ST[4:0],  sm_col};

                {R_FT,   2'd0}: it_ent = {X_FT,   S_FOOT, L_FOOT, 2'd0, Y_FT[4:0],  T_GREY};

                default:        it_ent = {10'h3FF, 23'd0};
            endcase
        end
    endfunction

    (* syn_romstyle = "block_rom" *) reg [32:0] it_rom [0:511];
    integer ii;
    initial for (ii = 0; ii < 512; ii = ii + 1)
        it_rom[ii] = it_ent(ii[8:5], ii[4:3], ii[2:1], ii[0]);

    reg [1:0]  slot;                    // siguiente elemento de la linea
    reg [32:0] it;                      // el elemento `slot` de la fila, un ciclo despues
    always @(posedge clk) it <= it_rom[{trow, slot, st_rom, st_msx}];

    wire [9:0] it_x0  = it[32:23];
    wire [6:0] it_str = it[22:16];
    wire [5:0] it_len = it[15:10];
    wire [1:0] it_sh  = it[9:8];
    wire [4:0] it_y0  = it[7:3];
    wire [2:0] it_col = it[2:0];

    // fila del glifo: ((cy - y0) / escala) mod 8; bastan los 5 bits bajos
    wire [4:0] it_dy  = cy[4:0] - it_y0;
    wire [2:0] it_row = (it_sh == 2'd2) ? it_dy[4:2] :
                        (it_sh == 2'd1) ? it_dy[3:1] : it_dy[2:0];

    // ------------------------------------------------------------------
    // Recorrido del texto (registros R: describen el pixel xd ya registrado)
    // ------------------------------------------------------------------
    reg        run;                     // dentro de un elemento
    reg [6:0]  chaddr;                  // caracter en curso (direccion en STR)
    reg [5:0]  nleft;                   // caracteres que quedan, contando este
    reg [4:0]  px;                      // pixel dentro del glifo ya escalado
    reg [1:0]  r_sh;
    reg [2:0]  r_col;
    reg [2:0]  r_row;

    wire px_last = (r_sh == 2'd2) ? (px      == 5'd31) :
                   (r_sh == 2'd1) ? (px[3:0] == 4'd15) : (px[2:0] == 3'd7);
    wire [2:0] gcol = (r_sh == 2'd2) ? px[4:2] :
                      (r_sh == 2'd1) ? px[3:1] : px[2:0];

    always @(posedge clk) begin
        if (!rst_n || line0) begin
            run  <= 1'b0;
            slot <= 2'd0;
        end
        else if (xt == it_x0) begin             // empieza el elemento
            run    <= 1'b1;
            slot   <= slot + 2'd1;
            chaddr <= it_str;
            nleft  <= it_len;
            px     <= 5'd0;
            r_sh   <= it_sh;
            r_col  <= it_col;
            r_row  <= it_row;
        end
        else if (run) begin
            if (px_last) begin                  // caracter siguiente
                px     <= 5'd0;
                chaddr <= chaddr + 7'd1;
                nleft  <= nleft - 6'd1;
                if (nleft == 6'd1) run <= 1'b0;
            end
            else px <= px + 5'd1;
        end
    end

    // caracter -> codigo de la fuente. {b6, b4..b0} es ASCII - 20h para
    // 20h..5Fh y, de paso, convierte las minusculas en mayusculas.
    // STR en una ROM de bloque: el caracter llega un ciclo despues (etapa Q).
    (* syn_romstyle = "block_rom" *) reg [7:0] str_rom [0:127];
    integer si;
    initial for (si = 0; si < 128; si = si + 1) str_rom[si] = STR[8*(127-si) +: 8];
    reg [7:0] ch;
    always @(posedge clk) ch <= str_rom[chaddr];
    wire [5:0] code = {ch[6], ch[4:0]};

    // registros Q: el resto del texto, a la par que `ch`
    reg       q_run;
    reg [2:0] q_gcol;
    reg [2:0] q_col;
    reg [2:0] q_row;
    always @(posedge clk) begin
        q_run  <= run;
        q_gcol <= gcol;
        q_col  <= r_col;
        q_row  <= r_row;
    end

    wire [7:0] font_bits;
    font8x8 u_font (
        .clk (clk),
        .code(code),
        .row (q_row),
        .bits(font_bits)
    );

    // ------------------------------------------------------------------
    // Barras (registros R). Un contador recorre los segmentos: sin divisiones.
    // ------------------------------------------------------------------
    reg [4:0] seg;                      // 0 = fuera de la barra, 1..28
    reg [4:0] sub;                      // 0..17 dentro del paso; 16 y 17 = hueco
    always @(posedge clk) begin
        if (!rst_n) begin
            seg <= 5'd0;
            sub <= 5'd0;
        end
        else if (xd == X_BAR) begin
            seg <= 5'd1;
            sub <= 5'd0;
        end
        else if (seg != 5'd0) begin
            if (sub == PITCH - 5'd1) begin
                sub <= 5'd0;
                seg <= (seg == NSEG) ? 5'd0 : seg + 5'd1;
            end
            else sub <= sub + 5'd1;
        end
    end

    // barra de esta linea
    reg       bar_v;
    reg [4:0] lvl;
    reg [4:0] pk;
    always @* begin
        bar_v = 1'b1;
        if      (in_y(cy, Y_B0, BAR_H)) begin lvl = level[ 4: 0]; pk = peak[ 4: 0]; end
        else if (in_y(cy, Y_B1, BAR_H)) begin lvl = level[ 9: 5]; pk = peak[ 9: 5]; end
        else if (in_y(cy, Y_B2, BAR_H)) begin lvl = level[14:10]; pk = peak[14:10]; end
        else if (in_y(cy, Y_B3, BAR_H)) begin lvl = level[19:15]; pk = peak[19:15]; end
        else if (in_y(cy, Y_B4, BAR_H)) begin lvl = level[24:20]; pk = peak[24:20]; end
        else if (in_y(cy, Y_B5, BAR_H)) begin lvl = level[29:25]; pk = peak[29:25]; end
        else begin
            bar_v = 1'b0;
            lvl   = 5'd0;
            pk    = 5'd0;
        end
    end

    wire       seg_on  = bar_v && (seg != 5'd0) && !sub[4];
    wire       seg_pk  = (seg == pk);           // seg != 0, asi que pk = 0 no coincide
    wire       seg_lit = (seg <= lvl);
    wire [1:0] zone    = (seg >= 5'd26) ? 2'd2 :      // rojo
                         (seg >= 5'd21) ? 2'd1 :      // amarillo
                                          2'd0;       // verde

    // separador (registro R)
    reg  sepx;
    wire sep_v = in_y(cy, Y_SEP, 10'd2);
    always @(posedge clk) begin
        if (!rst_n)          sepx <= 1'b0;
        else if (xd == X_L)  sepx <= 1'b1;
        else if (xd == X_R)  sepx <= 1'b0;
    end

    // ------------------------------------------------------------------
    // Registros P: a la par que los bits de la fuente
    // ------------------------------------------------------------------
    reg       p_txt;
    reg [2:0] p_gcol;
    reg [2:0] p_col;
    reg [3:0] p_under;                  // indice de paleta de lo que hay debajo
    always @(posedge clk) begin
        p_txt  <= q_run;
        p_gcol <= q_gcol;
        p_col  <= q_col;
        if (seg_on) p_under <= {seg_pk ? 2'd3 : seg_lit ? 2'd2 : 2'd1, zone};
        else        p_under <= {3'b000, sepx && sep_v};
    end

    // ------------------------------------------------------------------
    // Pixel
    // ------------------------------------------------------------------
    wire       glyph   = p_txt && font_bits[3'd7 - p_gcol];   // bit 7 = izquierda
    wire [4:0] cidx    = glyph ? {2'b10, p_col} : {1'b0, p_under};
    wire       visible = (cx < H_ACT) && (cy < V_ACT);

    always @(posedge clk) begin
        if (!rst_n || !visible) rgb <= 24'h000000;
        else                    rgb <= pal(cidx);
    end

endmodule

`default_nettype wire
