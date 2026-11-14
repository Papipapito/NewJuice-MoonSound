//
// t9990_timing.sv
//
// BSD 3-Clause License
// 
// Copyright (c) 2024, Shinobu Hashimoto
// 
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
// 
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

`default_nettype none

/***************************************************************
 * メモリ接続先
 ***************************************************************/
package T9990_MEM_CONNECT;
    localparam [2:0] RAM_XX = 3'h0; // no connect
    localparam [2:0] RAM_VC = 3'h1; // VDP command / CPU
    localparam [2:0] RAM_SP = 3'h2; // sprite
    localparam [2:0] RAM_BP = 3'h3; // bitmap
    localparam [2:0] RAM_PA = 3'h4; // Pattern A
    localparam [2:0] RAM_PB = 3'h5; // Pattern B
    localparam [2:0] RAM_RF = 3'h6; // refresh
endpackage

/***************************************************************
 * メモリタイミング I/F
 ***************************************************************/
interface T9990_MEM_TIMING;
    logic [2:0] STATE;  // モジュールを指定
    logic       PREP;   // 各モジュールにアドレスを教えてもらうタイミング
    logic       EXEC;   // メモリのリード(ライト)開始タイミング

    modport TG ( output PREP, EXEC, STATE );
    modport RAM( input  PREP, EXEC, STATE );
endinterface

    localparam [2:0]    RAM_XX = T9990_MEM_CONNECT::RAM_XX;  // なし
    localparam [2:0]    RAM_VC = T9990_MEM_CONNECT::RAM_VC;  // VDP コマンド or CPU R/W
    localparam [2:0]    RAM_SP = T9990_MEM_CONNECT::RAM_SP;  // スプライト
    localparam [2:0]    RAM_BP = T9990_MEM_CONNECT::RAM_BP;  // ビットマップ
    localparam [2:0]    RAM_PA = T9990_MEM_CONNECT::RAM_PA;  // P1A/P2
    localparam [2:0]    RAM_PB = T9990_MEM_CONNECT::RAM_PB;  // P1B
    localparam [2:0]    RAM_RF = T9990_MEM_CONNECT::RAM_RF;  // リフレッシュ

/***************************************************************
 * タイミングジェネレータモジュール
 ***************************************************************/
module T9990_TIMING #(
    parameter               ENABLE_PAL = 1,     // V9990TANG: cuadro PAL de 313 lineas (R#7 bit 3)
    parameter               ENABLE_R16 = 1,     // V9990TANG: ajuste de posicion de R#16
    parameter               ENABLE_SPR_LINE0 = 1    // V9990TANG: cursor (y sprites) tambien en la primera linea de imagen
) (
    input wire              RESET_n,
    input wire              CLK,
    input wire              CLK_MASTER_EN,
    input wire              DCLK_EN,
    input wire              TG_EN,

    T9990_REGISTER_IF.VDP   REG,
    T9990_STATUS_IF.TIM     STATUS,

    output reg              HD,
    output reg              VD,
    output logic            HS,
    output logic            VS,

    output reg              SPR_START,
    output reg [8:0]        SPR_Y,

    output reg              BG_START,
    output reg [9:0]        BG_X,
    output reg [9:0]        BG_Y,       // V9990TANG: 10 bits (PAL entrelazado en B2/B4: 2 x 290 lineas)

    output reg              MUX_VDE,    // MUX Vアクティブ期間
    output reg              MUX_HDE,    // MUX Hアクティブ期間

    // MSXimus Z 21/10/2026: reinicio del scroll vertical (ver el bloque VOFS mas abajo)
    output reg [8:0]        VOFS_A,     // linea de pantalla en la que cayo la ultima escritura de R#17 (0 al empezar el cuadro)
    output reg [8:0]        VOFS_B,     // idem R#21 (plano B de P1)
    output reg [4:0]        SCAY_HI,    // R#18[4:0] congelado durante el area visible
    output reg              SCBY_HI,    // R#22[0]   idem

    input wire              MEM_REQ,

    T9990_MEM_TIMING.TG     MEM,

    output logic            PAL_FRAME,  // V9990TANG: 1 = el cuadro en curso (de VS a VS) es el de 313 lineas
    output logic            PAL_WIN,    // V9990TANG: 1 = el cuadro de la ventana (h_cnt/v_cnt) es el de 313 lineas
    output logic            FIELD       // V9990TANG: paridad del campo para la salida de video (EO alineado con VS)
);
    //  HSCN    C25M    MCS     DCKM    width   total   sync    erase   border  border  erase
    //  0       X       0       0       256     342     25      50      14      14      8
    //  0       X       0       1       512     684     50      100     28      28      16
    //  0       X       1       1       384     456     34      62      0       0       10
    //  0       X       1       2       768     912     68      124     0       0       20
    //  1       0       X       X       640     848     64      128     0       0       80
    //  1       1       X       X       640     800     96      112     0       0       48

    localparam  SHIFT_BUFFER_DELAY_LOW = 33;
    localparam  SHIFT_BUFFER_DELAY_HIGH = 65;
    // MSXimus Z 28/10/2026: era 5 y el contenido salia UN PUNTO ANTES que la ventana DA del selector en todos
    // los modos (el ultimo punto de borde mostraba el punto 0 de la imagen y el ultimo de la ventana DA el
    // backdrop: los "desplazamientos horizontales del bitmap" de docs/notas/core.md). La cadena real es PRI 1 +
    // PAL 3 + selector 1 = 5, pero el DA (STATUS.HR) va un punto por detras de MUX_HDE + 5: con 4 el bitmap,
    // los sprites y el mux arrancan un punto mas tarde juntos y el punto 0 cae en el primero de la ventana.
    localparam  COLOR_DECODE_DELAY = 4;    // MUX+PAL / CLR_DEC
    localparam  SPR_DELAY = 1;             // SPRITE DELAY

    localparam  H256_LEFT_ERASE   = 50;
    localparam  H256_LEFT_BORDER  = 14;
    localparam  H256_WIDTH        = 256;
    localparam  H256_RIGHT_BORDER = 14;
    localparam  H256_RIGHT_ERASE  = 8;
    localparam  H256_SYNC         = 25;
    localparam  H256_TOTAL        = (H256_LEFT_ERASE + H256_LEFT_BORDER + H256_WIDTH + H256_RIGHT_BORDER + H256_RIGHT_ERASE);
    localparam  H256_ACTIVE       = (H256_LEFT_ERASE + H256_LEFT_BORDER);
    localparam  H256_INACTIVE     = (H256_LEFT_ERASE + H256_LEFT_BORDER + H256_WIDTH);
    localparam  H256_DISP_ENA     = (H256_LEFT_ERASE);
    localparam  H256_DISP_DIS     = (H256_LEFT_ERASE + H256_LEFT_BORDER + H256_WIDTH + H256_RIGHT_BORDER);
    localparam  H256_BG_ACTIVE    = (H256_ACTIVE - SHIFT_BUFFER_DELAY_LOW - COLOR_DECODE_DELAY);
    localparam  H256_SPR_ACTIVE   = (H256_ACTIVE - COLOR_DECODE_DELAY - SPR_DELAY);
    localparam  H256_MUX_ACTIVE   = (H256_ACTIVE - COLOR_DECODE_DELAY);
    localparam  H256_MUX_INACTIVE = (H256_INACTIVE - COLOR_DECODE_DELAY);

    localparam  H512_LEFT_ERASE   = 100;
    localparam  H512_LEFT_BORDER  = 28;
    localparam  H512_WIDTH        = 512;
    localparam  H512_RIGHT_BORDER = 28;
    localparam  H512_RIGHT_ERASE  = 16;
    localparam  H512_SYNC         = 50;
    localparam  H512_TOTAL        = (H512_LEFT_ERASE + H512_LEFT_BORDER + H512_WIDTH + H512_RIGHT_BORDER + H512_RIGHT_ERASE);
    localparam  H512_ACTIVE       = (H512_LEFT_ERASE + H512_LEFT_BORDER);
    localparam  H512_INACTIVE     = (H512_LEFT_ERASE + H512_LEFT_BORDER + H512_WIDTH);
    localparam  H512_DISP_ENA     = (H512_LEFT_ERASE);
    localparam  H512_DISP_DIS     = (H512_LEFT_ERASE + H512_LEFT_BORDER + H512_WIDTH + H512_RIGHT_BORDER);
    localparam  H512_BG_ACTIVE    = (H512_ACTIVE - SHIFT_BUFFER_DELAY_HIGH - COLOR_DECODE_DELAY);
    localparam  H512_SPR_ACTIVE   = (H512_ACTIVE - COLOR_DECODE_DELAY - SPR_DELAY);
    localparam  H512_MUX_ACTIVE   = (H512_ACTIVE - COLOR_DECODE_DELAY);
    localparam  H512_MUX_INACTIVE = (H512_INACTIVE - COLOR_DECODE_DELAY);

    localparam  H384_LEFT_ERASE   = 62;
    localparam  H384_LEFT_BORDER  = 0;
    localparam  H384_WIDTH        = 384;
    localparam  H384_RIGHT_BORDER = 0;
    localparam  H384_RIGHT_ERASE  = 10;
    localparam  H384_SYNC         = 34;
    localparam  H384_TOTAL        = (H384_LEFT_ERASE + H384_LEFT_BORDER + H384_WIDTH + H384_RIGHT_BORDER + H384_RIGHT_ERASE);
    localparam  H384_ACTIVE       = (H384_LEFT_ERASE + H384_LEFT_BORDER);
    localparam  H384_INACTIVE     = (H384_LEFT_ERASE + H384_LEFT_BORDER + H384_WIDTH);
    localparam  H384_DISP_ENA     = (H384_LEFT_ERASE);
    localparam  H384_DISP_DIS     = (H384_LEFT_ERASE + H384_LEFT_BORDER + H384_WIDTH + H384_RIGHT_BORDER);
    localparam  H384_BG_ACTIVE    = (H384_ACTIVE - SHIFT_BUFFER_DELAY_LOW - COLOR_DECODE_DELAY);
    localparam  H384_SPR_ACTIVE   = (H384_ACTIVE - COLOR_DECODE_DELAY - SPR_DELAY);
    localparam  H384_MUX_ACTIVE   = (H384_ACTIVE - COLOR_DECODE_DELAY);
    localparam  H384_MUX_INACTIVE = (H384_INACTIVE - COLOR_DECODE_DELAY);

    localparam  H768_LEFT_ERASE   = 124;
    localparam  H768_LEFT_BORDER  = 0;
    localparam  H768_WIDTH        = 768;
    localparam  H768_RIGHT_BORDER = 0;
    localparam  H768_RIGHT_ERASE  = 20;
    localparam  H768_SYNC         = 68;
    localparam  H768_TOTAL        = (H768_LEFT_ERASE + H768_LEFT_BORDER + H768_WIDTH + H768_RIGHT_BORDER + H768_RIGHT_ERASE);
    localparam  H768_ACTIVE       = (H768_LEFT_ERASE + H768_LEFT_BORDER);
    localparam  H768_INACTIVE     = (H768_LEFT_ERASE + H768_LEFT_BORDER + H768_WIDTH);
    localparam  H768_DISP_ENA     = (H768_LEFT_ERASE);
    localparam  H768_DISP_DIS     = (H768_LEFT_ERASE + H768_LEFT_BORDER + H768_WIDTH + H768_RIGHT_BORDER);
    localparam  H768_BG_ACTIVE    = (H768_ACTIVE - SHIFT_BUFFER_DELAY_HIGH - COLOR_DECODE_DELAY);
    localparam  H768_SPR_ACTIVE   = (H768_ACTIVE - COLOR_DECODE_DELAY - SPR_DELAY);
    localparam  H768_MUX_ACTIVE   = (H768_ACTIVE - COLOR_DECODE_DELAY);
    localparam  H768_MUX_INACTIVE = (H768_INACTIVE - COLOR_DECODE_DELAY);

    localparam  H640_LEFT_ERASE   = 144;
    localparam  H640_LEFT_BORDER  = 0;
    localparam  H640_WIDTH        = 640;
    localparam  H640_RIGHT_BORDER = 0;
    localparam  H640_RIGHT_ERASE  = 64;
    localparam  H640_SYNC         = 64;
    localparam  H640_TOTAL        = (H640_LEFT_ERASE + H640_LEFT_BORDER + H640_WIDTH + H640_RIGHT_BORDER + H640_RIGHT_ERASE);
    localparam  H640_ACTIVE       = (H640_LEFT_ERASE + H640_LEFT_BORDER);
    localparam  H640_INACTIVE     = (H640_LEFT_ERASE + H640_LEFT_BORDER + H640_WIDTH);
    localparam  H640_DISP_ENA     = (H640_LEFT_ERASE);
    localparam  H640_DISP_DIS     = (H640_LEFT_ERASE + H640_LEFT_BORDER + H640_WIDTH + H640_RIGHT_BORDER);
    localparam  H640_BG_ACTIVE    = (H640_ACTIVE - SHIFT_BUFFER_DELAY_HIGH - COLOR_DECODE_DELAY);
    localparam  H640_SPR_ACTIVE   = (H640_ACTIVE - COLOR_DECODE_DELAY - SPR_DELAY);
    localparam  H640_MUX_ACTIVE   = (H640_ACTIVE - COLOR_DECODE_DELAY);
    localparam  H640_MUX_INACTIVE = (H640_INACTIVE - COLOR_DECODE_DELAY);

    localparam  H648_LEFT_ERASE   = 144;
    localparam  H648_LEFT_BORDER  = 0;
    localparam  H648_WIDTH        = 640;
    localparam  H648_RIGHT_BORDER = 0;
    localparam  H648_RIGHT_ERASE  = 16;
    localparam  H648_SYNC         = 96;
    localparam  H648_TOTAL        = (H648_LEFT_ERASE + H648_LEFT_BORDER + H648_WIDTH + H648_RIGHT_BORDER + H648_RIGHT_ERASE);
    localparam  H648_ACTIVE       = (H648_LEFT_ERASE + H648_LEFT_BORDER);
    localparam  H648_INACTIVE     = (H648_LEFT_ERASE + H648_LEFT_BORDER + H648_WIDTH);
    localparam  H648_DISP_ENA     = (H648_LEFT_ERASE);
    localparam  H648_DISP_DIS     = (H648_LEFT_ERASE + H648_LEFT_BORDER + H648_WIDTH + H648_RIGHT_BORDER);
    localparam  H648_BG_ACTIVE    = (H648_ACTIVE - SHIFT_BUFFER_DELAY_HIGH - COLOR_DECODE_DELAY);
    localparam  H648_SPR_ACTIVE   = (H648_ACTIVE - COLOR_DECODE_DELAY - SPR_DELAY);
    localparam  H648_MUX_ACTIVE   = (H648_ACTIVE - COLOR_DECODE_DELAY);
    localparam  H648_MUX_INACTIVE = (H648_INACTIVE - COLOR_DECODE_DELAY);

    //  HSCN    C25M    MCS             height  total   sync    erase   border  border  erase
    //  0       X       0               212     262     3       18      14      14      4
    //  0       X       1               240     262     3       18      0       0       4
    //  1       0       X               400     440     8       33      0       0       7
    //  1       1       X               480     525     2       35      0       0       10

    localparam  V212_TOP_ERASE     = 18;
    localparam  V212_TOP_BORDER    = 14;
    localparam  V212_HEIGHT        = 212;
    localparam  V212_BOTTOM_BORDER = 14;
    localparam  V212_BOTTOM_ERASE  = 4;
    localparam  V212_SYNC          = 3;
    localparam  V212_TOTAL         = (V212_TOP_ERASE + V212_TOP_BORDER + V212_HEIGHT + V212_BOTTOM_BORDER + V212_BOTTOM_ERASE);
    localparam  V212_ACTIVE        = (V212_TOP_ERASE + V212_TOP_BORDER);
    localparam  V212_INACTIVE      = (V212_TOP_ERASE + V212_TOP_BORDER + V212_HEIGHT);
    localparam  V212_DISP_ENA      = (V212_TOP_ERASE);
    localparam  V212_DISP_DIS      = (V212_TOP_ERASE + V212_TOP_BORDER + V212_HEIGHT + V212_BOTTOM_BORDER);
    localparam  V212_BG_ACTIVE     = (V212_ACTIVE);
    localparam  V212_SPR_ACTIVE    = (V212_ACTIVE - 1);         // -1 ラインからアトリビュート収集を開始
    localparam  V212_SPR_INACTIVE  = (V212_INACTIVE - 1);
    localparam  V212_DISP_LI_START = (V212_ACTIVE); 

    localparam  V240_TOP_ERASE     = 18;
    localparam  V240_TOP_BORDER    = 0;
    localparam  V240_HEIGHT        = 240;
    localparam  V240_BOTTOM_BORDER = 0;
    localparam  V240_BOTTOM_ERASE  = 4;
    localparam  V240_SYNC          = 3;
    localparam  V240_TOTAL         = (V240_TOP_ERASE + V240_TOP_BORDER + V240_HEIGHT + V240_BOTTOM_BORDER + V240_BOTTOM_ERASE);
    localparam  V240_ACTIVE        = (V240_TOP_ERASE + V240_TOP_BORDER);
    localparam  V240_INACTIVE      = (V240_TOP_ERASE + V240_TOP_BORDER + V240_HEIGHT);
    localparam  V240_DISP_ENA      = (V240_TOP_ERASE);
    localparam  V240_DISP_DIS      = (V240_TOP_ERASE + V240_TOP_BORDER + V240_HEIGHT + V240_BOTTOM_BORDER);
    localparam  V240_BG_ACTIVE     = (V240_ACTIVE);
    localparam  V240_SPR_ACTIVE    = (V240_ACTIVE - 1);
    localparam  V240_SPR_INACTIVE  = (V240_INACTIVE - 1);
    localparam  V240_DISP_LI_START = (V240_ACTIVE); 

    localparam  V400_TOP_ERASE     = 33;
    localparam  V400_TOP_BORDER    = 0;
    localparam  V400_HEIGHT        = 400;
    localparam  V400_BOTTOM_BORDER = 0;
    localparam  V400_BOTTOM_ERASE  = 7;
    localparam  V400_SYNC          = 8;
    localparam  V400_TOTAL         = (V400_TOP_ERASE + V400_TOP_BORDER + V400_HEIGHT + V400_BOTTOM_BORDER + V400_BOTTOM_ERASE);
    localparam  V400_ACTIVE        = (V400_TOP_ERASE + V400_TOP_BORDER);
    localparam  V400_INACTIVE      = (V400_TOP_ERASE + V400_TOP_BORDER + V400_HEIGHT);
    localparam  V400_DISP_ENA      = (V400_TOP_ERASE);
    localparam  V400_DISP_DIS      = (V400_TOP_ERASE + V400_TOP_BORDER + V400_HEIGHT + V400_BOTTOM_BORDER);
    localparam  V400_BG_ACTIVE     = (V400_ACTIVE);
    localparam  V400_SPR_ACTIVE    = (V400_ACTIVE - 1);
    localparam  V400_SPR_INACTIVE  = (V400_INACTIVE - 1);
    localparam  V400_DISP_LI_START = (V400_ACTIVE); 

    localparam  V480_TOP_ERASE     = 35;
    localparam  V480_TOP_BORDER    = 0;
    localparam  V480_HEIGHT        = 480;
    localparam  V480_BOTTOM_BORDER = 0;
    localparam  V480_BOTTOM_ERASE  = 10;
    localparam  V480_SYNC          = 2;
    localparam  V480_TOTAL         = (V480_TOP_ERASE + V480_TOP_BORDER + V480_HEIGHT + V480_BOTTOM_BORDER + V480_BOTTOM_ERASE);
    localparam  V480_ACTIVE        = (V480_TOP_ERASE + V480_TOP_BORDER);
    localparam  V480_INACTIVE      = (V480_TOP_ERASE + V480_TOP_BORDER + V480_HEIGHT);
    localparam  V480_DISP_ENA      = (V480_TOP_ERASE);
    localparam  V480_DISP_DIS      = (V480_TOP_ERASE + V480_TOP_BORDER + V480_HEIGHT + V480_BOTTOM_BORDER);
    localparam  V480_BG_ACTIVE     = (V480_ACTIVE);
    localparam  V480_SPR_ACTIVE    = (V480_ACTIVE - 1);
    localparam  V480_SPR_INACTIVE  = (V480_INACTIVE - 1);
    localparam  V480_DISP_LI_START = (V480_ACTIVE); 

    // V9990TANG: cuadro PAL (R#7 bit 3, ENABLE_PAL). openMSX V9990DisplayTiming.hh:
    //   displayPAL_MCLK = {cycle 313, blank 15, border1 41, display 212, border2 37}   (MCS = 0: P1/P2/B1/B3)
    //   displayPAL_XTAL = {cycle 313, blank 15, border1  0, display 290, border2  0}   (MCS = 1: B2/B4)
    // y sus NTSC {262, 15, 14, 212, 14} / {262, 15, 0, 240, 0}. Las tablas NTSC del tiny9990 de arriba
    // ponen 3 lineas mas de borrado arriba que el "blank" de openMSX (18 frente a 15, sincronismo incluido)
    // y 3 menos abajo (4 frente a 7); las PAL siguen el mismo convenio: 18 arriba y 313 - 15 - 41 - 212 - 37
    // - 3 = 5 abajo, con el mismo sincronismo de 3 lineas. Los modos HSCN (440/525) no cambian.
    localparam  V212P_TOP_ERASE     = 18;
    localparam  V212P_TOP_BORDER    = 41;
    localparam  V212P_HEIGHT        = 212;
    localparam  V212P_BOTTOM_BORDER = 37;
    localparam  V212P_BOTTOM_ERASE  = 5;
    localparam  V212P_SYNC          = 3;
    localparam  V212P_TOTAL         = (V212P_TOP_ERASE + V212P_TOP_BORDER + V212P_HEIGHT + V212P_BOTTOM_BORDER + V212P_BOTTOM_ERASE);
    localparam  V212P_ACTIVE        = (V212P_TOP_ERASE + V212P_TOP_BORDER);
    localparam  V212P_INACTIVE      = (V212P_TOP_ERASE + V212P_TOP_BORDER + V212P_HEIGHT);
    localparam  V212P_DISP_ENA      = (V212P_TOP_ERASE);
    localparam  V212P_DISP_DIS      = (V212P_TOP_ERASE + V212P_TOP_BORDER + V212P_HEIGHT + V212P_BOTTOM_BORDER);
    localparam  V212P_BG_ACTIVE     = (V212P_ACTIVE);
    localparam  V212P_SPR_ACTIVE    = (V212P_ACTIVE - 1);
    localparam  V212P_SPR_INACTIVE  = (V212P_INACTIVE - 1);
    localparam  V212P_DISP_LI_START = (V212P_ACTIVE);

    localparam  V290P_TOP_ERASE     = 18;
    localparam  V290P_TOP_BORDER    = 0;
    localparam  V290P_HEIGHT        = 290;
    localparam  V290P_BOTTOM_BORDER = 0;
    localparam  V290P_BOTTOM_ERASE  = 5;
    localparam  V290P_SYNC          = 3;
    localparam  V290P_TOTAL         = (V290P_TOP_ERASE + V290P_TOP_BORDER + V290P_HEIGHT + V290P_BOTTOM_BORDER + V290P_BOTTOM_ERASE);
    localparam  V290P_ACTIVE        = (V290P_TOP_ERASE + V290P_TOP_BORDER);
    localparam  V290P_INACTIVE      = (V290P_TOP_ERASE + V290P_TOP_BORDER + V290P_HEIGHT);
    localparam  V290P_DISP_ENA      = (V290P_TOP_ERASE);
    localparam  V290P_DISP_DIS      = (V290P_TOP_ERASE + V290P_TOP_BORDER + V290P_HEIGHT + V290P_BOTTOM_BORDER);
    localparam  V290P_BG_ACTIVE     = (V290P_ACTIVE);
    localparam  V290P_SPR_ACTIVE    = (V290P_ACTIVE - 1);
    localparam  V290P_SPR_INACTIVE  = (V290P_INACTIVE - 1);
    localparam  V290P_DISP_LI_START = (V290P_ACTIVE);

    // cuadro PAL de la ventana (pal_w) y del sincronismo (pal_s): ver "V9990TANG: PAL y R#16" abajo
    logic pal_w;
    logic pal_s;
    // reajuste de la ventana por R#16 (ver "V9990TANG: PAL y R#16" abajo)
    logic       h_adj;          // en este DCLK_EN h_cnt salta a h_jump (linea ADJ_LINE de la ventana)
    logic [9:0] h_jump;
    logic       ext_run;        // la ventana alarga su cuadro: lineas de mas despues de V_TOTAL
    logic [3:0] ext_left;       // lineas de mas que quedan (contando la actual)
    logic [3:0] v_ext;          // lineas que alargara el cuadro que acaba (0 = ninguna)
    logic [3:0] v_first;        // linea con la que empieza el cuadro siguiente (> 0: se salta lineas)

    wire [9:0]  H_RESET         = REG.HSCN ? (REG.C25M ? (H648_TOTAL         - 2'd2) : (H640_TOTAL         - 2'd2)) : REG.MCS ? (REG.DCKM[1] ? (H768_TOTAL         - 2'd2) : (H384_TOTAL         - 2'd2)) : (REG.DCKM[0] ? (H512_TOTAL         - 2'd2) : (H256_TOTAL         - 2'd2));
    wire [9:0]  H_HR_ACTIVE     = REG.HSCN ? (REG.C25M ? (H648_ACTIVE        - 1'd1) : (H640_ACTIVE        - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_ACTIVE        - 1'd1) : (H384_ACTIVE        - 1'd1)) : (REG.DCKM[0] ? (H512_ACTIVE        - 1'd1) : (H256_ACTIVE        - 1'd1));
    wire [9:0]  H_HR_INACTIVE   = REG.HSCN ? (REG.C25M ? (H648_INACTIVE      - 1'd1) : (H640_INACTIVE      - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_INACTIVE      - 1'd1) : (H384_INACTIVE      - 1'd1)) : (REG.DCKM[0] ? (H512_INACTIVE      - 1'd1) : (H256_INACTIVE      - 1'd1));
    wire [9:0]  H_MUX_ACTIVE    = REG.HSCN ? (REG.C25M ? (H648_MUX_ACTIVE    - 1'd1) : (H640_MUX_ACTIVE    - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_MUX_ACTIVE    - 1'd1) : (H384_MUX_ACTIVE    - 1'd1)) : (REG.DCKM[0] ? (H512_MUX_ACTIVE    - 1'd1) : (H256_MUX_ACTIVE    - 1'd1));
    wire [9:0]  H_MUX_INACTIVE  = REG.HSCN ? (REG.C25M ? (H648_MUX_INACTIVE  - 1'd1) : (H640_MUX_INACTIVE  - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_MUX_INACTIVE  - 1'd1) : (H384_MUX_INACTIVE  - 1'd1)) : (REG.DCKM[0] ? (H512_MUX_INACTIVE  - 1'd1) : (H256_MUX_INACTIVE  - 1'd1));
    wire [9:0]  H_DISP_ENA      = REG.HSCN ? (REG.C25M ? (H648_DISP_ENA      - 1'd1) : (H640_DISP_ENA      - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_DISP_ENA      - 1'd1) : (H384_DISP_ENA      - 1'd1)) : (REG.DCKM[0] ? (H512_DISP_ENA      - 1'd1) : (H256_DISP_ENA      - 1'd1));
    wire [9:0]  H_DISP_DIS      = REG.HSCN ? (REG.C25M ? (H648_DISP_DIS      - 1'd1) : (H640_DISP_DIS      - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_DISP_DIS      - 1'd1) : (H384_DISP_DIS      - 1'd1)) : (REG.DCKM[0] ? (H512_DISP_DIS      - 1'd1) : (H256_DISP_DIS      - 1'd1));
    wire [9:0]  H_SYNC_PERIOD   = REG.HSCN ? (REG.C25M ? (H648_SYNC          - 1'd1) : (H640_SYNC          - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_SYNC          - 1'd1) : (H384_SYNC          - 1'd1)) : (REG.DCKM[0] ? (H512_SYNC          - 1'd1) : (H256_SYNC          - 1'd1));    // HSYNC 期間(DCLK タイミング用)

    wire [9:0]  V_TOTAL         = REG.HSCN ? (REG.C25M ? (V480_TOTAL         - 1'd1) : (V400_TOTAL         - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_TOTAL - 1'd1) : (V212P_TOTAL - 1'd1)) : (REG.MCS ? (V240_TOTAL         - 1'd1) : (V212_TOTAL         - 1'd1)));   // 縦総ライン数(v_incタイミング用)
    wire [9:0]  V_TOTAL_S       = REG.HSCN ? (REG.C25M ? (V480_TOTAL         - 1'd1) : (V400_TOTAL         - 1'd1)) : (pal_s ? (REG.MCS ? (V290P_TOTAL - 1'd1) : (V212P_TOTAL - 1'd1)) : (REG.MCS ? (V240_TOTAL         - 1'd1) : (V212_TOTAL         - 1'd1)));   // V9990TANG: lineas - 1 del cuadro de sincronismo (R#16)
    wire [9:0]  V_SYNC_PERIOD   = REG.HSCN ? (REG.C25M ? (V480_SYNC          - 1'd1) : (V400_SYNC          - 1'd1)) : (REG.MCS ? (V240_SYNC          - 1'd1) : (V212_SYNC          - 1'd1));   // VSYNC inactive ライン(v_incタイミング用)
    wire [9:0]  V_VR_ACTIVE     = REG.HSCN ? (REG.C25M ? (V480_ACTIVE        - 1'd1) : (V400_ACTIVE        - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_ACTIVE - 1'd1) : (V212P_ACTIVE - 1'd1)) : (REG.MCS ? (V240_ACTIVE        - 1'd1) : (V212_ACTIVE        - 1'd1)));
    wire [9:0]  V_VR_INACTIVE   = REG.HSCN ? (REG.C25M ? (V480_INACTIVE      - 1'd1) : (V400_INACTIVE      - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_INACTIVE - 1'd1) : (V212P_INACTIVE - 1'd1)) : (REG.MCS ? (V240_INACTIVE      - 1'd1) : (V212_INACTIVE      - 1'd1)));
    wire [9:0]  V_MUX_ACTIVE    = REG.HSCN ? (REG.C25M ? (V480_ACTIVE        - 1'd1) : (V400_ACTIVE        - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_ACTIVE - 1'd1) : (V212P_ACTIVE - 1'd1)) : (REG.MCS ? (V240_ACTIVE        - 1'd1) : (V212_ACTIVE        - 1'd1)));
    wire [9:0]  V_MUX_INACTIVE  = REG.HSCN ? (REG.C25M ? (V480_INACTIVE      - 1'd1) : (V400_INACTIVE      - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_INACTIVE - 1'd1) : (V212P_INACTIVE - 1'd1)) : (REG.MCS ? (V240_INACTIVE      - 1'd1) : (V212_INACTIVE      - 1'd1)));
    wire [9:0]  V_DISP_ENA      = REG.HSCN ? (REG.C25M ? (V480_DISP_ENA      - 1'd1) : (V400_DISP_ENA      - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_DISP_ENA - 1'd1) : (V212P_DISP_ENA - 1'd1)) : (REG.MCS ? (V240_DISP_ENA      - 1'd1) : (V212_DISP_ENA      - 1'd1)));   // VD active(v_incタイミング用)
    wire [9:0]  V_DISP_DIS      = REG.HSCN ? (REG.C25M ? (V480_DISP_DIS      - 1'd1) : (V400_DISP_DIS      - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_DISP_DIS - 1'd1) : (V212P_DISP_DIS - 1'd1)) : (REG.MCS ? (V240_DISP_DIS      - 1'd1) : (V212_DISP_DIS      - 1'd1)));   // VD inactive ライン(v_incタイミング用)
    wire [9:0]  V_DISP_LI_START = REG.HSCN ? (REG.C25M ? (V480_DISP_LI_START - 1'd1) : (V400_DISP_LI_START - 1'd1)) : (pal_w ? (REG.MCS ? (V290P_DISP_LI_START - 1'd1) : (V212P_DISP_LI_START - 1'd1)) : (REG.MCS ? (V240_DISP_LI_START - 1'd1) : (V212_DISP_LI_START - 1'd1)));   // ILカウンタ開始ライン(v_inc タイミング用)

    // MSXimus Z 28/10/2026: en B2 y B4 tbl_init / BG_START van 3 / 2 puntos antes de H_BG_ACTIVE, como en
    // B1/B3. Eran 4/3 en B2 (el punto 0 de la imagen caia en el borrado: B2 no tiene borde) y 6/5 en B4 (la
    // imagen salia 3 puntos antes y acababa con tres puntos de backdrop).
    wire [9:0]  H_BG_INIT       = REG.HSCN ? (REG.C25M ? (H648_BG_ACTIVE     - 2'd3) : (H640_BG_ACTIVE     - 2'd3)) : REG.MCS ? (REG.DCKM[1] ? (H768_BG_ACTIVE     - 2'd3) : (H384_BG_ACTIVE     - 2'd3)) : (REG.DCKM[0] ? (H512_BG_ACTIVE     - 2'd3) : (H256_BG_ACTIVE     - 2'd3));
    wire [9:0]  H_BG_START      = REG.HSCN ? (REG.C25M ? (H648_BG_ACTIVE     - 2'd2) : (H640_BG_ACTIVE     - 2'd2)) : REG.MCS ? (REG.DCKM[1] ? (H768_BG_ACTIVE     - 2'd2) : (H384_BG_ACTIVE     - 2'd2)) : (REG.DCKM[0] ? (H512_BG_ACTIVE     - 2'd2) : (H256_BG_ACTIVE     - 2'd2));
    wire [9:0]  H_BG_ACTIVE     = REG.HSCN ? (REG.C25M ? (H648_BG_ACTIVE     - 1'd1) : (H640_BG_ACTIVE     - 1'd1)) : REG.MCS ? (REG.DCKM[1] ? (H768_BG_ACTIVE     - 1'd1) : (H384_BG_ACTIVE     - 1'd1)) : (REG.DCKM[0] ? (H512_BG_ACTIVE     - 1'd1) : (H256_BG_ACTIVE     - 1'd1));
    wire [9:0]  H_SPR_OUT_START = REG.HSCN ? (REG.C25M ? (H648_SPR_ACTIVE    - 2'd2) : (H640_SPR_ACTIVE    - 2'd2)) : REG.MCS ? (REG.DCKM[1] ? (H768_SPR_ACTIVE    - 2'd2) : (H384_SPR_ACTIVE    - 2'd2)) : (REG.DCKM[0] ? (H512_SPR_ACTIVE    - 2'd2) : (H256_SPR_ACTIVE    - 2'd2));

    wire [9:0]  V_BG_ACTIVE     = REG.HSCN ? (REG.C25M ? (V480_BG_ACTIVE           ) : (V400_BG_ACTIVE           )) : (pal_w ? (REG.MCS ? (V290P_BG_ACTIVE) : (V212P_BG_ACTIVE)) : (REG.MCS ? (V240_BG_ACTIVE           ) : (V212_BG_ACTIVE           )));   // BG 処理開始ライン
    wire [9:0]  V_SPR_ACTIVE    = REG.HSCN ? (REG.C25M ? (V480_SPR_ACTIVE          ) : (V400_SPR_ACTIVE          )) : (pal_w ? (REG.MCS ? (V290P_SPR_ACTIVE) : (V212P_SPR_ACTIVE)) : (REG.MCS ? (V240_SPR_ACTIVE          ) : (V212_SPR_ACTIVE          )));   // スプライト処理開始ライン
    wire [9:0]  V_SPR_INACTIVE  = REG.HSCN ? (REG.C25M ? (V480_SPR_INACTIVE        ) : (V400_SPR_INACTIVE        )) : (pal_w ? (REG.MCS ? (V290P_SPR_INACTIVE) : (V212P_SPR_INACTIVE)) : (REG.MCS ? (V240_SPR_INACTIVE        ) : (V212_SPR_INACTIVE        )));   // スプライト処理終了ライン

    /***************************************************************
     * h_cnt(HSYNCからのカウント)
     ***************************************************************/
    logic h_rst;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)     h_rst <= 0;
        else if(!TG_EN)  h_rst <= 0;
        else if(DCLK_EN) h_rst <= (h_cnt == H_RESET);
    end

    logic [9:0] h_cnt;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)              h_cnt <= 0;
        else if(!TG_EN)           h_cnt <= 0;
        else if(DCLK_EN && h_rst) h_cnt <= 0;
        else if(h_adj           ) h_cnt <= h_jump;          // V9990TANG: R#16 (h_adj ya lleva DCLK_EN)
        else if(DCLK_EN         ) h_cnt <= h_cnt + 1'd1;
    end

    /***************************************************************
     * v_cnt(VSYNCからのカウント)
     ***************************************************************/
    wire v_inc = h_rst;

    logic v_rst;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)     v_rst <= 0;
        else if(!TG_EN)  v_rst <= 0;
        // V9990TANG: con R#16 el cuadro de la ventana puede alargarse v_ext lineas (ext_run)
        else if(DCLK_EN) v_rst <= (h_cnt == H_RESET) && (ext_run ? (ext_left == 4'd1) : ((v_cnt == V_TOTAL) && (v_ext == 4'd0)));
    end

    logic [8:0] v_cnt;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)              v_cnt <= 0;
        else if(!TG_EN)           v_cnt <= 0;
        else if(DCLK_EN && v_rst) v_cnt <= {5'd0, v_first};     // V9990TANG: > 0 si R#16 sube la imagen
        else if(DCLK_EN && v_inc) v_cnt <= v_cnt + 1'd1;
    end

    /***************************************************************
     * SPR_START
     ***************************************************************/
    // V9990TANG (ENABLE_SPR_LINE0): T9990_SPRITE lee en cada linea los datos de la linea siguiente y los
    // pasa a su salida al acabar la lectura; SPR_START empieza a sacarlos. En las lineas de imagen la
    // lectura acaba tarde (el bitmap tiene prioridad) y lo leido sale en la linea siguiente, pero en la
    // linea anterior a la primera (V_SPR_ACTIVE, sin bitmap) puede acabar antes del SPR_START de esa
    // misma linea (en B1 BD16 pasa: fpga/tb/core, +EOR=1, cursor con Y = 500), se gastaba en ella
    // (borde) y la primera linea de imagen salia sin cursor (Y de 480 a 511). Sin SPR_START en esa
    // linea los datos esperan a la primera linea de imagen.
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                 SPR_START <= 0;
        else if(DCLK_EN && h_cnt == H_SPR_OUT_START && !(ENABLE_SPR_LINE0 != 0 && v_cnt == V_SPR_ACTIVE[8:0]))
                                                     SPR_START <= 1;
        else                                         SPR_START <= 0;
    end

    /***************************************************************
     * SPR_Y
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                             SPR_Y <= 0;
        else if(DCLK_EN && h_cnt == H_BG_ACTIVE) SPR_Y <= (v_cnt == V_SPR_ACTIVE) ? 9'd0 : (SPR_Y + 1'd1);
    end

    /***************************************************************
     * spr_v_ena
     ***************************************************************/
    logic spr_v_ena;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                                        spr_v_ena <= 0;
        else if(DCLK_EN && h_cnt == H_BG_ACTIVE && v_cnt == V_SPR_ACTIVE)   spr_v_ena <= 1;
        else if(DCLK_EN && h_cnt == H_BG_ACTIVE && v_cnt == V_SPR_INACTIVE) spr_v_ena <= 0;
    end

    /***************************************************************
     * BG_START
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                            BG_START <= 0;
        else if(DCLK_EN && h_cnt == H_BG_START) BG_START <= 1;
        else                                    BG_START <= 0;
    end

    /***************************************************************
     * BG_X
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                             BG_X <= 0;
        else if(DCLK_EN && h_cnt == H_BG_ACTIVE) BG_X <= 0;
        else if(DCLK_EN)                         BG_X <= BG_X + 1'd1;
    end

    /***************************************************************
     * y_cnt
     ***************************************************************/
    logic [8:0] bg_y_cnt;
    wire [8:0] bg_y_cnt_new = bg_y_cnt + 1'd1;

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                             bg_y_cnt <= 0;
        else if(DCLK_EN && h_cnt == H_BG_ACTIVE) bg_y_cnt <= (v_cnt == V_BG_ACTIVE) ? 0 : bg_y_cnt_new;
    end

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                                     BG_Y <= 0;
        else if(DCLK_EN && h_cnt == H_BG_ACTIVE && v_cnt == V_BG_ACTIVE) BG_Y <= (REG.ILM && REG.EO && !REG.HSCN) ? {9'd0, STATUS.EO}              : 0;
        else if(DCLK_EN && h_cnt == H_BG_ACTIVE)                         BG_Y <= (REG.ILM && REG.EO && !REG.HSCN) ? {bg_y_cnt_new[8:0], STATUS.EO} : {1'b0, bg_y_cnt_new};
    end

    /***************************************************************
     * STATUS.EO
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                 STATUS.EO <= 0;
        else if(DCLK_EN && !REG.ILM) STATUS.EO <= 0;
        else if(DCLK_EN && v_rst)    STATUS.EO <= !STATUS.EO;
    end

    /***************************************************************
     * HSYNC
     ***************************************************************/
    logic hs_w;     // V9990TANG: el HS original, en coordenadas de la ventana (sin R#16)
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                               hs_w <= 0;
        else if(DCLK_EN && h_rst)                  hs_w <= 1;
        else if(DCLK_EN && h_cnt == H_SYNC_PERIOD) hs_w <= 0;
    end

    /***************************************************************
     * VSYNC
     ***************************************************************/
    logic vs_w;     // V9990TANG: el VS original, en coordenadas de la ventana (sin R#16)
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                        vs_w <= 0;
        else if(DCLK_EN && v_rst)                           vs_w <= 1;
        else if(DCLK_EN && v_inc && v_cnt == V_SYNC_PERIOD) vs_w <= 0;
    end

    /***************************************************************
     * V9990TANG: PAL y R#16
     *
     * Dos pares de contadores: s_h/s_v son los del SINCRONISMO (HS/VS, FIELD, PAL)
     * y corren libres, con las reglas del hito 1 y sin reajustarse nunca: el cuadro
     * de VS a VS y la linea de HS a HS son siempre los mismos, como en openMSX
     * (V9990.cc frameStart: syncVSync = frameStartTime + getUCTicksPerFrame, que no
     * depende de R#16). h_cnt/v_cnt son la VENTANA: todo lo que se ve (bordes, fetch
     * de VRAM, HR/VR, interrupciones, BG/SPR) se mide con ellas. R#16 mueve la ventana
     * frente al sincronismo, como en openMSX (frameStart: syncDisplayStart =
     * frameStartTime + getTopBorder lineas, y la imagen de cada linea empieza en
     * getLeftBorder). En regimen la ventana va desplazada (adj_v lineas, adj_h
     * puntos) frente al sincronismo: s = ventana + adj. Con R#16 = 00h adj = 0 y las
     * dos parejas coinciden ciclo a ciclo (HS/VS son los del hito 1).
     *
     * openMSX (V9990.hh): getLeftBorder = blank + border1 + (((R16 & 0Fh) ^ 7) - 8) * 8
     * ticks UC y getTopBorder = blank + border1 + ((R16 >> 4) ^ 7) - 8 lineas. Respecto
     * a R#16 = 00h (-1 en esa formula) el desplazamiento es k = (n ^ 7) - 7, de -7 a
     * +8 (+ = imagen a la derecha / abajo): 0 = posicion estandar, 1..7 = 1..7 pasos
     * a la izquierda / arriba, Fh..8 = 1..8 pasos a la derecha / abajo, igual que la
     * tabla de R#16 del manual (V9990 E-VDP-III application manual, 12.2, pag. 84).
     * Unidad horizontal: el manual da "P1 y B1 de 1 en 1 punto, P2, B2 y B3 de 2 en 2,
     * B4, B5 y B6 de 4 en 4" (4 ciclos del reloj maestro en todos los modos). openMSX
     * usa 8 ticks UC en todos (= 4 ciclos del maestro de 21 MHz, pero 8/3 del de 14
     * MHz: 4/3 de punto en B2 y 8/3 en B4); aqui se sigue el manual, que da puntos
     * enteros. En P1/P2/B1/B3 los dos coinciden.
     *
     * Cambio de R#16: se lleva la ventana a la posicion nueva UNA vez, dentro de su
     * borrado, con la diferencia entre el desplazamiento nuevo y el que esta en vigor
     * (adj_v_q/adj_h_q). Vertical (dv = -15..+15 lineas), al acabar el cuadro de la
     * ventana (h_cnt = H_RESET en la linea V_TOTAL): con dv > 0 el cuadro se alarga dv
     * lineas (v_cnt sigue mas alla de V_TOTAL, donde no hay ninguna comparacion), con
     * dv < 0 el cuadro siguiente empieza en su linea -dv (se salta lineas 0..14 del
     * borrado superior, donde solo esta el VS propio de la ventana, que no sale).
     * Horizontal (dh = -60..+60 puntos), en la linea ADJ_LINE = 16 de la ventana
     * (borrado superior en todos los modos; el vertical nunca se la salta), en el
     * punto hj_p = H_HR_ACTIVE + 80: h_cnt salta a hj_p + 1 - dh (repite o se salta dh
     * puntos). Entre hj_p - 60 y hj_p + 60 no hay ninguna comparacion de h_cnt en
     * ningun modo (la ultima de la izquierda es H_HR_ACTIVE, la primera de la derecha
     * H_MUX_INACTIVE), y en una linea de borrado solo hay accesos de la CPU/blitter y
     * de refresco, que van por MEM_REQ y no por h_cnt. Asi la irregularidad de un
     * cambio cae en el cuadro de la ventana (el intervalo entre VI y entre lineas de
     * imagen), como en openMSX, y nunca en el sincronismo. Un cambio de modo (MCS,
     * DCKM, HSCN, C25M) baja TG_EN (T9990_CLOCK) y pone a 0 las dos parejas y adj_q:
     * vuelven a coincidir y el cuadro siguiente aplica R#16 desde 0.
     *
     * PAL: R#7 bit 3 se toma al empezar cada cuadro de sincronismo (openMSX
     * frameStart, en el VSYNC) -> pal_s, que da la longitud de ese cuadro (VS a VS) y
     * es la salida PAL_FRAME. La ventana usa pal_w, la copia de pal_s al final de su
     * linea 15 (PAL_LINE): el VS cae como mucho 8 lineas antes o despues del (0,0) de
     * la ventana, el reajuste vertical se salta como mucho las lineas 0..14 y ninguna
     * comparacion de la ventana que dependa de PAL cae antes de su linea 17, asi que
     * pal_w ya es el del cuadro de sincronismo que va con el de la ventana y los dos
     * cuadros tienen la misma longitud.
     ***************************************************************/
    wire r16_on  = (ENABLE_R16 != 0);
    wire pal_req = (ENABLE_PAL != 0) && REG.PAL_TIMING && !REG.HSCN;

    // k = (n ^ 7) - 7 se indexa con t = n ^ 7 (k = t - 7)
    wire [3:0] adj_th = REG.DADJ[3:0] ^ 4'd7;
    wire [3:0] adj_tv = REG.DADJ[7:4] ^ 4'd7;

    // desplazamiento horizontal en puntos (manual, R#16): k x 1 con DCKM = 1/4 (P1, B1), k x 2 con
    // DCKM = 1/2 (P2, B3, B2) y k x 4 con DCKM = 1/1 (B4) y en HSCN (B5, B6)
    wire signed [6:0] adj_k     = $signed({3'b000, adj_th}) - 7'sd7;
    wire signed [6:0] adj_h_new = (!REG.HSCN && REG.DCKM == T9990_REG::DCKM_DIV4) ? adj_k :
                                  (!REG.HSCN && REG.DCKM == T9990_REG::DCKM_DIV2) ? (adj_k <<< 1) : (adj_k <<< 2);
    wire signed [4:0] adj_v_new = $signed({1'b0, adj_tv}) - 5'sd7;

    localparam [8:0] ADJ_LINE = 9'd16;      // linea de la ventana del reajuste horizontal
    localparam [8:0] PAL_LINE = 9'd15;      // linea de la ventana en la que se copia pal_s en pal_w

    logic signed [6:0] adj_h_q;             // desplazamiento en vigor (sincronismo - ventana)
    logic signed [4:0] adj_v_q;

    // Tiempo: R#16 y el punto del reajuste pasan por dos registros antes de llegar a los contadores
    // (R#7/R#16 -> desplazamiento -> diferencia -> destino). El destino de cada eje (h_tgt/h_jump,
    // v_tgt/v_ext/v_skip) sale del mismo ciclo y del mismo adj_*_q, asi que es coherente; adj_*_q solo
    // cambia en el reajuste, una vez por cuadro.
    logic signed [6:0] adj_h_a;
    logic signed [4:0] adj_v_a;
    logic [9:0]        hj_p;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            adj_h_a <= 0;
            adj_v_a <= 0;
            hj_p    <= 0;
        end
        else begin
            adj_h_a <= r16_on ? adj_h_new : 7'sd0;
            adj_v_a <= r16_on ? adj_v_new : 5'sd0;
            hj_p    <= H_HR_ACTIVE + 10'd80;
        end
    end

    wire signed [6:0] dh  = adj_h_a - adj_h_q;     // -60..+60
    wire signed [4:0] dv  = adj_v_a - adj_v_q;     // -15..+15
    wire        [4:0] ndv = -dv;
    logic signed [6:0] h_tgt;
    logic signed [4:0] v_tgt;
    logic        [3:0] v_skip;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            h_tgt  <= 0;
            h_jump <= 0;
            v_tgt  <= 0;
            v_ext  <= 0;
            v_skip <= 0;
        end
        else begin
            h_tgt  <= adj_h_a;
            h_jump <= hj_p + 10'd1 - {{3{dh[6]}}, dh};
            v_tgt  <= adj_v_a;
            v_ext  <= (dv > 0) ? dv[3:0]  : 4'd0;
            v_skip <= (dv < 0) ? ndv[3:0] : 4'd0;
        end
    end

    // reajuste vertical: al acabar el cuadro de la ventana (el mismo DCLK_EN en que se calcula v_rst)
    wire v_dec = r16_on && DCLK_EN && (h_cnt == H_RESET) && !ext_run && (v_cnt == V_TOTAL);
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            adj_v_q  <= 0;
            ext_run  <= 0;
            ext_left <= 0;
            v_first  <= 0;
        end
        else if(!TG_EN) begin
            adj_v_q  <= 0;
            ext_run  <= 0;
            ext_left <= 0;
            v_first  <= 0;
        end
        else if(v_dec) begin
            adj_v_q  <= v_tgt;
            v_first  <= v_skip;                 // 0 si se alarga
            ext_run  <= (v_ext != 4'd0);
            ext_left <= v_ext;
        end
        else if(DCLK_EN && ext_run && (h_cnt == H_RESET)) begin
            ext_left <= ext_left - 1'd1;
            if(ext_left == 4'd1) ext_run <= 0;  // v_rst en esta misma linea
        end
    end

    // reajuste horizontal: una vez en la linea ADJ_LINE (h_adj_done: con dh > 0 h_cnt vuelve a pasar por hj_p)
    logic h_adj_done;
    assign h_adj = r16_on && DCLK_EN && (v_cnt == ADJ_LINE) && (h_cnt == hj_p) && !h_adj_done;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            adj_h_q    <= 0;
            h_adj_done <= 0;
        end
        else if(!TG_EN) begin
            adj_h_q    <= 0;
            h_adj_done <= 0;
        end
        else if(h_adj) begin
            adj_h_q    <= h_tgt;
            h_adj_done <= 1;
        end
        else if(DCLK_EN && h_rst) begin
            h_adj_done <= 0;
        end
    end

    // sincronismo: cuenta libre, mismas reglas que h_cnt/v_cnt/HS/VS del hito 1
    logic [9:0] s_h;
    logic [8:0] s_v;
    logic       s_hrst;
    logic       s_vrst;
    logic       hs_s;
    logic       vs_s;
    logic       eo_s;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            s_h <= 0;
            s_v <= 0;
            s_hrst <= 0;
            s_vrst <= 0;
            hs_s <= 0;
            vs_s <= 0;
        end
        else if(!TG_EN) begin
            s_h <= 0;
            s_v <= 0;
            s_hrst <= 0;
            s_vrst <= 0;
        end
        else if(DCLK_EN) begin
            s_hrst <= (s_h == H_RESET);
            s_vrst <= (s_h == H_RESET) && (s_v == V_TOTAL_S);
            s_h    <= s_hrst ? 10'd0 : (s_h + 1'd1);
            if(s_vrst)      s_v <= 0;
            else if(s_hrst) s_v <= s_v + 1'd1;
            if(s_hrst)                      hs_s <= 1;
            else if(s_h == H_SYNC_PERIOD)   hs_s <= 0;
            if(s_vrst)                              vs_s <= 1;
            else if(s_hrst && s_v == V_SYNC_PERIOD) vs_s <= 0;
        end
    end

    // PAL del cuadro de sincronismo y EO del campo que empieza con el VS. El cuadro de la ventana que va
    // con este VS empieza como mucho 8 lineas antes o despues: si la ventana esta en sus primeras lineas
    // (v_cnt < 32) ya ha empezado y STATUS.EO es el suyo; si esta al final de su cuadro (o en las lineas
    // de mas de un alargue, o en el mismo DCLK_EN de su v_rst) aun no, y su EO sera eo_next.
    wire s_frame     = DCLK_EN && s_vrst;                       // empieza un cuadro de sincronismo
    wire win_frame   = DCLK_EN && v_rst;                        // (0,0) de la ventana
    wire win_started = (v_cnt[8:5] == 4'd0);
    wire eo_next     = REG.ILM ? !STATUS.EO : 1'b0;             // el EO que la ventana pone en v_rst
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            pal_s <= 0;
            eo_s  <= 0;
        end
        else if(ENABLE_R16 != 0) begin
            if(s_frame) begin
                pal_s <= pal_req;
                eo_s  <= win_started ? STATUS.EO : eo_next;
            end
        end
        else if(win_frame) begin
            pal_s <= pal_req;               // sin R#16 la ventana y el sincronismo coinciden
        end
    end

    // PAL de la ventana
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                                pal_w <= 0;
        else if(ENABLE_R16 == 0)                                    pal_w <= pal_s;
        else if(DCLK_EN && v_inc && v_cnt == PAL_LINE)              pal_w <= pal_s;
    end

    assign HS        = (ENABLE_R16 != 0) ? hs_s : hs_w;
    assign VS        = (ENABLE_R16 != 0) ? vs_s : vs_w;
    assign FIELD     = (ENABLE_R16 != 0) ? eo_s : STATUS.EO;
    assign PAL_FRAME = pal_s;
    assign PAL_WIN   = pal_w;

    /***************************************************************
     * STATUS.HR(ボーダーを含まない表示期間)
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                               STATUS.HR <= 1;
        else if(DCLK_EN && h_cnt == H_HR_ACTIVE)   STATUS.HR <= 0;
        else if(DCLK_EN && h_cnt == H_HR_INACTIVE) STATUS.HR <= 1;
    end

    /***************************************************************
     * MUX HDE
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                MUX_HDE <= 0;
        else if(DCLK_EN && h_cnt == H_MUX_ACTIVE)   MUX_HDE <= 1;
        else if(DCLK_EN && h_cnt == H_MUX_INACTIVE) MUX_HDE <= 0;
    end

    /***************************************************************
     * HD(ボーダーを含む表示期間)
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                            HD <= 0;
        else if(DCLK_EN && h_cnt == H_DISP_ENA) HD <= 1;
        else if(DCLK_EN && h_cnt == H_DISP_DIS) HD <= 0;
    end

    /***************************************************************
     * STATUS.HI
     ***************************************************************/
    logic [10:0] mclk_cnt;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                             mclk_cnt <= 0;
        else if(DCLK_EN && h_cnt == H_HR_ACTIVE) mclk_cnt <= 0;
        else if(CLK_MASTER_EN)                   mclk_cnt <= mclk_cnt + 1'd1;
    end

    logic [9:0] disp_line;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                            disp_line <= 0;
        else if(DCLK_EN && v_inc && (v_cnt == V_DISP_LI_START)) disp_line <= 0;
        else if(DCLK_EN && v_inc)                               disp_line <= disp_line + 1'd1;
    end

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                                        STATUS.HI <= 0;
        else if(!CLK_MASTER_EN)                                             STATUS.HI <= 0;
        else if((mclk_cnt == {REG.IX, 6'b000000}) && (disp_line == REG.IL)) STATUS.HI <= 1;
        else                                                                STATUS.HI <= 0;
    end

    /***************************************************************
     * MSXimus Z 21/10/2026: reinicio del scroll vertical y R#18/R#22
     *  Como openMSX (V9990PixelRenderer::updateScrollAYLow/BYLow, "verified" en el chip real):
     *  escribir R#17 (o R#21) con la pantalla encendida y dentro del area visible reinicia la
     *  cuenta de lineas del plano: desde ese punto la linea L muestra la linea 0 del nuevo scroll
     *  y la L+k la k. Fuera del area visible no reinicia nada. R#18/R#22 (parte alta) se toman
     *  una vez por cuadro (openMSX scrollAYHigh en frameStart): aqui siguen al registro fuera
     *  del area visible y se congelan dentro. DISP tambien se toma una vez por cuadro, como el
     *  displayEnabled de openMSX.
     *  La ventana sale de v_cnt (= !STATUS.VR en marcha normal) y no de STATUS.VR: cuando
     *  T9990_CLOCK rearranca el TG (cambio de MCS/DCKM/HSCN/C25M) a mitad de pantalla, v_cnt
     *  vuelve a 0 pero STATUS.VR se queda a 0 hasta el final del area visible siguiente.
     *  disp_line cambia en el v_inc (como el lastY de openMSX) y vuelve a 0 justo al abrirse la
     *  ventana (V_DISP_LI_START = V_VR_ACTIVE); el fetch de la linea de pantalla L se hace dentro
     *  de la linea L con BG_Y = L, asi que el plano usa Y = SCAY + (BG_Y - VOFS). Xybots lo usa
     *  para partir la pantalla (R#17 en la linea 95).
     *  V9990TANG: v_cnt es el contador de la ventana (el que mueve R#16), el mismo de BG_Y y
     *  disp_line; con el cuadro de la ventana alargado por un reajuste de R#16 v_cnt pasa de
     *  V_TOTAL, fuera de esta ventana.
     ***************************************************************/
    wire vofs_win = TG_EN && (v_cnt > V_VR_ACTIVE) && (v_cnt <= V_VR_INACTIVE);
    logic disp_fs;
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            VOFS_A  <= 0;
            VOFS_B  <= 0;
            SCAY_HI <= 0;
            SCBY_HI <= 0;
            disp_fs <= 0;
        end
        else if(!vofs_win) begin
            VOFS_A  <= 0;
            VOFS_B  <= 0;
            SCAY_HI <= REG.SCAY[12:8];
            SCBY_HI <= REG.SCBY[8];
            disp_fs <= REG.DISP;
        end
        else begin
            if(REG.SCAYL_WR && disp_fs) VOFS_A <= disp_line[8:0];
            if(REG.SCBYL_WR && disp_fs) VOFS_B <= disp_line[8:0];
        end
    end

    /***************************************************************
     * STATUS.VR(ボーダーを含まない表示期間)
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                        STATUS.VR <= 1;
        else if(DCLK_EN && v_inc && v_cnt == V_VR_ACTIVE)   STATUS.VR <= 0;
        else if(DCLK_EN && v_inc && v_cnt == V_VR_INACTIVE) STATUS.VR <= 1;
    end

    /***************************************************************
     * MUX VDE
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                         MUX_VDE <= 0;
        else if(DCLK_EN && v_inc && v_cnt == V_MUX_ACTIVE)   MUX_VDE <= 1;
        else if(DCLK_EN && v_inc && v_cnt == V_MUX_INACTIVE) MUX_VDE <= 0;
    end

    /***************************************************************
     * VD(ボーダーを含む表示期間)
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                     VD <= 0;
        else if(DCLK_EN && v_inc && v_cnt == V_DISP_ENA) VD <= 1;
        else if(DCLK_EN && v_inc && v_cnt == V_DISP_DIS) VD <= 0;
    end

    /***************************************************************
     * STATUS.VI
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                        STATUS.VI <= 0;
        else if(DCLK_EN && v_inc && v_cnt == V_VR_INACTIVE) STATUS.VI <= 1; // 表示期間完了時に1(ToDo: ボーダーを含むか含まないかを確認)
        else                                                STATUS.VI <= 0;
    end

    /***************************************************************
     * RAM タイミング
     ***************************************************************/
    wire tbl_init = DCLK_EN && (h_cnt == (H_BG_INIT));
    wire cnt_init = DCLK_EN && (h_cnt == (H_BG_INIT));
    wire tbl_send = MEM_REQ && (h_cnt != (H_BG_START));
    logic cnt_dec;

    wire ena_sp = (sp_cnt != 0) && REG.DISP && !REG.SPD && spr_v_ena;
    wire ena_bp = (bp_cnt != 0) && REG.DISP && !STATUS.VR;
    wire ena_pa = (pa_cnt != 0) && REG.DISP && !STATUS.VR;
    wire ena_pb = (pb_cnt != 0) && REG.DISP && !STATUS.VR;

    assign MEM.PREP = MEM_REQ;

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) MEM.EXEC <= 0;
        else         MEM.EXEC <= MEM_REQ;
    end

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                    MEM.STATE <= RAM_XX;    // なにもしない
        else if(REG.DSPM == T9990_REG::DSPM_STANDBY) 
                                        MEM.STATE <= RAM_XX;    // なにもしない
        else if(tbl_init)               MEM.STATE <= RAM_RF;    // リフレッシュ固定
        else if(tbl_send) begin
            case (curr_tbl)
                default:                MEM.STATE <= RAM_VC;    // 未定義
                RAM_VC:                 MEM.STATE <= RAM_VC;    // VDP/CPU
                RAM_RF:                 MEM.STATE <= RAM_RF;    // リフレッシュ
                RAM_BP: if(ena_bp)      MEM.STATE <= RAM_BP;    // BITMAP データが必要なので BITMAP データを取得する
                        else if(ena_sp) MEM.STATE <= RAM_SP;    // BITMAP データがいらないので CURSOR データを取得する
                        else            MEM.STATE <= RAM_VC;    // BITMAP も CURSOR データもいらないので VDP/CPU に帯域をまわす
                RAM_SP: if(ena_sp)      MEM.STATE <= RAM_SP;    // SPRITE データが必要なので SPRITE データを取得する
                        else            MEM.STATE <= RAM_VC;    // SPRITE データがいらないので VDP/CPU に帯域をまわす
                RAM_PA: if(ena_pa)      MEM.STATE <= RAM_PA;    // PATTERN A データが必要なので PATTERN A データを取得
                        else if(ena_sp) MEM.STATE <= RAM_SP;    // PATTERN A がいらないので SPRITE データを取得
                        else            MEM.STATE <= RAM_VC;    // PATTERN A も SPRITE データもいらないので VDP/CPU に帯域をまわす
                RAM_PB: if(ena_pb)      MEM.STATE <= RAM_PB;    // PATTERN B データが必要なので PATTERN B データを取得
                        else if(ena_sp) MEM.STATE <= RAM_SP;    // PATTERN B データがいらないので SPRITE データを取得
                        else            MEM.STATE <= RAM_VC;    // PATTERN B も SPRITE もいらないので VDP/CPU に帯域をまわす
            endcase
        end
        //else                          MEM.STATE <= MEM.STATE;
    end

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                 cnt_dec <= 0;
        else if(REG.DSPM == T9990_REG::DSPM_STANDBY) cnt_dec <= 0;
        else if(tbl_init)                            cnt_dec <= 0;
        else if(tbl_send)                            cnt_dec <= 1;
        else                                         cnt_dec <= 0;
    end

    // データ残数更新
    logic [7:0] sp_cnt; // スプライトデータ残数
    logic [7:0] pa_cnt; // P1Aデータ残数
    logic [7:0] pb_cnt; // P2Bデータ残数
    logic [8:0] bp_cnt; // BPデータ残数

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            sp_cnt <= 0;
            bp_cnt <= 0;
            pa_cnt <= 0;
            pb_cnt <= 0;
        end
        else if(cnt_init) begin

            // SPRITE / CURSOR
            if(REG.DSPM == T9990_REG::DSPM_P2 || REG.DSPM == T9990_REG::DSPM_P1) begin
                sp_cnt <= 8'd157;       // 125 + 16 * 2
            end
            else begin
                sp_cnt <= 3'd6;         // (2 + 1) * 2
            end

            // PA/PB/BP
            if(REG.DSPM == T9990_REG::DSPM_P1) begin
                pa_cnt <= REG.MCS == T9990_REG::MCS_21MHZ ? 8'd51 : 8'd75;     // (256 / 16 +1) * 3 : (384 / 16 +1) * 3
                pb_cnt <= REG.MCS == T9990_REG::MCS_21MHZ ? 8'd51 : 8'd75;     // (256 / 16 +1) * 3 : (384 / 16 +1) * 3
                bp_cnt <= 0;

            end
            else if(REG.DSPM == T9990_REG::DSPM_P2) begin
                pa_cnt <= REG.MCS == T9990_REG::MCS_21MHZ ? 8'd102 : 8'd150;    // (512 / 32 + 1) * 6 : (768 / 32 + 1) * 6
                pb_cnt <= 0;
                bp_cnt <= 0;
            end
            else begin
                pa_cnt <= 0;
                pb_cnt <= 0;
                case ({REG.MCS, REG.DCKM, REG.CLRM})
                    default:                                                              bp_cnt <= 0;       // 未定義
                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV4, T9990_REG::CLRM_2BPP }: bp_cnt <= 9'd17;   // 256dot 2bpp    (256+16)* 2/32
                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV4, T9990_REG::CLRM_4BPP }: bp_cnt <= 9'd34;   // 256dot 4bpp    (256+16)* 4/32
                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV4, T9990_REG::CLRM_8BPP }: bp_cnt <= 9'd68;   // 256dot 8bpp    (256+16)* 8/32
                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV4, T9990_REG::CLRM_16BPP}: bp_cnt <= 9'd136;  // 256dot 16bpp   (256+16)*16/32

                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_2BPP }: bp_cnt <= 9'd34;   // 512dot 2bpp    (512+32)* 2/32
                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_4BPP }: bp_cnt <= 9'd68;   // 512dot 4bpp    (512+32)* 4/32
                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_8BPP }: bp_cnt <= 9'd136;  // 512dot 8bpp    (512+32)* 8/32
                    { T9990_REG::MCS_21MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_16BPP}: bp_cnt <= 9'd272;  // 512dot 16bpp   (512+32)*16/32

                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_2BPP }: bp_cnt <= 9'd25;   // 384dot 2bpp    (384+16)* 2/32
                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_4BPP }: bp_cnt <= 9'd50;   // 384dot 4bpp    (384+16)* 4/32
                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_8BPP }: bp_cnt <= 9'd100;  // 384dot 8bpp    (384+16)* 8/32
                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV2, T9990_REG::CLRM_16BPP}: bp_cnt <= 9'd200;  // 384dot 16bpp   (384+16)*16/32

                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV1, T9990_REG::CLRM_2BPP }: bp_cnt <= 9'd50;   // 768dot 2bpp    (768+32)* 2/32
                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV1, T9990_REG::CLRM_4BPP }: bp_cnt <= 9'd100;  // 768dot 4bpp    (768+32)* 4/32
                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV1, T9990_REG::CLRM_8BPP }: bp_cnt <= 9'd200;  // 768dot 8bpp    (768+32)* 8/32
                    { T9990_REG::MCS_14MHZ, T9990_REG::DCKM_DIV1, T9990_REG::CLRM_16BPP}: bp_cnt <= 9'd400;  // 768dot 16bpp   (768+32)*16/32
                endcase
            end
        end
        else if(cnt_dec) begin
            if(MEM.STATE == RAM_SP) begin
                if(sp_cnt) sp_cnt <= sp_cnt - 1'd1;
            end
            else if(MEM.STATE == RAM_BP) begin
                if(bp_cnt) bp_cnt <= bp_cnt - 1'd1;
            end
            else if(MEM.STATE == RAM_PA) begin
                if(pa_cnt) pa_cnt <= pa_cnt - 1'd1;
            end
            else if(MEM.STATE == RAM_PB) begin
                if(pb_cnt) pb_cnt <= pb_cnt - 1'd1;
            end
        end
    end

    // テーブル更新
    logic [3:0] tbl_addr;
    logic [$bits(RAM_XX)-1:0] curr_tbl;
    T9990_TIMING_TABLE u_tbl (
        .RESET_n,
        .CLK,
        .REG,
        .ADDR(tbl_init ? 4'd0 : tbl_addr),
        .OUT(curr_tbl)
    );

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n)                                         tbl_addr <= 0;
        else if(tbl_init)                                    tbl_addr <= 0;
        else if(tbl_send && REG.MCS == T9990_REG::MCS_21MHZ) tbl_addr <= tbl_addr + 1'd1;                                // 16サイクル
        else if(tbl_send && REG.MCS == T9990_REG::MCS_14MHZ) tbl_addr <= (tbl_addr == 4'd11) ? 4'd0 : (tbl_addr + 1'd1); // 12サイクル
    end

endmodule 

module T9990_TIMING_TABLE (
    input wire                      RESET_n,
    input wire                      CLK,
    T9990_REGISTER_IF.VDP           REG,
    input wire [3:0]                ADDR,
    output reg [$bits(RAM_XX)-1:0]  OUT
);
    wire [3:0] addr = ADDR;

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            OUT <= RAM_XX;
        end

        // P1 256dot
        else if(REG.DSPM == T9990_REG::DSPM_P1 && REG.MCS == T9990_REG::MCS_21MHZ) begin
            case (addr)
                4'd 0:  OUT <= RAM_PA;
                4'd 1:  OUT <= RAM_PB;
                4'd 2:  OUT <= RAM_PA;
                4'd 3:  OUT <= RAM_PB;
                4'd 4:  OUT <= RAM_PA;
                4'd 5:  OUT <= RAM_PB;
                4'd 6:  OUT <= RAM_SP;
                4'd 7:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_SP;
                4'd 9:  OUT <= RAM_SP;
                4'd10:  OUT <= RAM_SP;
                4'd11:  OUT <= RAM_SP;
                4'd12:  OUT <= RAM_SP;
                4'd13:  OUT <= RAM_SP;
                4'd14:  OUT <= RAM_SP;
                4'd15:  OUT <= RAM_VC;
            endcase
        end

        // P1 384dot
        else if(REG.DSPM == T9990_REG::DSPM_P1 && REG.MCS == T9990_REG::MCS_14MHZ) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_SP;
                4'd 9:  OUT <= RAM_SP;
                4'd 8:  OUT <= RAM_SP;
                4'd 7:  OUT <= RAM_SP;
                4'd 6:  OUT <= RAM_SP;
                4'd 5:  OUT <= RAM_PB;
                4'd 4:  OUT <= RAM_PA;
                4'd 3:  OUT <= RAM_PB;
                4'd 2:  OUT <= RAM_PA;
                4'd 1:  OUT <= RAM_PB;
                4'd 0:  OUT <= RAM_PA;
            endcase
        end

        // P2 512dot
        else if(REG.DSPM == T9990_REG::DSPM_P2 && REG.MCS == T9990_REG::MCS_21MHZ) begin
            case (addr)
                4'd 0:  OUT <= RAM_PA;
                4'd 1:  OUT <= RAM_PA;
                4'd 2:  OUT <= RAM_PA;
                4'd 3:  OUT <= RAM_PA;
                4'd 4:  OUT <= RAM_PA;
                4'd 5:  OUT <= RAM_PA;
                4'd 6:  OUT <= RAM_SP;
                4'd 7:  OUT <= RAM_VC;

                4'd 8:  OUT <= RAM_SP;
                4'd 9:  OUT <= RAM_SP;
                4'd10:  OUT <= RAM_SP;
                4'd11:  OUT <= RAM_SP;
                4'd12:  OUT <= RAM_SP;
                4'd13:  OUT <= RAM_SP;
                4'd14:  OUT <= RAM_SP;
                4'd15:  OUT <= RAM_VC;
            endcase
        end

        // P2 768dot
        else if(REG.DSPM == T9990_REG::DSPM_P2 && REG.MCS == T9990_REG::MCS_14MHZ) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_SP;
                4'd 9:  OUT <= RAM_SP;
                4'd 8:  OUT <= RAM_SP;
                4'd 7:  OUT <= RAM_SP;
                4'd 6:  OUT <= RAM_SP;
                4'd 5:  OUT <= RAM_PA;
                4'd 4:  OUT <= RAM_PA;
                4'd 3:  OUT <= RAM_PA;
                4'd 2:  OUT <= RAM_PA;
                4'd 1:  OUT <= RAM_PA;
                4'd 0:  OUT <= RAM_PA;
            endcase
        end

        // 2bpp 256dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV4 && REG.CLRM == T9990_REG::CLRM_2BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_VC;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 4bpp 256dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV4 && REG.CLRM == T9990_REG::CLRM_4BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_VC;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 8bpp 256dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV4 && REG.CLRM == T9990_REG::CLRM_8BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_BP;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_VC;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 16bpp 256dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV4 && REG.CLRM == T9990_REG::CLRM_16BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_BP;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_BP;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_BP;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_BP;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 2bpp 512dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_2BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_VC;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 4bpp 512dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_4BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_BP;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_VC;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 8bpp 512dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_8BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_BP;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_BP;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_BP;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_BP;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 16bpp 512dot
        else if(REG.MCS == T9990_REG::MCS_21MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_16BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_BP;
                4'd14:  OUT <= RAM_BP;
                4'd13:  OUT <= RAM_BP;
                4'd12:  OUT <= RAM_BP;
                4'd11:  OUT <= RAM_BP;
                4'd10:  OUT <= RAM_BP;
                4'd 9:  OUT <= RAM_BP;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_BP;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_BP;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_BP;
                4'd 2:  OUT <= RAM_BP;
                4'd 1:  OUT <= RAM_BP;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 2bpp 384dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_2BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_VC;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 4bpp 384dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_4BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 8bpp 384dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_8BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_BP;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_BP;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 16bpp 384dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV2 && REG.CLRM == T9990_REG::CLRM_16BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_BP;
                4'd 9:  OUT <= RAM_BP;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_BP;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_BP;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_BP;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 2bpp 768dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV1 && REG.CLRM == T9990_REG::CLRM_2BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_VC;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_VC;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 4bpp 768dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV1 && REG.CLRM == T9990_REG::CLRM_4BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_VC;
                4'd 9:  OUT <= RAM_BP;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_VC;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_VC;
                4'd 3:  OUT <= RAM_BP;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_VC;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 8bpp 768dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV1 && REG.CLRM == T9990_REG::CLRM_8BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_VC;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_BP;
                4'd 9:  OUT <= RAM_BP;
                4'd 8:  OUT <= RAM_VC;
                4'd 7:  OUT <= RAM_BP;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_VC;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_BP;
                4'd 2:  OUT <= RAM_VC;
                4'd 1:  OUT <= RAM_BP;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // 16bpp 768dot
        else if(REG.MCS == T9990_REG::MCS_14MHZ && REG.DCKM == T9990_REG::DCKM_DIV1 && REG.CLRM == T9990_REG::CLRM_16BPP) begin
            case (addr)
                4'd15:  OUT <= RAM_BP;
                4'd14:  OUT <= RAM_VC;
                4'd13:  OUT <= RAM_VC;
                4'd12:  OUT <= RAM_VC;
                4'd11:  OUT <= RAM_VC;
                4'd10:  OUT <= RAM_BP;
                4'd 9:  OUT <= RAM_BP;
                4'd 8:  OUT <= RAM_BP;
                4'd 7:  OUT <= RAM_BP;
                4'd 6:  OUT <= RAM_BP;
                4'd 5:  OUT <= RAM_BP;
                4'd 4:  OUT <= RAM_BP;
                4'd 3:  OUT <= RAM_BP;
                4'd 2:  OUT <= RAM_BP;
                4'd 1:  OUT <= RAM_BP;
                4'd 0:  OUT <= RAM_BP;
            endcase
        end

        // default
        else begin
            OUT <= 0;
        end
    end
endmodule

`default_nettype wire
