module mp_debouncer
(
    input clk,
    input reset_n,
    input [7:0] mp,
    output [2:0] msel_n,
    output [7:0] a_lo,
    output [7:0] a_hi,
    output [15:0] addr,
    output merq_n,
    output iorq_n,
    output cs1_n,
    output cs2_n,
    output reset_in_n,
    output rfsh_n,
    output cs12_n,
    output m1_n,
    output inputs_latched,
    // MoonSound fork (timing): decodes of addr, published with it (below)
    output addr_is_ffff,
    output addr_is_sfg_io,
    output addr_is_dos2_overlay
);

    localparam int MP_A_LO = 0;
    localparam int MP_A_HI = 8;
    localparam int MP_CTRL = 16;
    localparam int MP_MERQ_N = 16;
    localparam int MP_IORQ_N = 17;
    localparam int MP_CS1_N = 18;
    localparam int MP_CS2_N = 19;
    localparam int MP_RESET_IN_N = 20;
    localparam int MP_RFSH_N = 21;
    localparam int MP_CS12_N = 22;
    localparam int MP_M1_N = 23;

    reg [2:0] msel_reg = 3'b111;
    reg [2:0] scan_phase = 3'd0;
    reg [23:0] previous_sample = 24'hffffff;
    reg [23:0] debounced = 24'hffffff;
    reg [23:0] latched = 24'hffffff;
    reg inputs_latched_reg = 1'b0;

    // MoonSound fork (timing): three comparisons of the published address,
    // registered on the same edge as the address. A[7:0] and A[15:8] stop
    // changing in `debounced` at scan phases 1 and 3, so in phase 5 the flags
    // are computed from the very value that goes into `latched`: each one
    // always equals its comparison on addr, with no clock of delay. This
    // takes the 16-bit comparisons off the one-clock paths from the snapshot
    // to slot_expander, sdram_mapper, linear_rom and flash_roms, where
    // synthesis shared them between modules in chains of 3 to 5 LUTs.
    // The reset values are those of FFFFh.
    wire [15:0] debounced_addr =
        {debounced[MP_A_HI +: 8], debounced[MP_A_LO +: 8]};
    reg addr_is_ffff_reg = 1'b1;          // FFFFh: expanded-slot register
    reg addr_is_sfg_io_reg = 1'b0;        // 3FF0h-3FF1h: SFG-01 (YM2151)
    reg addr_is_dos2_overlay_reg = 1'b0;  // 7C00h-7EFFh: SD overlay

    always_ff @(posedge clk or negedge reset_n)
    begin
        if(!reset_n) begin
            msel_reg <= 3'b111;
            scan_phase <= 3'd0;
            previous_sample <= 24'hffffff;
            debounced <= 24'hffffff;
            latched <= 24'hffffff;
            inputs_latched_reg <= 1'b0;
            addr_is_ffff_reg <= 1'b1;
            addr_is_sfg_io_reg <= 1'b0;
            addr_is_dos2_overlay_reg <= 1'b0;
        end else begin
            inputs_latched_reg <= 1'b0;

            case (scan_phase)
                // Select A[7:0], then allow one clock for the mux to settle.
                3'd0: begin
                    msel_reg <= 3'b110;
                    scan_phase <= 3'd1;
                end
                3'd1: begin
                    for (int i = 0; i < 8; i++) begin
                        case ({previous_sample[MP_A_LO + i], mp[i]})
                            2'b00: debounced[MP_A_LO + i] <= 1'b0;
                            2'b11: debounced[MP_A_LO + i] <= 1'b1;
                            default: debounced[MP_A_LO + i] <= debounced[MP_A_LO + i];
                        endcase
                        previous_sample[MP_A_LO + i] <= mp[i];
                    end
                    msel_reg <= 3'b101;
                    scan_phase <= 3'd2;
                end

                // Select and sample A[15:8].
                3'd2: begin
                    scan_phase <= 3'd3;
                end
                3'd3: begin
                    for (int i = 0; i < 8; i++) begin
                        case ({previous_sample[MP_A_HI + i], mp[i]})
                            2'b00: debounced[MP_A_HI + i] <= 1'b0;
                            2'b11: debounced[MP_A_HI + i] <= 1'b1;
                            default: debounced[MP_A_HI + i] <= debounced[MP_A_HI + i];
                        endcase
                        previous_sample[MP_A_HI + i] <= mp[i];
                    end
                    msel_reg <= 3'b011;
                    scan_phase <= 3'd4;
                end

                // Select and sample the control signals, then publish one
                // coherent snapshot at the end of the six-clock scan.
                3'd4: begin
                    scan_phase <= 3'd5;
                end
                default: begin
                    for (int i = 0; i < 8; i++) begin
                        case ({previous_sample[MP_CTRL + i], mp[i]})
                            2'b00: begin
                                debounced[MP_CTRL + i] <= 1'b0;
                                latched[MP_CTRL + i] <= 1'b0;
                            end
                            2'b11: begin
                                debounced[MP_CTRL + i] <= 1'b1;
                                latched[MP_CTRL + i] <= 1'b1;
                            end
                            default: begin
                                debounced[MP_CTRL + i] <= debounced[MP_CTRL + i];
                                latched[MP_CTRL + i] <= debounced[MP_CTRL + i];
                            end
                        endcase
                        previous_sample[MP_CTRL + i] <= mp[i];
                    end

                    latched[MP_A_LO +: 8] <= debounced[MP_A_LO +: 8];
                    latched[MP_A_HI +: 8] <= debounced[MP_A_HI +: 8];
                    addr_is_ffff_reg <= debounced_addr == 16'hffff;
                    addr_is_sfg_io_reg <= debounced_addr[15:1] == 15'h1ff8;
                    addr_is_dos2_overlay_reg <= debounced_addr >= 16'h7c00 &&
                                                debounced_addr <= 16'h7eff;
                    msel_reg <= 3'b110;
                    scan_phase <= 3'd0;
                    inputs_latched_reg <= 1'b1;
                end
            endcase
        end
    end

    assign msel_n = msel_reg;
    assign a_lo = latched[MP_A_LO +: 8];
    assign a_hi = latched[MP_A_HI +: 8];
    assign addr = {a_hi, a_lo};
    assign merq_n = latched[MP_MERQ_N];
    assign iorq_n = latched[MP_IORQ_N];
    assign cs1_n = latched[MP_CS1_N];
    assign cs2_n = latched[MP_CS2_N];
    assign reset_in_n = latched[MP_RESET_IN_N];
    assign rfsh_n = latched[MP_RFSH_N];
    assign cs12_n = latched[MP_CS12_N];
    assign m1_n = latched[MP_M1_N];
    assign inputs_latched = inputs_latched_reg;
    assign addr_is_ffff = addr_is_ffff_reg;
    assign addr_is_sfg_io = addr_is_sfg_io_reg;
    assign addr_is_dos2_overlay = addr_is_dos2_overlay_reg;

endmodule
