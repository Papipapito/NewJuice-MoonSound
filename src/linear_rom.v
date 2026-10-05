module linear_rom
#(
    parameter [22:0] SDRAM_BASE = 23'h400000
)
(
    input clk,
    input reset_n,
    input enabled,
    input [15:0] addr,
    input merq_n,
    input iorq_n,
    input rd_n,
    input wr_n,
    input rfsh_n,
    input bus_snapshot_valid,
    input sltsl_n,
    input [3:0] page0_subslot_en,
    input [3:0] page1_subslot_en,
    input [3:0] page2_subslot_en,
    input [3:0] page3_subslot_en,
    output [7:0] data_out,
    output data_out_en,
    output wait_n,
    output sdrc_cmd_en,
    output [2:0] sdrc_cmd,
    output [20:0] sdrc_addr,
    output [3:0] sdrc_dqm,
    output [31:0] sdrc_data,
    input [31:0] sdrc_data_in,
    input sdrc_init_done,
    input sdrc_cmd_ack
);

    localparam [2:0] SDRAM_CMD_READ = 3'b101;
    localparam [15:0] EXPANDED_SLOT_REG_ADDR = 16'hffff;
    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_CMD = 3'd1;
    localparam [2:0] STATE_WAIT_ACK = 3'd2;
    localparam [2:0] STATE_READ_SETTLE = 3'd3;
    localparam [2:0] STATE_DONE = 3'd4;

    reg [2:0] state = STATE_IDLE;
    reg cycle_seen = 1'b0;
    reg address_snapshot_pending = 1'b0;
    reg [1:0] access_byte_lane = 2'd0;
    reg [7:0] read_data = 8'hff;
    reg read_data_active = 1'b0;
    reg [20:0] sdrc_addr_reg = 21'd0;
    reg [3:0] sdrc_dqm_reg = 4'b1111;
    reg sdrc_cmd_en_reg = 1'b0;

    wire selected_page =
        (addr[15:14] == 2'd0 && page0_subslot_en[2]) ||
        (addr[15:14] == 2'd1 && page1_subslot_en[2]) ||
        (addr[15:14] == 2'd2 && page2_subslot_en[2]) ||
        (addr[15:14] == 2'd3 && page3_subslot_en[2]);

    // FFFFh belongs exclusively to the expanded-slot register. LINEAR is a
    // ROM view: writes never reach SDRAM after the loader selects mode 02h.
    wire read_selected = enabled && !sltsl_n && selected_page &&
                         addr != EXPANDED_SLOT_REG_ADDR &&
                         !rd_n && wr_n;
    wire coherent_read = address_snapshot_pending &&
                         bus_snapshot_valid &&
                         !merq_n && iorq_n && rfsh_n;
    wire start_read = state == STATE_IDLE && read_selected &&
                      sdrc_init_done && coherent_read && !cycle_seen;

    wire [22:0] byte_address = SDRAM_BASE + {7'd0, addr};
    wire [1:0] byte_lane = byte_address[1:0];
    wire [3:0] byte_dqm =
        (byte_lane == 2'd0) ? 4'b1110 :
        (byte_lane == 2'd1) ? 4'b1101 :
        (byte_lane == 2'd2) ? 4'b1011 :
                              4'b0111;

    always_ff @(posedge clk or negedge reset_n)
    begin
        if (!reset_n) begin
            state <= STATE_IDLE;
            cycle_seen <= 1'b0;
            address_snapshot_pending <= 1'b0;
            access_byte_lane <= 2'd0;
            read_data <= 8'hff;
            read_data_active <= 1'b0;
            sdrc_addr_reg <= 21'd0;
            sdrc_dqm_reg <= 4'b1111;
            sdrc_cmd_en_reg <= 1'b0;
        end else begin
            sdrc_cmd_en_reg <= 1'b0;

            if (!read_selected) begin
                cycle_seen <= 1'b0;
                address_snapshot_pending <= 1'b0;
                read_data_active <= 1'b0;
                if (state == STATE_DONE)
                    state <= STATE_IDLE;
            end else if (state == STATE_IDLE && !cycle_seen &&
                         !address_snapshot_pending) begin
                address_snapshot_pending <= 1'b1;
            end

            case (state)
                STATE_IDLE: begin
                    // MoonSound fork (timing): the request registers load on
                    // every idle clock and are only used once sdrc_cmd_en is
                    // issued, so the start decision no longer drives their
                    // clock enables (same values, same cycle as before).
                    sdrc_addr_reg <= byte_address[22:2];
                    sdrc_dqm_reg <= byte_dqm;
                    if (start_read) begin
                        access_byte_lane <= byte_lane;
                        sdrc_cmd_en_reg <= 1'b1;
                        cycle_seen <= 1'b1;
                        address_snapshot_pending <= 1'b0;
                        state <= STATE_CMD;
                    end
                end
                STATE_CMD: state <= STATE_WAIT_ACK;
                STATE_WAIT_ACK: begin
                    if (sdrc_cmd_ack) begin
                        case (access_byte_lane)
                            2'd0: read_data <= sdrc_data_in[7:0];
                            2'd1: read_data <= sdrc_data_in[15:8];
                            2'd2: read_data <= sdrc_data_in[23:16];
                            default: read_data <= sdrc_data_in[31:24];
                        endcase
                        read_data_active <= 1'b1;
                        state <= STATE_READ_SETTLE;
                    end
                end
                STATE_READ_SETTLE: state <= STATE_DONE;
                default: begin
                    if (!read_selected)
                        state <= STATE_IDLE;
                end
            endcase
        end
    end

    assign data_out = read_data;
    assign data_out_en = read_data_active && read_selected;
    assign wait_n = !read_selected ||
                    (sdrc_init_done && state == STATE_DONE);
    assign sdrc_cmd_en = sdrc_cmd_en_reg;
    assign sdrc_cmd = SDRAM_CMD_READ;
    assign sdrc_addr = sdrc_addr_reg;
    assign sdrc_dqm = sdrc_dqm_reg;
    assign sdrc_data = 32'd0;

endmodule
