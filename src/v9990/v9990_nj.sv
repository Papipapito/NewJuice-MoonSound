//
// v9990_nj.sv - the V9990 (tiny9990) on New Juice's bus, with its video chain.
//
// BSD 3-Clause License
//
// The bus glue and the video capture come from cartridge_v9990.sv of tnCart
// (Copyright (c) 2024, Shinobu Hashimoto) with the three-sample re-arm of
// V9990TANG (Copyright (c) 2026, Papipapito). Adapted to New Juice's bus and
// SDRAM by the New Juice V9990 fork (2026, Albert "Papipapito", with Claude).
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

module v9990_nj #(
    parameter [7:0] IO_BASE_ADDR = 8'h60,
    parameter       UPSCAN_BLEND = 1
) (
    input  wire         clk,            // main_clk, 108 MHz
    input  wire         reset_n,        // module reset (startup sequence done)
    input  wire         slot_reset_n,   // MSX /RESET, as seen in clk

    // New Juice's debounced bus (clk)
    input  wire         iorq_n,
    input  wire         rd_n,
    input  wire         wr_n,
    input  wire [7:0]   addr,
    input  wire [7:0]   din,
    output wire [7:0]   rd_data,
    output wire         rd_active,      // drive rd_data and turn the bus around
    output wire         wait_n,
    output wire         int_n,

    // clock enables and VRAM (nj_v9990_arb)
    input  wire         clk21m_en,
    input  wire         clk14m_en,
    input  wire         clk25m_en,
    input  wire         ram_req,
    output wire         ram_oe_n,
    output wire         ram_we_n,
    output wire         ram_rfsh_n,
    output wire [18:0]  ram_addr,
    output wire [31:0]  ram_din,
    output wire [2:0]   ram_din_size,
    input  wire [31:0]  ram_dout,
    input  wire         ram_ack_n,

    // video out
    input  wire         clk_pixel,      // 27 MHz
    input  wire         clk_pixel_x5,   // 135 MHz
    input  wire         video_reset_n,  // 0 = transmitter in reset (async)
    output wire         tmds_clk_p,
    output wire         tmds_clk_n,
    output wire [2:0]   tmds_data_p,
    output wire [2:0]   tmds_data_n
);
    /***************************************************************
     * Bus: one I/O cycle is shown to the core once (V9990TANG's re-arm)
     ***************************************************************/
    wire cs_n    = iorq_n || (addr[7:4] != IO_BASE_ADDR[7:4]);
    wire io_rd   = !cs_n && !rd_n;
    wire io_wr   = !cs_n && !wr_n;
    wire io_any  = io_rd || io_wr;
    wire rw_idle = rd_n && wr_n;

    wire core_reset_n = reset_n && slot_reset_n;

    logic served;           // this I/O cycle has been shown to the core
    logic served_rd;        // ... and it was a read
    logic [1:0] idle_cnt;   // clocks in a row with /RD and /WR idle (saturates at 3)
    logic CSR_n;
    logic CSW_n;
    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            served    <= 0;
            served_rd <= 0;
            idle_cnt  <= 0;
            CSR_n     <= 1;
            CSW_n     <= 1;
        end
        else begin
            if(io_any && !served) begin
                served    <= 1;
                served_rd <= io_rd && !io_wr;
                CSR_n     <= !(io_rd && !io_wr);
                CSW_n     <= !io_wr;
            end
            else if(!io_any) begin
                CSR_n     <= 1;
                CSW_n     <= 1;
            end

            if(!rw_idle)                idle_cnt <= 0;
            else if(idle_cnt != 2'd3)   idle_cnt <= idle_cnt + 2'd1;
            if(rw_idle && idle_cnt >= 2'd2) begin
                served    <= 0;
                served_rd <= 0;
            end
        end
    end

    logic [7:0] dout;
    logic       drive;
    logic [7:0] dout_q;
    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            drive  <= 0;
            dout_q <= 0;
        end
        else if(served && served_rd) begin
            drive  <= 1;
            dout_q <= dout;
        end
        else begin
            drive  <= 0;
            dout_q <= 0;
        end
    end
    // released with New Juice's own /RD, like its other ports
    assign rd_active = drive && !rd_n;
    assign rd_data   = dout_q;

    logic [3:0] MODE;
    logic [7:0] CD_IN;
    always_ff @(posedge clk) begin
        MODE  <= addr[3:0];
        CD_IN <= din;
    end

    /***************************************************************
     * VDP
     ***************************************************************/
    logic [4:0] r;
    logic [4:0] g;
    logic [4:0] b;
    logic hs;
    logic vs;
    logic dclk_en;
    logic [2:0] reso;
    logic pal;
    logic hscn;
    logic il;
    logic eo;
    logic int0_n;
    logic int1_n;
    assign int_n = int0_n && int1_n;

    // /WAIT with a fail-open limit, as in V9990TANG's bus: after 4096 clocks
    // (38 us) the Z80 is let go, until the core drops its request.
    logic        core_wait_n;
    logic [11:0] wait_cnt;
    logic        wait_to;
    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            wait_cnt <= 0;
            wait_to  <= 0;
        end
        else if(core_wait_n) begin
            wait_cnt <= 0;
            wait_to  <= 0;
        end
        else if(&wait_cnt) wait_to  <= 1;
        else               wait_cnt <= wait_cnt + 12'd1;
    end
    assign wait_n = core_wait_n || wait_to;

    T9990 #(
        .ENABLE_PAL         (1),
        .ENABLE_CURSOR_EOR  (1),
        .ENABLE_R16         (1)
    ) u_vdp (
        .RESET_n(core_reset_n),
        .CLK(clk),
        .CLK_21M_EN(clk21m_en),
        .CLK_14M_EN(clk14m_en),
        .CLK_25M_EN(clk25m_en),

        .CSR_n,
        .CSW_n,
        .MODE,
        .CD_IN,
        .CD_OUT(dout),
        .WAIT_n(core_wait_n),
        .INT0_n(int0_n),
        .INT1_n(int1_n),
        .DREQ_n(),
        .VMREQ_n(),

        .RAM_REQ(ram_req),
        .RAM_OE_n(ram_oe_n),
        .RAM_WE_n(ram_we_n),
        .RAM_RFSH_n(ram_rfsh_n),
        .RAM_ADDR(ram_addr),
        .RAM_DIN(ram_din),
        .RAM_DIN_SIZE(ram_din_size),
        .RAM_DOUT(ram_dout),
        .RAM_ACK_n(ram_ack_n),

        .HS(hs),
        .VS(vs),
        .R(r),
        .G(g),
        .B(b),
        .Ys(),
        .DCLK_EN(dclk_en),
        .RESO(reso),
        .HSCN(hscn),
        .IL(il),
        .EO(eo),
        .PAL(pal)
    );

    /***************************************************************
     * Video capture. tnCart clocked this with a clock made by logic (DCLK =
     * dclk_en delayed one clock OR delayed two) and raced R/G/B against it.
     * Here the dot domain is clk with the enable dot_ce, one clock after the
     * edge DCLK would have had: the registers take the same values, the
     * whole domain is one 108 MHz clock later.
     ***************************************************************/
    logic [1:0] dclk_en_ff;
    always_ff @(posedge clk) dclk_en_ff <= {dclk_en_ff[0], dclk_en};
    wire dot_ce = dclk_en_ff[0] && !dclk_en_ff[1];

    VIDEO_IF Video();
    VIDEO_IF VideoTmds();

    assign Video.DCLK      = 1'b0;      // not used: see dot_ce
    assign Video.HSCAN     = hscn;
    assign Video.INTERLACE = il;
    assign Video.FIELD     = eo;

    logic [7:0] video_r;
    logic [7:0] video_g;
    logic [7:0] video_b;
    logic       video_hs_n;
    logic       video_vs_n;
    logic       video_pal;
    VIDEO::RESOLUTION_t video_reso;
    always_ff @(posedge clk) if(dot_ce) begin
        video_r    <= {r,r[4:2]};
        video_g    <= {g,g[4:2]};
        video_b    <= {b,b[4:2]};
        video_hs_n <= !hs;
        video_vs_n <= !vs;
        video_pal  <= pal;
        video_reso <= (reso == T9990_RESO::B1) ? VIDEO::RESOLUTION_B1 :
                      (reso == T9990_RESO::B2) ? VIDEO::RESOLUTION_B2 :
                      (reso == T9990_RESO::B3) ? VIDEO::RESOLUTION_B3 :
                      (reso == T9990_RESO::B4) ? VIDEO::RESOLUTION_B4 :
                      (reso == T9990_RESO::B5) ? VIDEO::RESOLUTION_B5 :
                      (reso == T9990_RESO::B6) ? VIDEO::RESOLUTION_B6 : VIDEO::RESOLUTION_B1;
    end
    assign Video.R = video_r;
    assign Video.G = video_g;
    assign Video.B = video_b;
    assign Video.HS_n = video_hs_n;
    assign Video.VS_n = video_vs_n;
    assign Video.PAL = video_pal;
    assign Video.RESOLUTION = video_reso;

    VIDEO_UPSCAN #(
        .BLEND          (UPSCAN_BLEND)
    ) u_upscan (
        .RESET_n        (video_reset_n),
        .DCLK           (clk_pixel),
        .IN_CLK         (clk),
        .IN_CE          (dot_ce),
        .IN             (Video),
        .OUT            (VideoTmds)
    );

    BOARD_REV1_TMDS_OUT u_tmds (
        .RESET_n        (video_reset_n),
        .IN             (VideoTmds),
        .TMDS_READY     (video_reset_n),
        .CLK_S          (clk_pixel_x5),
        .CLK_P          (clk_pixel),
        .TMDS_CLKP      (tmds_clk_p),
        .TMDS_CLKN      (tmds_clk_n),
        .TMDS_DATAP     (tmds_data_p),
        .TMDS_DATAN     (tmds_data_n)
    );

endmodule

`default_nettype wire
