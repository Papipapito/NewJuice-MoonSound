module input_debouncer
#(
    parameter int WIDTH = 1
)
(
    input clk,
    input reset_n,
    input [WIDTH-1:0] in,
    output [WIDTH-1:0] out
);

    reg [WIDTH-1:0] sync_0 = {WIDTH{1'b1}};
    reg [WIDTH-1:0] sync_1 = {WIDTH{1'b1}};
    reg [WIDTH-1:0] latched = {WIDTH{1'b1}};
    reg [2:0] cycle_count = 3'd0;
    
    always_ff @(posedge clk or negedge reset_n)
    begin
        if(!reset_n) begin
            sync_0 <= {WIDTH{1'b1}};
            sync_1 <= {WIDTH{1'b1}};
            latched <= {WIDTH{1'b1}};
            cycle_count <= 3'd0;
        end else begin
            sync_0 <= in;
            sync_1 <= sync_0;

            if (cycle_count == 3'd5) begin
                cycle_count <= 3'd0;
                for (int i = 0; i < WIDTH; i++) begin
                    case ({sync_1[i], sync_0[i]})
                        2'b00: latched[i] <= 1'b0;
                        2'b11: latched[i] <= 1'b1;
                        default: latched[i] <= latched[i];
                    endcase
                end
            end else begin
                cycle_count <= cycle_count + 1'b1;
            end
        end
    end

    assign out = latched;

endmodule
