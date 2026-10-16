module slot_expander
(
    input clk,
    input reset_n,
    input [15:0] addr,
    input [7:0] data_in,
    input merq_n,
    input iorq_n,
    input rd_n,
    input wr_n,
    input sltsl_n,
    // MoonSound fork (timing): addr == FFFFh, registered with addr by
    // mp_debouncer (the same decode sdram_mapper and linear_rom exclude).
    input addr_is_ffff,
    output [7:0] data_out,
    output data_out_en,
    output [3:0] page0_subslot_en,
    output [3:0] page1_subslot_en,
    output [3:0] page2_subslot_en,
    output [3:0] page3_subslot_en,
    output [7:0] debug_expanded_slot
);

    reg [7:0] expanded_slot_reg = 8'h00;

    wire selected = !sltsl_n && !merq_n /*&& iorq_n*/ &&
                    addr_is_ffff;
    wire read_selected = selected && !rd_n;
    wire write_selected = selected && !wr_n;

    wire [1:0] page0_subslot = expanded_slot_reg[1:0];
    wire [1:0] page1_subslot = expanded_slot_reg[3:2];
    wire [1:0] page2_subslot = expanded_slot_reg[5:4];
    wire [1:0] page3_subslot = expanded_slot_reg[7:6];

    always_ff @(posedge clk or negedge reset_n)
    begin
        if(!reset_n) begin
            expanded_slot_reg <= 8'h00;
        end else if (write_selected) begin
            expanded_slot_reg <= data_in;
        end
    end

    assign data_out = ~expanded_slot_reg;
    assign data_out_en = read_selected;
    assign debug_expanded_slot = expanded_slot_reg;

    // Direct equality decoders avoid implementing each one-hot output as a
    // variable barrel shift. This is on the critical CPU-to-SDRAM path.
    assign page0_subslot_en = {
        page0_subslot == 2'd3, page0_subslot == 2'd2,
        page0_subslot == 2'd1, page0_subslot == 2'd0
    };
    assign page1_subslot_en = {
        page1_subslot == 2'd3, page1_subslot == 2'd2,
        page1_subslot == 2'd1, page1_subslot == 2'd0
    };
    assign page2_subslot_en = {
        page2_subslot == 2'd3, page2_subslot == 2'd2,
        page2_subslot == 2'd1, page2_subslot == 2'd0
    };
    assign page3_subslot_en = {
        page3_subslot == 2'd3, page3_subslot == 2'd2,
        page3_subslot == 2'd1, page3_subslot == 2'd0
    };

endmodule
