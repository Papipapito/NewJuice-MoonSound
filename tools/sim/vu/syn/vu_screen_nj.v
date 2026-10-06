// vu_screen with the texts of src/top.v, as a top of its own for a
// synthesis-only Gowin run (run_syn.sh); its netlist is simulated by
// run_vu.sh (GL=...) against the same model as the RTL.
module vu_screen_nj (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [9:0]  cx,
    input  wire [9:0]  cy,
    output wire [23:0] rgb,
    input  wire [29:0] level,
    input  wire [29:0] peak,
    input  wire [1:0]  st_rom,
    input  wire        st_msx
);
    vu_screen #(
        .TITLE_N(`VU_TITLE_N), .TITLE(`VU_TITLE),
        .SUB_N(`VU_SUB_N),     .SUB(`VU_SUB),
        .FOOT_N(`VU_FOOT_N),   .FOOT(`VU_FOOT)
    ) u (
        .clk(clk), .rst_n(rst_n), .cx(cx), .cy(cy), .rgb(rgb),
        .level(level), .peak(peak), .st_rom(st_rom), .st_msx(st_msx)
    );
endmodule
