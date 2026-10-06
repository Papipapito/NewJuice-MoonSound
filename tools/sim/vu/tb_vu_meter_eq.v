// ============================================================================
// tb_vu_meter_eq.v - vu_meter_nj.v (the fork's meter) against MoonTANG's
// vu_meter.v (moontang/vu_meter.v, commit 5400f15, the reference).
//
// Both get the same clock, the same frame toggle and the same six signals.
// The signals are random in level (all 16 exponents, both signs, -32768
// included) and in how long each value lasts (from 1 clock to a whole frame),
// and some frames are silent, so the bars rise, fall to zero and the peak
// marks go through their 45-frame hold. Frames are short (NCH + 20 to 400
// clocks) so that hundreds of them run.
//
// vu_meter_nj runs one clock behind its inputs (its input register) and
// spreads the frame change over NCH clocks, so the outputs are compared once
// they have settled: 16 clocks after each frame tick. They must be equal in
// every frame. With -DMUTANT=1 the bench uses HOLD = 44 in vu_meter_nj and
// must FAIL (negative control).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_vu_meter_eq;
    localparam integer NCH = 6;
`ifdef MUTANT
    localparam integer HOLD_NJ = 44;
`else
    localparam integer HOLD_NJ = 45;
`endif

    reg clk = 1'b0;
    always #9.259 clk = ~clk;                  // 54 MHz

    reg               frame_tog = 1'b0;
    reg  [NCH*16-1:0] samples   = {NCH*16{1'b0}};
    wire [NCH*5-1:0]  lv_ref, pk_ref, lv_nj, pk_nj;

    vu_meter #(.NCH(NCH), .HOLD(45)) u_ref (
        .clk(clk), .frame_tog(frame_tog), .samples(samples), .level(lv_ref), .peak(pk_ref));
    vu_meter_nj #(.NCH(NCH), .HOLD(HOLD_NJ)) u_nj (
        .clk(clk), .frame_tog(frame_tog), .samples(samples), .level(lv_nj), .peak(pk_nj));

    // random signal: a mantissa scaled by a random exponent, random sign
    integer seed = 32'h4E4A5653;
    function [15:0] rnd_sample(input integer quiet);
        integer e, v;
        begin
            e = $unsigned($random(seed)) % 17;            // 0..16
            v = $unsigned($random(seed)) & 16'hFFFF;
            v = (e == 16) ? 32'hFFFF8000 : (v >> (16 - e));
            if ($random(seed) & 1) v = -v;
            if (quiet) v = 0;
            rnd_sample = v[15:0];
        end
    endfunction

    integer ch;
    integer hold_left [0:NCH-1];
    integer frame_len, frame_cnt = 0, nframes = 0, quiet = 0;
    integer errors = 0, compared = 0, nonzero = 0, held = 0, fell = 0;
    reg [NCH*5-1:0] lv_prev = 0, pk_prev = 0;
    integer k;

    initial for (ch = 0; ch < NCH; ch = ch + 1) hold_left[ch] = 0;

    // inputs change on the falling edge (away from the sampling edge)
    always @(negedge clk) begin
        for (ch = 0; ch < NCH; ch = ch + 1) begin
            if (hold_left[ch] == 0) begin
                samples[ch*16 +: 16] = rnd_sample(quiet);
                case ($unsigned($random(seed)) % 4)
                    0: hold_left[ch] = 1 + $unsigned($random(seed)) % 4;
                    1: hold_left[ch] = 1 + $unsigned($random(seed)) % 40;
                    2: hold_left[ch] = 1 + $unsigned($random(seed)) % 400;
                    default: hold_left[ch] = 1 + $unsigned($random(seed)) % 2000;
                endcase
            end
            else hold_left[ch] = hold_left[ch] - 1;
        end
        if (frame_cnt == 0) begin
            frame_tog = ~frame_tog;
            nframes = nframes + 1;
            frame_len = NCH + 20 + $unsigned($random(seed)) % 380;
            frame_cnt = frame_len;
            // runs of silent frames, so that bars fall and marks expire
            if (quiet == 0 && ($unsigned($random(seed)) % 20) == 0) quiet = 60 + $unsigned($random(seed)) % 30;
            else if (quiet > 0) quiet = quiet - 1;
        end
        else frame_cnt = frame_cnt - 1;
    end

    // compare once both have settled after a tick
    always @(posedge clk) if (u_ref.tick) begin
        repeat (16) @(posedge clk);
        compared = compared + 1;
        if (lv_ref !== lv_nj || pk_ref !== pk_nj) begin
            errors = errors + 1;
            if (errors <= 5)
                $display("  frame %0d: ref level %h peak %h | nj level %h peak %h", nframes, lv_ref, pk_ref, lv_nj, pk_nj);
        end
        if (lv_ref != 0) nonzero = nonzero + 1;
        for (k = 0; k < NCH; k = k + 1) begin
            if (pk_ref[k*5 +: 5] == pk_prev[k*5 +: 5] && pk_ref[k*5 +: 5] != 0 && lv_ref[k*5 +: 5] < pk_ref[k*5 +: 5]) held = held + 1;
            if (lv_ref[k*5 +: 5] < lv_prev[k*5 +: 5]) fell = fell + 1;
        end
        lv_prev = lv_ref; pk_prev = pk_ref;
    end

    initial begin
        #(18.518 * 300000);
        $display("frames %0d, compared %0d (with some bar lit %0d; bar falls %0d, held marks %0d), differences %0d",
                 nframes, compared, nonzero, fell, held, errors);
        if (errors == 0 && compared > 500 && nonzero > 100 && fell > 100 && held > 100)
            $display("RESULTADO: PASS");
        else
            $display("RESULTADO: FAIL");
        $finish;
    end
endmodule

`default_nettype wire
