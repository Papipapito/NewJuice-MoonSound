// ============================================================================
// tb_vu_rom_dump.v - writes what the three ROMs of vu_screen hold in
// simulation (texts of src/top.v, passed by run_vu.sh as for
// tb_vu_hdmi_nj.v): the table of text elements (it_rom), the 6-bit font codes
// of the strings (str_rom) and the font (u_font.rom). rom_check.py compares
// them with the INIT values Gowin synthesis put in the block RAMs of a build
// (impl/gwsynthesis/new-juice.vg), so a constant that the synthesis tool
// evaluated differently from the simulator would show up.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

`ifndef VU_TITLE
`define VU_TITLE "NEW JUICE"
`define VU_TITLE_N 9
`endif
`ifndef VU_SUB
`define VU_SUB "+ MOONSOUND OPL4"
`define VU_SUB_N 16
`endif
`ifndef VU_FOOT
`define VU_FOOT "NEW JUICE MOONSOUND"
`define VU_FOOT_N 19
`endif

module tb_vu_rom_dump;
    reg clk = 1'b0;
    wire [23:0] rgb;
    vu_screen #(
        .TITLE_N(`VU_TITLE_N), .TITLE(`VU_TITLE),
        .SUB_N(`VU_SUB_N),     .SUB(`VU_SUB),
        .FOOT_N(`VU_FOOT_N),   .FOOT(`VU_FOOT)
    ) u (
        .clk(clk), .rst_n(1'b0), .cx(10'd0), .cy(10'd0), .rgb(rgb),
        .level(30'd0), .peak(30'd0), .st_rom(2'd0), .st_msx(1'b0)
    );

    integer i, fd;
    reg [7:0] c;
    initial begin
        #1;
        fd = $fopen("rom_dump.txt", "w");
        for (i = 0; i < 512; i = i + 1) $fdisplay(fd, "it %0d %09h", i, u.it_rom[i]);
        for (i = 0; i < 128; i = i + 1) begin
            c = u.str_rom[i];
            $fdisplay(fd, "str %0d %02h", i, {c[6], c[4:0]});
        end
        for (i = 0; i < 512; i = i + 1) $fdisplay(fd, "font %0d %02h", i, u.u_font.rom[i]);
        $fclose(fd);
        $display("rom_dump.txt: 512 + 128 + 512 entries");
        $finish;
    end
endmodule

`default_nettype wire
