//
// t9990_palette.sv
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
 * パレットモジュール
 ***************************************************************/
module T9990_PALETTE #(
    parameter               ENABLE_CURSOR_EOR = 1   // V9990TANG: cursor con la semantica de openMSX (EOR y color)
) (
    input wire              RESET_n,
    input wire              CLK,
    input wire              DCLK_EN,

    T9990_PALETTE_IF.PAL    PAL,

    input wire              START,
    input wire [5:0]        PA,
    input wire [0:0]        PRI,
    output reg [15:0]       OUT,

    input wire              DIRECT,     // V9990TANG: bitmap de color directo (BD8/BD16/YJK/YUV/YAE): ver abajo
    input wire              CUR_IN,     // V9990TANG: el punto es del cursor (opaco), alineado con PA/PRI; solo con DIRECT
    input wire              EOR_IN,     // V9990TANG: EOR del cursor, alineado con PA/PRI
    output reg              EOR_OUT     // V9990TANG: EOR alineado con el color de OUT
);
    reg [5:0] p_addr;
    reg [15:0] p_data;

    T9990_PALETTE_REG u_reg (
        .RESET_n,
        .CLK,

        .W_STROBE(PAL.W_STROBE),
        .W_ADDR(PAL.W_ADDR),
        .W_PTR(PAL.W_PTR),
        .W_DATA(PAL.W_DATA),
        .W_ACK(PAL.W_ACK),

        .R_STROBE(PAL.R_STROBE),
        .R_ADDR(PAL.R_ADDR),
        .R_PTR(PAL.R_PTR),
        .R_DATA(PAL.R_DATA),
        .R_ACK(PAL.R_ACK),

        .P_EN(DCLK_EN),
        .P_ADDR(p_addr),
        .P_DATA(p_data)
    );

    // 遅延バッファ
    // V9990TANG: cada entrada lleva ademas {EOR, CUR} del punto (ceros con ENABLE_CURSOR_EOR = 0)
    logic [2+$bits(PRI)+$bits(PA)-1:0] buffer[0:4-1];
    logic [1:0] w_index;
    logic [1:0] pa_index;
    logic [1:0] pri_index;

    /***************************************************************
     * V9990TANG: color del cursor alineado con su transparencia
     *
     * El color sale con 2 puntos de retardo (buffer 1 + p_addr -> P_DATA, que
     * la DPB da en el ciclo siguiente, + OUT) y la transparencia (OUT[15]) con
     * 3: en OUT van la transparencia del punto k y el color del punto k + 1.
     * Con una sola capa (P1/P2, BPx) eso solo adelanta toda la imagen un punto,
     * pero cuando OUT[15] elige entre la paleta y el bitmap directo (BD8/BD16/
     * YJK/YUV: el cursor) el ultimo punto opaco de cada tramo del cursor salia
     * con el color del punto siguiente (el fondo, BDC) en vez del del cursor.
     * En los puntos del cursor (CUR, por el mismo anillo que PRI) se toma el
     * color del punto anterior, el suyo; el resto sale como en el hito 1.
     * CUR solo se marca en los modos de color directo (DIRECT): en BP2/BP4/BP6
     * el cursor y el bitmap van juntos en la misma capa, los dos con el color
     * k + 1, y alinear solo los puntos del cursor duplicaria su primer punto y
     * se comeria el punto del bitmap que le sigue.
     *
     * EOR_OUT va con el color que sale en OUT: el del punto k (la entrada del
     * anillo de la transparencia) con DIRECT, donde el selector usa esa
     * transparencia y el color del cursor ya va alineado, y el del punto k + 1
     * (la entrada siguiente) en los modos de paleta, donde la imagen es el color.
     ***************************************************************/
    wire  [2+$bits(PRI)+$bits(PA)-1:0] pri_entry = buffer[pri_index];
    // V9990TANG 0.3beta: con la transparencia ya alineada con el color (pri_index) no hace falta tomar el
    // color del punto anterior en los puntos del cursor; DIRECT y CUR_IN quedan sin uso.
    wire  [15:0] p_color = p_data;

    // color decode に合わせて遅延をいれる
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n || START) begin
            w_index <= 0;
            pa_index <= 4-1;      // 1dotclk の遅れ
            // V9990TANG 0.3beta: 2 puntos, los mismos que el color (p_addr un punto despues de la entrada y OUT
            // otro mas). Con 4-3 la transparencia (OUT[15]) salia un punto despues que su color: en los modos de
            // color directo el hueco por el que se ve el bitmap iba un punto tarde (el MSXimus Z lo compensa
            // abriendo antes la ventana del PRI, MUX_HDE_E) y el cursor salia un punto a la derecha.
            pri_index <= 4-2;
        end
        else if(DCLK_EN) begin
            OUT[14:0] <= p_color[14:0];
            OUT[15] <= (pri_entry[$bits(PA)]) ? 1 : p_color[15];
            pri_index <= pri_index + 1'd1;

            p_addr <= buffer[pa_index][$bits(PA)-1:0];
            pa_index <= pa_index + 1'd1;

            buffer[w_index] <= { (ENABLE_CURSOR_EOR != 0) && EOR_IN, (ENABLE_CURSOR_EOR != 0) && CUR_IN, PRI, PA };
            w_index <= w_index + 1'd1;
        end
    end

    // V9990TANG: EOR del cursor, leido del anillo: alineado con el color de OUT
    always_ff @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            EOR_OUT <= 0;
        end
        else if(DCLK_EN) begin
            EOR_OUT <= (ENABLE_CURSOR_EOR != 0) && pri_entry[$bits(PRI)+$bits(PA)+1];
        end
    end
