// ============================================================================
// vu_meter_nj.v - level meter for the VU meter on HDMI, New Juice version.
// Copyright (c) 2026 Albert "Papipapito", with Claude. GPL-3.0 (see NOTICE.md).
//
// Does exactly what MoonTANG's vu_meter.v does (the same outputs, frame for
// frame, a few clocks later, with each frame ending one clock later; see the
// end of this header), with much less logic, because the New Juice chip is
// full:
//
//   For each signal (16-bit signed, `clk` domain) it keeps the peak of |x|
//   over a video frame and, at the frame change, turns it into bar segments
//   on a log scale, level = 4 * (position of the top bit) + (the next two
//   bits), i.e. 1.5 dB steps; NSEG = 28 segments, the top one full scale, the
//   bottom one 42 dB below (|x| < 256 lights nothing). Ballistics, per frame:
//   the bar rises at once and falls one segment every second frame; the peak
//   mark stays HOLD frames at its maximum and then falls the same way.
//
// How it is cheaper (tools/sim/vu/tb_vu_meter_eq.v proves it equal to
// vu_meter.v on random signals):
//   - only bits 14..6 of |x| can light a segment. Each input is reduced,
//     before its register, to a 10-bit key: {x[14:6], 0} for x >= 0 and
//     {~x[14:6], x[5:0] == 0} for x < 0, so that bits 14..6 of |x| are
//     key[9:1] + key[0] (the carry of the two's complement negation). A
//     larger key never means a smaller |x|, so the peak is kept as the
//     largest key, with a plain 10-bit comparison and no negation;
//   - the frame-change work (key -> segments, bar, peak mark, hold timer) is
//     done for one signal per clock by one shared circuit, during the NCH
//     clocks after the frame change, from a copy of the peak key of each
//     signal. Bars, marks and hold timers rotate through that circuit (a ring
//     of registers), so there is no read or write multiplexer; while it runs
//     (NCH clocks, in the vertical blanking) the outputs are rotated;
//   - every input goes through one register first. That makes the crossing
//     from another clock of the same PLL (here main_clk -> 54 MHz) a plain
//     register-to-register path, and the whole meter runs one clock behind
//     its inputs, frame tick included, so nothing else changes.
//
// `frame_tog` toggles once per frame in the pixel clock domain and is
// synchronized here, with one stage more than vu_meter.v: `tick` comes one
// clock later than there, so the frame ends one clock later, which is all
// that differs (the bench feeds vu_meter.v frame_tog one clock late and
// gets the same outputs). In New Juice that stage is kept because the build
// closes timing in every placement option with it (X3), which it did not
// without it (X2); it is placement luck, not a fix of the tight paths, which
// are New Juice's own. The outputs only change right after the tick, at the
// start of the vertical blanking, so the screen generator can read them with
// no further crossing.
// ============================================================================
`default_nettype none

module vu_meter_nj #(
    parameter integer NCH  = 6,          // number of signals (2..8)
    parameter integer HOLD = 45          // frames the peak mark stays up
) (
    input  wire                 clk,
    input  wire                 frame_tog,          // toggles once per frame
    input  wire [NCH*16-1:0]    samples,            // NCH signed 16-bit signals
    output reg  [NCH*5-1:0]     level = {NCH*5{1'b0}},   // lit segments, 0..28
    output reg  [NCH*5-1:0]     peak  = {NCH*5{1'b0}}    // peak mark position, 0 = none
);
    // the 10-bit key of a sample (see above)
    function automatic [9:0] key(input [15:0] s);
        key = s[15] ? {~s[14:6], (s[5:0] == 6'd0)} : {s[14:6], 1'b0};
    endfunction

    // segments lit by the sample of key k:
    //   m = bits 14..6 of |x| (|-32768| saturates to 7FFFh, as in vu_meter.v)
    //   q = top bit of m; segments = 4 * (q - 2) + 1 + (the two bits under it),
    //   none when q < 2 (|x| < 256)
    function automatic [4:0] segs(input [9:0] k);
        reg  [9:0] m;
        reg  [3:0] q;
        reg  [1:0] f;
        integer    i;
        begin
            m = {1'b0, k[9:1]} + {9'd0, k[0]};
            if (m[9]) m = 10'h1FF;                                  // -32768
            q = 4'd0;
            for (i = 2; i < 9; i = i + 1)
                if (m[i]) q = i[3:0];
            f = 2'b00;
            for (i = 2; i < 9; i = i + 1)
                if (q == i) f = {m[i-1], m[i-2]};
            segs = (q < 4'd2) ? 5'd0 : {q[2:0] - 3'd2, 2'b00} + {3'd0, f} + 5'd1;
        end
    endfunction

    // the frame tick (one synchronizer stage more than vu_meter.v), and one
    // clock later for the inputs
    reg [3:0] ft = 4'b0000;
    always @(posedge clk) ft <= {ft[2:0], frame_tog};
    wire tick = ft[3] ^ ft[2];
    reg  tick_q = 1'b0;
    always @(posedge clk) tick_q <= tick;

    // ------------------------------------------------------------------
    //  Peak of the frame, per signal, as a key
    // ------------------------------------------------------------------
    reg [NCH*10-1:0] k_q = {NCH*10{1'b0}};       // input keys, one register
    reg [NCH*10-1:0] pk  = {NCH*10{1'b0}};       // frame in progress
    reg [NCH*10-1:0] pkf = {NCH*10{1'b0}};       // frame just ended

    genvar g;
    generate
        for (g = 0; g < NCH; g = g + 1) begin : g_ch
            always @(posedge clk) begin
                k_q[g*10 +: 10] <= key(samples[g*16 +: 16]);
                if (tick_q) begin
                    pkf[g*10 +: 10] <= pk[g*10 +: 10];
                    pk [g*10 +: 10] <= k_q[g*10 +: 10];
                end
                else if (k_q[g*10 +: 10] > pk[g*10 +: 10])
                    pk [g*10 +: 10] <= k_q[g*10 +: 10];
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    //  Frame change, one signal per clock. Bars, marks and timers rotate:
    //  at step n the head (field 0) holds signal n; its new values enter at
    //  the tail (field NCH-1) while the rest move down one field, so after
    //  NCH steps every signal is back in its own field.
    // ------------------------------------------------------------------
    reg [3:0] ch  = 4'd15;               // signal being updated; >= NCH: idle
    reg       odd = 1'b0;                // falls one frame out of two
    reg [NCH*6-1:0] tmr = {NCH*6{1'b0}};

    wire       busy = (ch < NCH);
    wire [4:0] now  = segs(pkf[ch[2:0]*10 +: 10]);
    wire [4:0] lvl  = level[4:0];
    wire [4:0] hld  = peak [4:0];
    wire [5:0] tm   = tmr  [5:0];
    reg  [4:0] lvl_n, hld_n;
    reg  [5:0] tm_n;

    always @* begin
        // bar
        if (now >= lvl)                 lvl_n = now;
        else if (odd && lvl != 5'd0)    lvl_n = lvl - 5'd1;
        else                            lvl_n = lvl;
        // peak mark
        hld_n = hld;
        tm_n  = tm;
        if (now >= hld) begin
            hld_n = now;
            tm_n  = HOLD[5:0];
        end
        else if (tm != 6'd0)            tm_n  = tm - 6'd1;
        else if (odd && hld != 5'd0)    hld_n = hld - 5'd1;
    end

    always @(posedge clk) begin
        if (tick_q)
            ch <= 4'd0;
        else if (busy) begin
            ch    <= ch + 4'd1;
            if (ch == NCH - 1) odd <= ~odd;
            level <= {lvl_n, level[NCH*5-1:5]};
            peak  <= {hld_n, peak [NCH*5-1:5]};
            tmr   <= {tm_n,  tmr  [NCH*6-1:6]};
        end
    end
endmodule

`default_nettype wire
