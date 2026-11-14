// ============================================================================
// dvi_tx_stub.v - stand-in for Gowin's encrypted DVI_TX_Top IP (src/v9990/
// dvi_tx/dvi_tx.v), which neither sv2v nor Icarus accept. Same ports (see
// BOARD_REV1_TMDS_OUT in src/v9990/board_rev1_tmds.sv), TMDS outputs at 0.
// The bench looks at the video where it enters this module (I_rgb_*, 27 MHz).
// Simulation only: run_board.sh puts it in the file list in place of dvi_tx.v.
// ============================================================================
module DVI_TX_Top (
    input  wire        I_rst_n,
    input  wire        I_serial_clk,
    input  wire        I_rgb_clk,
    input  wire        I_rgb_vs,
    input  wire        I_rgb_hs,
    input  wire        I_rgb_de,
    input  wire [7:0]  I_rgb_r,
    input  wire [7:0]  I_rgb_g,
    input  wire [7:0]  I_rgb_b,
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n
);
    assign O_tmds_clk_p  = 1'b0;
    assign O_tmds_clk_n  = 1'b0;
    assign O_tmds_data_p = 3'b000;
    assign O_tmds_data_n = 3'b000;
endmodule