endmodule

/***************************************************************
 * パレットレジスタ
 ***************************************************************/
`define PALETTE_USE_DPB
`ifdef PALETTE_USE_DPB
module T9990_PALETTE_REG (
    input wire          RESET_n,
    input wire          CLK,

    // P#1 WRITE
    input wire          W_STROBE,
    input wire [5:0]    W_ADDR,
    input wire [1:0]    W_PTR,
    input wire [5:0]    W_DATA,
    output reg          W_ACK,

    // P#1 READ
    input wire          R_STROBE,
    input wire [5:0]    R_ADDR,
    input wire [1:0]    R_PTR,
    output wire [5:0]   R_DATA,
    output reg          R_ACK,

    // PIXEL
    input wire          P_EN,
    input wire [5:0]    P_ADDR,
    output wire [15:0]  P_DATA
);
    /***************************************************************
     * 表示パレット
     ***************************************************************/
    reg [5:0] p_data_r;
    reg [4:0] p_data_g;
    reg [4:0] p_data_b;
    assign P_DATA = { p_data_r[5], p_data_g, p_data_r[4:0], p_data_b};

    /***************************************************************
     * リード制御
     ***************************************************************/
    logic [1:0] ptr;
    reg [5:0] r_data_r;
    reg [4:0] r_data_g;
    reg [4:0] r_data_b;
    assign R_DATA = (ptr == T9990_REG::PLTP_R) ? r_data_r :
                    (ptr == T9990_REG::PLTP_G) ? {1'b0, r_data_g} : {1'b0,r_data_b};    // MSXimus Z 18/10/2026: era PLTP_R dos veces (leer G por P#1 devolvia B)

    always_ff @(posedge CLK) begin
        if(!RESET_n) begin
            ptr <= 0;
        end
        else if(!P_EN && !W_STROBE && R_STROBE) begin
            ptr <= R_PTR;
        end
    end

    /***************************************************************
     * ライト制御
     ***************************************************************/
    // ライトイネーブル
    logic dpb_r_wreb;
    logic dpb_g_wreb;
    logic dpb_b_wreb;

    // R/W アドレス
    wire [5:0] adb = (dpb_r_wreb | dpb_g_wreb | dpb_b_wreb) ? W_ADDR : R_ADDR;

    always_ff @(posedge CLK) begin
        if(!RESET_n) begin
            dpb_r_wreb <= 0;
            dpb_g_wreb <= 0;
            dpb_b_wreb <= 0;
        end

        // P#1 WRITE
        else if(!P_EN && W_STROBE) begin
            dpb_r_wreb <= W_PTR == T9990_REG::PLTP_R;
            dpb_g_wreb <= W_PTR == T9990_REG::PLTP_G;
            dpb_b_wreb <= W_PTR == T9990_REG::PLTP_B;
        end

        else begin
            dpb_r_wreb <= 0;
            dpb_g_wreb <= 0;
            dpb_b_wreb <= 0;
        end
    end

    /***************************************************************
     * ACK
     ***************************************************************/
    always_ff @(posedge CLK) begin
        if(!RESET_n) begin
            W_ACK <= 0;
            R_ACK <= 0;
        end

        // PIXEL を優先
        if(P_EN) begin
            W_ACK <= 0;
            R_ACK <= 0;
        end

        // P#1 WRITE
        else if(W_STROBE) begin
            W_ACK <= 1;
            R_ACK <= 0;
        end

        // P#1 READ
        else if(R_STROBE) begin
            W_ACK <= 0;
            R_ACK <= 1;
        end

        else begin
            W_ACK <= 0;
            R_ACK <= 0;
        end
    end

    /***************************************************************
     * 赤メモリ
     ***************************************************************/
    wire [9:0] dpb_r_douta_w;
    wire [9:0] dpb_r_doutb_w;

    DPB dpb_r (
        .DOA({dpb_r_douta_w[9:0],p_data_r[5:0]}),
        .DOB({dpb_r_doutb_w[9:0],r_data_r[5:0]}),
        .CLKA(CLK),
        .OCEA(1'b1),
        .CEA(1'b1),
        .RESETA(!RESET_n),
        .WREA(1'b0),
        .CLKB(CLK),
        .OCEB(1'b1),
        .CEB(1'b1),
        .RESETB(!RESET_n),
        .WREB(dpb_r_wreb),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({5'b00000,P_ADDR,3'b000}),
        .DIA({10'b0000000000,6'b000000}),
        .ADB({5'b00000,adb[5:0],3'b000}),
        .DIB({10'b0000000000,W_DATA[5:0]})
    );

    defparam dpb_r.READ_MODE0 = 1'b0;
    defparam dpb_r.READ_MODE1 = 1'b0;
    defparam dpb_r.WRITE_MODE0 = 2'b00;
    defparam dpb_r.WRITE_MODE1 = 2'b00;
    defparam dpb_r.BIT_WIDTH_0 = 8;
    defparam dpb_r.BIT_WIDTH_1 = 8;
    defparam dpb_r.BLK_SEL_0 = 3'b000;
    defparam dpb_r.BLK_SEL_1 = 3'b000;
    defparam dpb_r.RESET_MODE = "SYNC";

    /***************************************************************
     * 緑メモリ
     ***************************************************************/
    wire [10:0] dpb_g_douta_w;
    wire [10:0] dpb_g_doutb_w;

    DPB dpb_g (
        .DOA({dpb_g_douta_w[10:0],p_data_g[4:0]}),
        .DOB({dpb_g_doutb_w[10:0],r_data_g[4:0]}),
        .CLKA(CLK),
        .OCEA(1'b1),
        .CEA(1'b1),
        .RESETA(!RESET_n),
        .WREA(1'b0),
        .CLKB(CLK),
        .OCEB(1'b1),
        .CEB(1'b1),
        .RESETB(!RESET_n),
        .WREB(dpb_g_wreb),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({5'b00000,P_ADDR,3'b000}),
        .DIA({11'b00000000000,5'b00000}),
        .ADB({5'b00000,adb[5:0],3'b000}),
        .DIB({11'b00000000000,W_DATA[4:0]})
    );

    defparam dpb_g.READ_MODE0 = 1'b0;
    defparam dpb_g.READ_MODE1 = 1'b0;
    defparam dpb_g.WRITE_MODE0 = 2'b00;
    defparam dpb_g.WRITE_MODE1 = 2'b00;
    defparam dpb_g.BIT_WIDTH_0 = 8;
    defparam dpb_g.BIT_WIDTH_1 = 8;
    defparam dpb_g.BLK_SEL_0 = 3'b000;
    defparam dpb_g.BLK_SEL_1 = 3'b000;
    defparam dpb_g.RESET_MODE = "SYNC";

    /***************************************************************
     * 青メモリ
     ***************************************************************/
    wire [10:0] dpb_b_douta_w;
    wire [10:0] dpb_b_doutb_w;

    DPB dpb_b (
        .DOA({dpb_b_douta_w[10:0],p_data_b[4:0]}),
        .DOB({dpb_b_doutb_w[10:0],r_data_b[4:0]}),
        .CLKA(CLK),
        .OCEA(1'b1),
        .CEA(1'b1),
        .RESETA(!RESET_n),
        .WREA(1'b0),
        .CLKB(CLK),
        .OCEB(1'b1),
        .CEB(1'b1),
        .RESETB(!RESET_n),
        .WREB(dpb_b_wreb),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({5'b00000,P_ADDR,3'b000}),
        .DIA({11'b00000000000,5'b00000}),
        .ADB({5'b00000,adb[5:0],3'b000}),
        .DIB({11'b00000000000,W_DATA[4:0]})
    );

    defparam dpb_b.READ_MODE0 = 1'b0;
    defparam dpb_b.READ_MODE1 = 1'b0;
    defparam dpb_b.WRITE_MODE0 = 2'b00;
    defparam dpb_b.WRITE_MODE1 = 2'b00;
    defparam dpb_b.BIT_WIDTH_0 = 8;
    defparam dpb_b.BIT_WIDTH_1 = 8;
    defparam dpb_b.BLK_SEL_0 = 3'b000;
    defparam dpb_b.BLK_SEL_1 = 3'b000;
    defparam dpb_b.RESET_MODE = "SYNC";

endmodule

`else

module T9990_PALETTE_REG (
    input wire          RESET_n,
    input wire          CLK,

    // P#1 WRITE
    input wire          W_STROBE,
    input wire [5:0]    W_ADDR,
    input wire [1:0]    W_PTR,
    input wire [5:0]    W_DATA,
    output reg          W_ACK,

    // P#1 READ
    input wire          R_STROBE,
    input wire [5:0]    R_ADDR,
    input wire [1:0]    R_PTR,
    output reg [5:0]    R_DATA,
    output reg          R_ACK,

    // PIXEL
    input wire          P_EN,
    input wire [5:0]    P_ADDR,
    output reg [15:0]   P_DATA
);
    reg [5:0] buff_r[0:63] /* synthesis syn_ramstyle="block_ram" */;
    reg [4:0] buff_g[0:63] /* synthesis syn_ramstyle="block_ram" */;
    reg [4:0] buff_b[0:63] /* synthesis syn_ramstyle="block_ram" */;

    reg [5:0] p_data_r;
    reg [4:0] p_data_g;
    reg [4:0] p_data_b;
    assign P_DATA = { p_data_r[5], p_data_g, p_data_r[4:0], p_data_b};

    always_ff @(posedge CLK) begin
        if(!RESET_n) begin
            p_data_r <= 0;
            p_data_g <= 0;
            p_data_b <= 0;

            R_DATA <= 0;
            W_ACK <= 0;
            R_ACK <= 0;
//`define DEBUG
`ifdef DEBUG
            buff_r[ 0] <= 6'b0_00000;
            buff_r[ 1] <= 6'b0_00000;
            buff_r[ 2] <= 6'b0_00111;
            buff_r[ 3] <= 6'b0_01110;
            buff_r[ 4] <= 6'b0_01011;
            buff_r[ 5] <= 6'b0_10000;
            buff_r[ 6] <= 6'b0_10111;
            buff_r[ 7] <= 6'b0_01100;
            buff_r[ 8] <= 6'b0_11011;
            buff_r[ 9] <= 6'b0_11111;
            buff_r[10] <= 6'b0_11001;
            buff_r[11] <= 6'b0_11011;
            buff_r[12] <= 6'b0_00111;
            buff_r[13] <= 6'b0_10110;
            buff_r[14] <= 6'b0_11001;
            buff_r[15] <= 6'b0_11111;

            buff_g[ 0] <= 5'b00000;
            buff_g[ 1] <= 5'b00000;
            buff_g[ 2] <= 5'b10111;
            buff_g[ 3] <= 5'b11010;
            buff_g[ 4] <= 5'b01010;
            buff_g[ 5] <= 5'b01110;
            buff_g[ 6] <= 5'b01011;
            buff_g[ 7] <= 5'b11011;
            buff_g[ 8] <= 5'b01100;
            buff_g[ 9] <= 5'b10001;
            buff_g[10] <= 5'b11000;
            buff_g[11] <= 5'b11010;
            buff_g[12] <= 5'b10100;
            buff_g[13] <= 5'b01100;
            buff_g[14] <= 5'b11001;
            buff_g[15] <= 5'b11111;

            buff_b[ 0] <= 5'b00000;
            buff_b[ 1] <= 5'b00000;
            buff_b[ 2] <= 5'b01001;
            buff_b[ 3] <= 5'b01111;
            buff_b[ 4] <= 5'b11100;
            buff_b[ 5] <= 5'b11110;
            buff_b[ 6] <= 5'b01010;
            buff_b[ 7] <= 5'b11101;
            buff_b[ 8] <= 5'b01011;
            buff_b[ 9] <= 5'b01111;
            buff_b[10] <= 5'b01011;
            buff_b[11] <= 5'b10000;
            buff_b[12] <= 5'b01000;
            buff_b[13] <= 5'b10110;
            buff_b[14] <= 5'b11001;
            buff_b[15] <= 5'b11111;
`endif
        end

        // PIXEL を優先
        if(P_EN) begin
            p_data_r <= buff_r[P_ADDR];
            p_data_g <= buff_g[P_ADDR];
            p_data_b <= buff_b[P_ADDR];
            W_ACK <= 0;
            R_ACK <= 0;
        end

        // P#1 WRITE
        else if(W_STROBE) begin
            case (W_PTR)
                T9990_REG::PLTP_R: buff_r[W_ADDR] <= W_DATA;
                T9990_REG::PLTP_G: buff_g[W_ADDR] <= W_DATA[4:0];
                T9990_REG::PLTP_B: buff_b[W_ADDR] <= W_DATA[4:0];
            endcase
            W_ACK <= 1;
            R_ACK <= 0;
        end

        // P#1 READ
        else if(R_STROBE) begin
            case (R_PTR)
                T9990_REG::PLTP_R: R_DATA <= buff_r[R_ADDR];
                T9990_REG::PLTP_G: R_DATA <= {1'b0,buff_g[R_ADDR]};
                T9990_REG::PLTP_B: R_DATA <= {1'b0,buff_b[R_ADDR]};
            endcase
            W_ACK <= 0;
            R_ACK <= 1;
        end

        else begin
            W_ACK <= 0;
            R_ACK <= 0;
        end
    end
endmodule
`endif

`default_nettype wire
