`timescale 1ps/1ps
// tb_i2s.v - New Juice's I2S transmitter (audio_drive + clockdiv, as top.v
// instantiates them at 108 MHz) against the MAX98357A of the Tang Nano 20K.
//   - standard I2S framing: the MSB one BCLK after the WS edge, sampled on
//     rising BCLK edges; every word must come out exactly as it went in, and
//     both halves of a frame carry the same (mono) sample;
//   - a left-justified receiver (MAX98357B framing) must NOT decode it;
//   - DIN and WS must keep 10 ns of setup and hold around each rising BCLK
//     edge (MAX98357A/B datasheet, tSETUP/tHOLD/tSYNCSET/tSYNCHOLD);
//   - 32 BCLK per frame at 108 MHz / 70 = 48.2 kHz.
module tb_i2s;
    reg clk = 1'b0;
    always #4630 clk = ~clk;                      // 108 MHz
    reg rst_n = 1'b0;
    wire bck_raw, bck_rise, req, BCK, WS, DIN;
    clockdiv #(.CLK_HZ(108_000_000), .OUT_HZ(1_542_857)) u_cd (
        .clk_src(clk), .reset_n(rst_n), .clk_div(bck_raw), .clk_rise(bck_rise));
    reg [15:0] hold = 16'd0;
    audio_drive u_ad (
        .clk(clk), .bit_enable(bck_rise), .bit_clock(bck_raw), .rst_n(rst_n),
        .idata(hold), .req(req), .HP_BCK(BCK), .HP_WS(WS), .HP_DIN(DIN));

    // like top.v: synchronize req and take one sample on its rising edge
    reg [15:0] vals [0:15];
    initial begin
        vals[0]  = 16'h1234; vals[1]  = 16'h4000; vals[2]  = 16'h7FFF; vals[3]  = 16'h8000;
        vals[4]  = 16'hC000; vals[5]  = 16'h3FFF; vals[6]  = 16'h5A5A; vals[7]  = 16'hA5A5;
        vals[8]  = 16'h0001; vals[9]  = 16'hFFFF; vals[10] = 16'h6000; vals[11] = 16'h9000;
        vals[12] = 16'h2000; vals[13] = 16'hE000; vals[14] = 16'h7000; vals[15] = 16'h0000;
    end
    reg [1:0] rs = 2'b00;
    reg rsd = 1'b0;
    integer k = 0, ns = 0;
    reg [15:0] sent [0:127];
    always @(posedge clk) begin
        rs <= {rs[0], req}; rsd <= rs[1];
        if (rs[1] && !rsd && ns < 128) begin
            hold <= vals[k % 16]; sent[ns] <= vals[k % 16]; ns <= ns + 1; k <= k + 1;
        end
    end

    // standard I2S receiver (MAX98357A): the bit on the WS edge is the LSB of
    // the previous word, the MSB of the new one comes on the next edge
    reg wsp = 1'b0, ch = 1'b0;
    integer nb = 99, nL = 0, nR = 0;
    reg [15:0] sh = 16'd0;
    reg [15:0] gotL [0:127];
    integer n_pairs = 0, n_mono_bad = 0;      // R half against the L half of its frame
    // left-justified receiver (MAX98357B): the MSB comes on the WS edge
    integer nbj = 99, nLj = 0;
    reg [15:0] shj = 16'd0;
    reg [15:0] gotLj [0:127];
    real t_rise = 0.0, t_chg = 0.0, worst_hold = 1.0e12, worst_setup = 1.0e12;
    real t_ws0 = 0.0, t_ws1 = 0.0;
    integer n_ws = 0;
    always @(DIN or WS) begin
        t_chg = $realtime;
        if (rst_n && t_rise > 0.0 && (t_chg - t_rise) < worst_hold) worst_hold = t_chg - t_rise;
    end
    always @(negedge WS) if (rst_n) begin
        if (n_ws == 2) t_ws0 = $realtime;
        if (n_ws == 102) t_ws1 = $realtime;
        n_ws = n_ws + 1;
    end
    always @(posedge BCK) if (rst_n) begin
        t_rise = $realtime;
        if (t_chg > 0.0 && (t_rise - t_chg) < worst_setup) worst_setup = t_rise - t_chg;
        if (WS !== wsp) begin
            if (nb == 15) begin
                if (ch == 1'b0) begin if (nL < 128) gotL[nL] = {sh[14:0], DIN}; nL = nL + 1; end
                else begin
                    nR = nR + 1;
                    if (nL > 0) begin
                        n_pairs = n_pairs + 1;
                        if ({sh[14:0], DIN} !== gotL[nL - 1]) n_mono_bad = n_mono_bad + 1;
                    end
                end
            end
            nb = 0; sh = 16'd0; ch = WS;
            if (nbj == 16 && wsp == 1'b0) begin if (nLj < 128) gotLj[nLj] = shj; nLj = nLj + 1; end
            shj = {15'd0, DIN}; nbj = 1;
        end else begin
            if (nb < 15) begin sh = {sh[14:0], DIN}; nb = nb + 1; end
            if (nbj < 16) begin shj = {shj[14:0], DIN}; nbj = nbj + 1; end
        end
        wsp = WS;
    end

    integer i, lag, okL, okJ, bestL, bestJ, lagL, errors;
    real fs;
    task chk(input c, input [8*100-1:0] msg);
        begin
            if (c) $display("  [ok]   %0s", msg);
            else begin $display("  [FAIL] %0s", msg); errors = errors + 1; end
        end
    endtask
    initial begin
        errors = 0;
        #100_000 rst_n = 1'b1;
        #(2_200_000_000);                         // 2.2 ms, ~105 frames
        fs = 100.0 / ((t_ws1 - t_ws0) * 1.0e-12);
        $display("  tramas: %0d L, %0d R; fs = %0.1f Hz", nL, nR, fs);
        bestL = 0; bestJ = 0; lagL = 99;
        for (lag = -3; lag <= 3; lag = lag + 1) begin
            okL = 0; okJ = 0;
            for (i = 8; i < 72; i = i + 1) begin
                if (i - lag >= 0 && gotL[i] === sent[i - lag]) okL = okL + 1;
                if (i - lag >= 0 && gotLj[i] === sent[i - lag]) okJ = okJ + 1;
            end
            if (okL > bestL) begin bestL = okL; lagL = lag; end
            if (okJ > bestJ) bestJ = okJ;
        end
        for (i = 8; i < 14; i = i + 1)
            $display("  enviada %h | I2S %h | left-justified %h", sent[i - lagL], gotL[i], gotLj[i]);
        $display("  I2S: %0d/64 palabras exactas, %0d tramas con R distinta de L de %0d; left-justified: %0d/64",
                 bestL, n_mono_bad, n_pairs, bestJ);
        $display("  DIN/WS: preparacion minima %0.2f ns, mantenimiento minimo %0.2f ns (flanco de subida de BCLK)",
                 worst_setup / 1000.0, worst_hold / 1000.0);
        chk(bestL == 64 && n_pairs > 90 && n_mono_bad == 0, "I2S estandar: cada palabra llega exacta, L y R con la misma muestra (mono)");
        chk(bestJ < 32, "un receptor left-justified (MAX98357B) no la decodifica: el formato es I2S");
        chk(worst_setup >= 10_000.0 && worst_hold >= 10_000.0, "DIN/WS con 10 ns de preparacion y de mantenimiento (MAX98357A)");
        chk(fs > 48_100.0 && fs < 48_300.0, "32 BCLK por trama a 108 MHz / 70 = 48,2 kHz");
        $display("RESULTADO: %0s (%0d errores)", errors ? "FAIL" : "PASS", errors);
        $finish;
    end
endmodule
