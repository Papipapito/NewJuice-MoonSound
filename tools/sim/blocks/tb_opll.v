// ============================================================================
// tb_opll.v - New Juice's OPLL (jt2413, unchanged) simulated directly.
// In the whole-board bench, after sv2v, Icarus leaves the jt2413 output at X;
// this bench runs the same RTL without sv2v, with the same 27 MHz clock and
// 3.58 MHz enable as top.v and the same register writes, and checks that it
// produces sound. Needs -DSIMULATION (jotego cores zero their dividers).
// ============================================================================
`timescale 1ns/1ps
module tb_opll;
    reg clk = 0; always #18.5185 clk = ~clk;                 // 27 MHz
    reg rst = 1; reg [31:0] acc = 0; reg cen = 0;
    always @(posedge clk) {cen, acc} <= {1'b0, acc} + 33'd569408471;   // as top.v
    reg [7:0] din = 0; reg a = 0, cs_n = 1, wr_n = 1;
    wire signed [15:0] snd;
    jt2413 u (.rst(rst), .clk(clk), .cen(cen), .din(din), .addr(a), .cs_n(cs_n),
              .wr_n(wr_n), .snd(snd), .sample());
    task w(input aa, input [7:0] d);
        begin
            @(posedge clk); a <= aa; din <= d; cs_n <= 0; wr_n <= 0;
            repeat (20) @(posedge clk); cs_n <= 1; wr_n <= 1;
            repeat (100) @(posedge clk);
        end
    endtask
    integer mx = 0, mn = 0, nx = 0;
    always @(posedge clk) if (!rst) begin
        if (^snd === 1'bx) nx = nx + 1;
        else begin if ($signed(snd) > mx) mx = $signed(snd); if ($signed(snd) < mn) mn = $signed(snd); end
    end
    initial begin
        #200000 rst = 0; #2000;
        // the board bench's writes: user instrument 0, channel 0 key on
        w(0, 8'h00); w(1, 8'h21); w(0, 8'h01); w(1, 8'h21); w(0, 8'h02); w(1, 8'h3F);
        w(0, 8'h03); w(1, 8'h00); w(0, 8'h04); w(1, 8'hF0); w(0, 8'h05); w(1, 8'hF0);
        w(0, 8'h06); w(1, 8'h0F); w(0, 8'h07); w(1, 8'h0F); w(0, 8'h30); w(1, 8'h00);
        w(0, 8'h10); w(1, 8'h80); w(0, 8'h20); w(1, 8'h19);
        #3000000;
        $display("OPLL: max=%0d min=%0d, muestras X tras el reset: %0d", mx, mn, nx);
        if (mx > 200 && mn < -200 && nx < 2000) $display("RESULTADO: PASS");
        else $display("RESULTADO: FAIL");
        $finish;
    end
endmodule
