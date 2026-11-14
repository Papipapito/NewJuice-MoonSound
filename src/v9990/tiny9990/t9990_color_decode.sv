//
// t9990_color_decode.sv
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

`define CLRDEC_USE_DPB

/***************************************************************
 * 色空間を変換
 ***************************************************************/
module T9990_COLOR_DECODE (
    input wire              RESET_n,
    input wire              CLK,
    input wire              DCLK_EN,

    T9990_REGISTER_IF.VDP   REG,

    input wire [9:0]        HCNT,

    input wire [15:0]       IN,
    output reg [15:0]       OUT
);
    wire [1:0] INDEX = HCNT[1:0];

    /***************************************************************
     * データを保存
     ***************************************************************/
`ifdef CLRDEC_USE_DPB
    wire [15:0] delay;
    T9990_COLOR_DECODE_DELAY u_delay (
        .RESET_n,
        .CLK,
        .DCLK_EN,
        .ADDR(INDEX),
        .IN,
        .OUT(delay)
    );
`else
    logic [15:0] buff[0:3] /* synthesis syn_ramstyle="block_ram" */;
    wire [15:0] delay = buff[INDEX];

    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            buff[0] <= 0;
            buff[1] <= 0;
            buff[2] <= 0;
            buff[3] <= 0;
        end
        else if(DCLK_EN) begin
            buff[INDEX] <= IN;
        end
    end
`endif

    /***************************************************************
     * Retardo extra del color directo (MSXimus Z 28/10/2026): el flujo de color directo (BD8, BD16, YJK/YUV)
     * llega ANTES a la salida que el de paleta y su ventana visible en el selector es la de DA un punto mas
     * tarde (la paleta pasa ademas por la mascara de MUX_HDE). Medido con un bitmap de 512 px (pixel 0 y 511
     * de colores unicos, tb_v9990_chain +DOTS): ventana visible de 512 puntos = 28..539 (contando desde el
     * flanco del DE) en color directo y 27..538 en paleta; el flujo en bruto llegaba con el pixel 0 en el
     * punto 26 (BD8) o 24 (BD16 con doble densidad, B3): el pixel 511 caia 2 (BD8) o 4 (BD16) puntos antes
     * del ultimo visible y por la derecha asomaban los 2-4 primeros pixeles de la linea siguiente (Dream
     * Puzzle, B3 a 16 bpp). Se retrasa el flujo: +2 puntos (B1, BD8, YJK/YUV) o +4 (BD16 con doble densidad).
     ***************************************************************/
    // MSXimus Z 30/10/2026: con COLOR_DECODE_DELAY = 4 (t9990_timing) y el hueco del PRI alineado con la
    // paleta (aqui: la transparencia de T9990_PALETTE alineada con su color), al color directo le basta UN punto en todos los modos (BD8, BD16 con doble densidad o
    // sin ella, YJK/YUV).
    logic [14:0] bd_s0;
    always_ff @(posedge CLK) begin
        if(DCLK_EN) bd_s0 <= delay[14:0];
    end
    wire [14:0] bd8  = bd_s0;                   // +1 punto
    wire [14:0] bd16 = bd_s0;

    /***************************************************************
     * 出力
     ***************************************************************/
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            OUT <= 16'b1_00000_00000_00000;
        end

        //
        // YUV / YJK: el bitmap (T9990_BITMAP) ya entrega el color RGB decodificado (tnCart #31)
        //
        else if(REG.PLTM == T9990_REG::PLTM_YUV || REG.PLTM == T9990_REG::PLTM_YJK) begin
            if(DCLK_EN) OUT <= { 1'b0, bd8 };    // con el mismo retardo que BD8
        end

        //
        // BD16
        //
        else if(REG.CLRM == T9990_REG::CLRM_16BPP) begin
            // YS (bit 15) solo cuenta al superponer video externo; sin el, el pixel se ve igual
            // (openMSX rasterBD16 sin superimpose enmascara el bit). MSXimus Z 22/09/2026.
            if(DCLK_EN) OUT <= { 1'b0, bd16 };
        end

        //
        // BD8
        //
        else if(REG.CLRM == T9990_REG::CLRM_8BPP) begin
            if(DCLK_EN) OUT <= {
                                bd8[7:0] == 0 ? 1'b1 : 1'b0,
                                bd8[7:5], bd8[7:6],
                                bd8[4:2], bd8[4:3],
                                bd8[1:0], bd8[1:0], bd8[1] | bd8[0]
                            };
        end

        //
        // その他の画面モード
        //
        // V9990TANG: en los modos de paleta la salida vuelve al valor del reset (bit 15 = 1, "sin color
        // directo"). Antes se quedaba como estaba (OUT <= OUT) y T9990_SELECTOR la usa donde la paleta es
        // transparente (indice 0 de BP2/BP4, fondo de P1/P2): tras un BD8/BD16 (bit 15 a 0) esos puntos
        // salian con el ultimo color directo en vez del fondo, hasta el siguiente reset (revision del
        // area; prueba bdbp de fpga/tb/core). Desde el reset no cambia nada: la salida ya valia esto.
        else begin
            OUT <= 16'b1_00000_00000_00000;
        end
    end
endmodule

module T9990_COLOR_DECODE_DELAY (
    input wire              RESET_n,
    input wire              CLK,
    input wire              DCLK_EN,
    input wire [1:0]        ADDR,
    input wire [15:0]       IN,
    output wire [15:0]      OUT
);
    wire [1:0] ADDR_R = (ADDR + 2'd3) & 2'd3;
    wire [15:0] dummy;

    DPB dpb_inst_0 (
        .DOA(OUT),
        .DOB(dummy),
        .CLKA(CLK),
        .OCEA(1'b1),
        .CEA(DCLK_EN),
        .RESETA(!RESET_n),
        .WREA(1'b0),
        .CLKB(CLK),
        .OCEB(1'b1),
        .CEB(DCLK_EN),
        .RESETB(!RESET_n),
        .WREB(1'b1),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({8'b00000000,ADDR_R[1:0],4'b0011}),
        .DIA(16'd0),
        .ADB({8'b00000000,ADDR[1:0],4'b0011}),
        .DIB(IN)
    );

    defparam dpb_inst_0.READ_MODE0 = 1'b0;
    defparam dpb_inst_0.READ_MODE1 = 1'b0;
    defparam dpb_inst_0.WRITE_MODE0 = 2'b00;
    defparam dpb_inst_0.WRITE_MODE1 = 2'b00;
    defparam dpb_inst_0.BIT_WIDTH_0 = 16;
    defparam dpb_inst_0.BIT_WIDTH_1 = 16;
    defparam dpb_inst_0.BLK_SEL_0 = 3'b000;
    defparam dpb_inst_0.BLK_SEL_1 = 3'b000;
    defparam dpb_inst_0.RESET_MODE = "SYNC";

endmodule
`default_nettype wire
