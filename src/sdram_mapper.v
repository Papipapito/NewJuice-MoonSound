module sdram_mapper
(
    input clk,
    input cpu_clk_high,
    input reset_n,
    input [15:0] addr,
    input [7:0] data_in,
    input merq_n,
    input iorq_n,
    input rd_n,
    input wr_n,
    input rfsh_n,
    input m1_n,
    input sltsl_n,
    input [3:0] page0_subslot_en,
    input [3:0] page1_subslot_en,
    input [3:0] page2_subslot_en,
    input [3:0] page3_subslot_en,
    output [7:0] data_out,
    output data_out_en,
    output wait_n,

    output [7:0] debug_page0,
    output [7:0] debug_page1,
    output [7:0] debug_page2,
    output [7:0] debug_page3,

    output sdrc_cmd_en,
    output [2:0] sdrc_cmd,
    output sdrc_precharge_ctrl,
    output sdram_power_down,
    output sdram_selfrefresh,
    output [20:0] sdrc_addr,
    output [3:0] sdrc_dqm,
    output [31:0] sdrc_data,
    output [7:0] sdrc_data_len,
    input [31:0] sdrc_data_in,
    input sdrc_init_done,
    input sdrc_cmd_ack
);

    localparam [2:0] SDRAM_CMD_READ = 3'b101;  // {ras_n, cas_n, wen_n}
    localparam [2:0] SDRAM_CMD_WRITE = 3'b100;
    localparam [15:0] EXPANDED_SLOT_REG_ADDR = 16'hffff;

    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_CMD = 3'd1;
    localparam [2:0] STATE_WAIT_ACK = 3'd2;
    localparam [2:0] STATE_DONE = 3'd3;

    reg [7:0] mapper_page [0:3];
    reg [2:0] state = STATE_IDLE;
    reg access_is_read = 1'b0;
    reg [1:0] access_byte_lane = 2'b00;
    reg [7:0] read_data = 8'hff;
    reg [20:0] sdrc_addr_reg = 21'd0;
    reg [3:0] sdrc_dqm_reg = 4'b1111;
    reg [31:0] sdrc_data_reg = 32'd0;
    reg [2:0] sdrc_cmd_reg = SDRAM_CMD_READ;
    reg sdrc_cmd_en_reg = 1'b0;
    reg cpu_cycle_seen = 1'b0;
    reg read_data_active = 1'b0;
    reg mapper_port_write_seen = 1'b0;

    // M1 must be high for normal I/O cycles. Without this qualification an
    // interrupt acknowledge cycle can corrupt or drive mapper ports FC-FF.
    wire mapper_port_selected =
        !iorq_n && m1_n && addr[7:2] == 6'b111111;
    wire mapper_port_read = mapper_port_selected && !rd_n;
    wire mapper_port_write = mapper_port_selected && !wr_n;
    wire [1:0] mapper_port_page = addr[1:0];

    wire mapper_subslot_selected =
        (addr[15:14] == 2'd0 && page0_subslot_en[3]) ||
        (addr[15:14] == 2'd1 && page1_subslot_en[3]) ||
        (addr[15:14] == 2'd2 && page2_subslot_en[3]) ||
        (addr[15:14] == 2'd3 && page3_subslot_en[3]);
    wire memory_cycle_selected =
        !merq_n && iorq_n && rfsh_n && !sltsl_n &&
        mapper_subslot_selected && addr != EXPANDED_SLOT_REG_ADDR;
    wire memory_read_selected = memory_cycle_selected && !rd_n;
    wire memory_write_selected = memory_cycle_selected && !wr_n;
    wire memory_access_selected = memory_read_selected || memory_write_selected;
    wire memory_read_held = memory_read_selected;

    wire [7:0] selected_mapper_page =
        (addr[15:14] == 2'd0) ? mapper_page[0] :
        (addr[15:14] == 2'd1) ? mapper_page[1] :
        (addr[15:14] == 2'd2) ? mapper_page[2] :
                                mapper_page[3];

    wire [21:0] mapper_byte_addr = {selected_mapper_page, addr[13:0]};
    wire [1:0] byte_lane = mapper_byte_addr[1:0];
    wire [3:0] byte_dqm =
        (byte_lane == 2'd0) ? 4'b1110 :
        (byte_lane == 2'd1) ? 4'b1101 :
        (byte_lane == 2'd2) ? 4'b1011 :
                              4'b0111;

    wire cpu_cycle_active = memory_access_selected && sdrc_init_done;
    wire start_access = state == STATE_IDLE && cpu_cycle_active && !cpu_cycle_seen;

    always_ff @(posedge clk or negedge reset_n)
    begin
        if(!reset_n) begin
            mapper_page[0] <= 8'h03;
            mapper_page[1] <= 8'h02;
            mapper_page[2] <= 8'h01;
            mapper_page[3] <= 8'h00;
            state <= STATE_IDLE;
            access_is_read <= 1'b0;
            access_byte_lane <= 2'b00;
            read_data <= 8'hff;
            sdrc_addr_reg <= 21'd0;
            sdrc_dqm_reg <= 4'b1111;
            sdrc_data_reg <= 32'd0;
            sdrc_cmd_reg <= SDRAM_CMD_READ;
            sdrc_cmd_en_reg <= 1'b0;
            cpu_cycle_seen <= 1'b0;
            read_data_active <= 1'b0;
            mapper_port_write_seen <= 1'b0;
        end else begin
            sdrc_cmd_en_reg <= 1'b0;

            if (!memory_read_held) begin
                read_data_active <= 1'b0;
            end

            if (!memory_access_selected) begin
                cpu_cycle_seen <= 1'b0;
            end

            if (!mapper_port_write)
                mapper_port_write_seen <= 1'b0;
            else if (cpu_clk_high && !mapper_port_write_seen) begin
                mapper_page[mapper_port_page] <= data_in;
                mapper_port_write_seen <= 1'b1;
            end

            case (state)
                STATE_IDLE: begin
                    if (start_access) begin
                        access_is_read <= memory_read_selected;
                        access_byte_lane <= byte_lane;
                        // MoonSound fork: 2 MB mapper (128 pages). Page bit 7 is
                        // ignored, so pages 80h-FFh mirror 00h-7Fh like a real
                        // 2 MB mapper and SDRAM 0x200000+ (YRW801) is never reached.
                        sdrc_addr_reg <= {2'b00, mapper_byte_addr[20:2]};
                        sdrc_dqm_reg <= byte_dqm;
                        sdrc_data_reg <= {4{data_in}};
                        sdrc_cmd_reg <= memory_read_selected ? SDRAM_CMD_READ : SDRAM_CMD_WRITE;
                        sdrc_cmd_en_reg <= 1'b1;
                        cpu_cycle_seen <= 1'b1;
                        state <= STATE_CMD;
                    end
                end
                STATE_CMD: begin
                    state <= STATE_WAIT_ACK;
                end
                STATE_WAIT_ACK: begin
                    if (sdrc_cmd_ack) begin
                        if (access_is_read) begin
                            case (access_byte_lane)
                                2'd0: read_data <= sdrc_data_in[7:0];
                                2'd1: read_data <= sdrc_data_in[15:8];
                                2'd2: read_data <= sdrc_data_in[23:16];
                                default: read_data <= sdrc_data_in[31:24];
                            endcase
                            if (memory_read_held) begin
                                read_data_active <= 1'b1;
                            end
                        end
                        state <= STATE_DONE;
                    end
                end
                default: begin
                    if (!memory_access_selected) begin
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

    assign data_out =
        mapper_port_read ? mapper_page[mapper_port_page] :
        read_data;
    assign data_out_en = mapper_port_read || (read_data_active && access_is_read && memory_read_held);
    assign wait_n = !memory_access_selected || (sdrc_init_done && state == STATE_DONE);

    // Read-only visibility for the HDMI debugger. Keeping these separate
    // from the mapper I/O readback avoids affecting the CPU data bus.
    assign debug_page0 = mapper_page[0];
    assign debug_page1 = mapper_page[1];
    assign debug_page2 = mapper_page[2];
    assign debug_page3 = mapper_page[3];

    assign sdrc_cmd_en = sdrc_cmd_en_reg;
    assign sdrc_cmd = sdrc_cmd_reg;
    assign sdrc_precharge_ctrl = 1'b1;
    assign sdram_power_down = 1'b0;
    assign sdram_selfrefresh = 1'b0;
    assign sdrc_addr = sdrc_addr_reg;
    assign sdrc_dqm = sdrc_dqm_reg;
    assign sdrc_data = sdrc_data_reg;
    assign sdrc_data_len = 8'd0;

endmodule
