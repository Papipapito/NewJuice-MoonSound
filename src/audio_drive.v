module audio_drive
(
    input        clk,
    input        bit_enable,
    input        bit_clock,
    input        rst_n,
    input [15:0] idata,
    output       req,
    output       HP_BCK,
    output       HP_WS,
    output       HP_DIN
);

    reg [4:0] bit_count;
    reg req_reg;
    reg load_reg;
    reg req_delayed;
    reg [15:0] shift_reg;
    reg hp_ws_reg;
    reg hp_din_reg;

    // bit_clock is an output waveform only. All serializer state remains in
    // the clk domain and advances on bit_enable.
    assign HP_BCK = bit_clock;
    assign HP_WS = hp_ws_reg;
    assign HP_DIN = hp_din_reg;
    assign req = req_reg;

    always_ff @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            bit_count <= 5'd0;
        else if (bit_enable)
            bit_count <= bit_count + 1'b1;
    end

    // MoonSound fork: request one sample per frame and send it in both
    // halves (left and right carry the same mono sample). Before, each half
    // requested its own sample, so the frame carried two consecutive ones.
    always_ff @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) begin
            req_reg <= 1'b0;
            load_reg <= 1'b0;
        end else if (bit_enable) begin
            req_reg <= bit_count == 5'd0;
            load_reg <= bit_count == 5'd0 || bit_count == 5'd16;
        end
    end

    always_ff @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) begin
            req_delayed <= 1'b0;
            shift_reg <= 16'd0;
        end else if (bit_enable) begin
            req_delayed <= load_reg;
            if (req_delayed)
                shift_reg <= idata;
            else
                shift_reg <= shift_reg << 1;
        end
    end

    always_ff @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            hp_din_reg <= 1'b0;
        else if (bit_enable)
            hp_din_reg <= shift_reg[15];
    end

    always_ff @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            hp_ws_reg <= 1'b0;
        else if (bit_enable && bit_count == 5'd3)
            hp_ws_reg <= 1'b0;
        else if (bit_enable && bit_count == 5'd19)
            hp_ws_reg <= 1'b1;
    end

endmodule
