module flash_roms
(
    input clk,
    input reset_n,
    input load_enable,

    input [15:0] addr,
    input [7:0] data_in,
    input merq_n,
    input iorq_n,
    input rd_n,
    input wr_n,
    input rfsh_n,
    input sltsl_n,
    input [3:0] page0_subslot_en,
    input [3:0] page1_subslot_en,
    input dos2_overlay_enabled,

    output [7:0] data_out,
    output data_out_en,
    output wait_n,
    output loaded,

    output mspi_cs,
    output mspi_sclk,
    input mspi_miso,
    output mspi_mosi,

    output sdrc_cmd_en,
    output [2:0] sdrc_cmd,
    output [20:0] sdrc_addr,
    output [3:0] sdrc_dqm,
    output [31:0] sdrc_data,
    input [31:0] sdrc_data_in,
    input sdrc_cmd_ack
);

    localparam [2:0] SDRAM_CMD_READ = 3'b101;
    localparam [2:0] SDRAM_CMD_WRITE = 3'b100;
    localparam [23:0] FLASH_BASE = 24'h100000;
    localparam [17:0] ROM_BYTE_COUNT = 18'h28000;
    localparam [22:0] SDRAM_ROM_BASE = 23'h600000;

    localparam [3:0] STATE_WAIT_ENABLE = 4'd0;
    localparam [3:0] STATE_START_FLASH = 4'd1;
    localparam [3:0] STATE_WAIT_FLASH_BYTE = 4'd2;
    localparam [3:0] STATE_LOAD_CMD = 4'd3;
    localparam [3:0] STATE_LOAD_ACK = 4'd4;
    localparam [3:0] STATE_READY = 4'd5;
    localparam [3:0] STATE_ROM_CMD = 4'd6;
    localparam [3:0] STATE_ROM_ACK = 4'd7;
    localparam [3:0] STATE_ROM_DONE = 4'd8;
    localparam [3:0] STATE_WAIT_FLASH_RELEASE = 4'd9;
    localparam [3:0] STATE_CLEAR_SMR_CMD = 4'd10;
    localparam [3:0] STATE_CLEAR_SMR_ACK = 4'd11;

    reg [3:0] state = STATE_WAIT_ENABLE;
    reg [17:0] load_offset = 18'd0;
    reg [1:0] clear_smr_index = 2'd0;
    reg [2:0] dos2_bank = 3'd0;
    reg [7:0] read_data_reg = 8'hff;
    reg [1:0] read_lane_reg = 2'd0;
    reg sdrc_cmd_en_reg = 1'b0;
    reg [2:0] sdrc_cmd_reg = SDRAM_CMD_WRITE;
    reg [20:0] sdrc_addr_reg = 21'd0;
    reg [3:0] sdrc_dqm_reg = 4'b1111;
    reg [31:0] sdrc_data_reg = 32'd0;
    reg flash_start = 1'b0;
    reg flash_stop = 1'b0;
    reg flash_byte_ready = 1'b0;
    reg cpu_cycle_seen = 1'b0;

    wire [7:0] flash_byte;
    wire flash_byte_valid;

    wire page0_selected = !sltsl_n && !merq_n && iorq_n && rfsh_n &&
                          addr[15:14] == 2'b00;
    wire page1_selected = !sltsl_n && !merq_n && iorq_n && rfsh_n &&
                          addr[15:14] == 2'b01;
    wire sfg_selected = page0_selected && page0_subslot_en[1];
    wire dos2_selected = page1_selected && page1_subslot_en[0];
    wire fmpac_selected = page1_selected && page1_subslot_en[1];
    wire sfg_io_selected = sfg_selected &&
                           (addr == 16'h3ff0 || addr == 16'h3ff1);
    wire dos2_overlay_selected = dos2_overlay_enabled && dos2_selected &&
                                 addr >= 16'h7c00 && addr <= 16'h7eff;
    wire rom_read_selected = !rd_n &&
                             ((dos2_selected && !dos2_overlay_selected) ||
                              fmpac_selected ||
                              (sfg_selected && !sfg_io_selected));
    wire dos2_bank_write = !wr_n && dos2_selected && addr == 16'h6000;
    wire [17:0] dos2_offset = {dos2_bank, addr[13:0]};
    wire [17:0] fmpac_offset = 18'h20000 + {4'd0, addr[13:0]};
    wire [17:0] sfg_offset = 18'h24000 + {4'd0, addr[13:0]};
    wire [17:0] selected_rom_offset =
        dos2_selected ? dos2_offset :
        fmpac_selected ? fmpac_offset :
                         sfg_offset;
    wire [22:0] selected_sdram_byte_addr = SDRAM_ROM_BASE + selected_rom_offset;
    wire [22:0] load_sdram_byte_addr = SDRAM_ROM_BASE + load_offset;
    // SMR reset maps banks 0/1 at 4000h and banks 2/3 at 8000h. Clear the
    // two possible "AB" cartridge signatures before releasing the CPU so
    // uninitialized SDRAM cannot be mistaken for an extension ROM.
    wire [22:0] clear_smr_byte_addr =
        (clear_smr_index == 2'd0) ? 23'h400000 :
        (clear_smr_index == 2'd1) ? 23'h400001 :
        (clear_smr_index == 2'd2) ? 23'h404000 :
                                    23'h404001;
    wire load_complete = state == STATE_READY || state == STATE_ROM_CMD ||
                         state == STATE_ROM_ACK || state == STATE_ROM_DONE;

    function automatic [3:0] byte_dqm;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: byte_dqm = 4'b1110;
                2'd1: byte_dqm = 4'b1101;
                2'd2: byte_dqm = 4'b1011;
                default: byte_dqm = 4'b0111;
            endcase
        end
    endfunction

    spi_flash_reader #(.CLK_DIV(2)) flash_reader_inst(
        .clk(clk),
        .reset_n(reset_n),
        .start(flash_start),
        .stop(flash_stop),
        .start_addr(FLASH_BASE),
        .byte_ready(flash_byte_ready),
        .byte_data(flash_byte),
        .byte_valid(flash_byte_valid),
        .busy(),
        .mspi_cs(mspi_cs),
        .mspi_sclk(mspi_sclk),
        .mspi_miso(mspi_miso),
        .mspi_mosi(mspi_mosi)
    );

    always_ff @(posedge clk or negedge reset_n)
    begin
        if (!reset_n) begin
            state <= STATE_WAIT_ENABLE;
            load_offset <= 18'd0;
            clear_smr_index <= 2'd0;
            dos2_bank <= 3'd0;
            read_data_reg <= 8'hff;
            read_lane_reg <= 2'd0;
            sdrc_cmd_en_reg <= 1'b0;
            sdrc_cmd_reg <= SDRAM_CMD_WRITE;
            sdrc_addr_reg <= 21'd0;
            sdrc_dqm_reg <= 4'b1111;
            sdrc_data_reg <= 32'd0;
            flash_start <= 1'b0;
            flash_stop <= 1'b0;
            flash_byte_ready <= 1'b0;
            cpu_cycle_seen <= 1'b0;
        end else begin
            sdrc_cmd_en_reg <= 1'b0;
            flash_start <= 1'b0;
            flash_stop <= 1'b0;
            flash_byte_ready <= 1'b0;

            if (!rom_read_selected)
                cpu_cycle_seen <= 1'b0;

            if (load_complete && dos2_bank_write)
                dos2_bank <= data_in[2:0];

            case (state)
                STATE_WAIT_ENABLE: begin
                    if (load_enable)
                        state <= STATE_START_FLASH;
                end
                STATE_START_FLASH: begin
                    flash_start <= 1'b1;
                    state <= STATE_WAIT_FLASH_BYTE;
                end
                STATE_WAIT_FLASH_BYTE: begin
                    if (flash_byte_valid)
                        state <= STATE_LOAD_CMD;
                end
                STATE_LOAD_CMD: begin
                    sdrc_cmd_reg <= SDRAM_CMD_WRITE;
                    sdrc_addr_reg <= load_sdram_byte_addr[22:2];
                    sdrc_dqm_reg <= byte_dqm(load_sdram_byte_addr[1:0]);
                    sdrc_data_reg <= {4{flash_byte}};
                    sdrc_cmd_en_reg <= 1'b1;
                    state <= STATE_LOAD_ACK;
                end
                STATE_LOAD_ACK: begin
                    if (sdrc_cmd_ack) begin
                        flash_byte_ready <= 1'b1;
                        if (load_offset == ROM_BYTE_COUNT - 1'b1) begin
                            flash_stop <= 1'b1;
                            clear_smr_index <= 2'd0;
                            state <= STATE_CLEAR_SMR_CMD;
                        end else begin
                            load_offset <= load_offset + 1'b1;
                            // byte_ready and byte_valid cross between two
                            // synchronous state machines. Wait until the SPI
                            // reader has actually dropped byte_valid before
                            // accepting the next byte, otherwise the previous
                            // byte can be written twice.
                            state <= STATE_WAIT_FLASH_RELEASE;
                        end
                    end
                end
                STATE_WAIT_FLASH_RELEASE: begin
                    if (!flash_byte_valid)
                        state <= STATE_WAIT_FLASH_BYTE;
                end
                STATE_CLEAR_SMR_CMD: begin
                    sdrc_cmd_reg <= SDRAM_CMD_WRITE;
                    sdrc_addr_reg <= clear_smr_byte_addr[22:2];
                    sdrc_dqm_reg <= byte_dqm(clear_smr_byte_addr[1:0]);
                    sdrc_data_reg <= 32'd0;
                    sdrc_cmd_en_reg <= 1'b1;
                    state <= STATE_CLEAR_SMR_ACK;
                end
                STATE_CLEAR_SMR_ACK: begin
                    if (sdrc_cmd_ack) begin
                        if (clear_smr_index == 2'd3)
                            state <= STATE_READY;
                        else begin
                            clear_smr_index <= clear_smr_index + 1'b1;
                            state <= STATE_CLEAR_SMR_CMD;
                        end
                    end
                end
                STATE_READY: begin
                    // MoonSound fork (timing): the request registers load on
                    // every idle clock and are only used once sdrc_cmd_en is
                    // issued, so the start decision no longer drives their
                    // clock enables (same values, same cycle as before).
                    sdrc_cmd_reg <= SDRAM_CMD_READ;
                    sdrc_addr_reg <= selected_sdram_byte_addr[22:2];
                    sdrc_dqm_reg <= byte_dqm(selected_sdram_byte_addr[1:0]);
                    sdrc_data_reg <= 32'd0;
                    if (rom_read_selected && !cpu_cycle_seen) begin
                        read_lane_reg <= selected_sdram_byte_addr[1:0];
                        sdrc_cmd_en_reg <= 1'b1;
                        cpu_cycle_seen <= 1'b1;
                        state <= STATE_ROM_CMD;
                    end
                end
                STATE_ROM_CMD: begin
                    state <= STATE_ROM_ACK;
                end
                STATE_ROM_ACK: begin
                    if (sdrc_cmd_ack) begin
                        case (read_lane_reg)
                            2'd0: read_data_reg <= sdrc_data_in[7:0];
                            2'd1: read_data_reg <= sdrc_data_in[15:8];
                            2'd2: read_data_reg <= sdrc_data_in[23:16];
                            default: read_data_reg <= sdrc_data_in[31:24];
                        endcase
                        state <= STATE_ROM_DONE;
                    end
                end
                default: begin
                    if (!rom_read_selected)
                        state <= STATE_READY;
                end
            endcase
        end
    end

    assign data_out = read_data_reg;
    assign data_out_en = state == STATE_ROM_DONE && rom_read_selected;
    assign wait_n = load_complete &&
                    (!rom_read_selected || state == STATE_ROM_DONE);
    assign loaded = load_complete;
    assign sdrc_cmd_en = sdrc_cmd_en_reg;
    assign sdrc_cmd = sdrc_cmd_reg;
    assign sdrc_addr = sdrc_addr_reg;
    assign sdrc_dqm = sdrc_dqm_reg;
    assign sdrc_data = sdrc_data_reg;

endmodule
