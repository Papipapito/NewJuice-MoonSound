// Simple SDRAM controller for Tang 20k
// nand2mario
// 
// 2023.3: ported to use GW2AR-18's embedded 64Mbit SDRAM.
//         changed to byte-based access.
// 2022.9: iniital version.
//
// This is a byte-based, low-latency and non-bursting controller for the embedded SDRAM
// on Tang Nano 20K. The SDRAM module is 64Mbit 32bit. (2K rows x 256 columns x 4 banks x 32 bits).
//
// Under default settings (max 66.7Mhz):
// - Data read latency is 4 cycles. 
// - Read/write operations take 5 cycles to complete. There's no overlap between
//   reads/writes.
// - All reads/writes are done with auto-precharge. So user does not need to deal with
//   row activations and precharges.
// - SDRAMs need periodic refreshes or they lose data. So they provide an "auto-refresh"
//   function to do one row of refresh. This "auto-refresh" operation is controlled with
//   the 'refresh' input. 4096 or more refreshes should happen in any 64ms for the memory
//   to not lose data. So the main circuit should invoke auto-refresh at least once 
//   **every ~15us**.
//
// Finally you need a 180-degree phase-shifted clock signal (clk_sdram) for SDRAM. 
// This can be generated with PLL's clkoutp output.
//

module sdram
#(
    // Timing defaults for the project's 108 MHz controller clock.
    parameter         FREQ = 108_000_000,
    parameter         DATA_WIDTH = 32,
    parameter         ROW_WIDTH = 11,  // 2K rows
    parameter         COL_WIDTH = 8,   // 256 words per row (1Kbytes)
    parameter         BANK_WIDTH = 2,  // 4 banks

    parameter [4:0]   CAS  = 5'd3,
    parameter [4:0]   T_WR = 5'd3,
    parameter [4:0]   T_MRD= 5'd2,
    parameter [4:0]   T_RP = 5'd2,
    parameter [4:0]   T_RCD= 5'd2,
    parameter [4:0]   T_RC = 5'd7
)
(
    // SDRAM side interface
    inout [DATA_WIDTH-1:0]      SDRAM_DQ,
    output [ROW_WIDTH-1:0]  SDRAM_A,
    output [BANK_WIDTH-1:0] SDRAM_BA,
    output            SDRAM_nCS,    // not strictly necessary, always 0
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_CLK,
    output            SDRAM_CKE,    // not strictly necessary, always 1
    output [3:0] SDRAM_DQM,
    
    // Logic side interface
    input             clk,
    input             clk_sdram,    // phase shifted from clk (normally 180-degrees)
    input             resetn,
    input             rd,           // command: read
    input             wr,           // command: write
    input             refresh,      // command: auto refresh. 4096 refresh cycles in 64ms. Once per 15us.
    input      [22:0] addr,         // byte address
    input       [15:0] din,          // data input
    input          [1:0] wdm,        // write data mask
    output      [15:0] dout,         // data output
    output [DATA_WIDTH-1:0] dout32, // 32-bit data output
    output            data_ready,   // available 6 cycles after wr is set
    output            busy,          // 0: ready for next command
    output            enabled,

    // V9990 fork: a second kind of access for the VRAM. One 32-bit word, or
    // two (v_dbl: col and col^1 of the same row, as tnCart's burst of two),
    // with a 4-bit mask per word. Issue v_rd / v_wr for one clock while
    // busy = 0 and rd = wr = 0; v_addr, v_dbl, v_din* and v_dqm* are taken
    // in that clock. A read gives its word(s) on dout32 while v_data_ready
    // is 1: one clock per word, with an idle clock between the two, so that
    // each word is followed by a released bus, like the CPU's single read.
    // The CPU port above is unchanged.
    input             v_rd,
    input             v_wr,
    input             v_dbl,
    input      [20:0] v_addr,       // word address: {bank, row, column}
    input      [31:0] v_din0,
    input      [3:0]  v_dqm0,       // 1 = byte not written
    input      [31:0] v_din1,
    input      [3:0]  v_dqm1,
    output            v_data_ready
);

// Tri-state DQ input/output
reg dq_oen;         // 0 means output
reg [DATA_WIDTH-1:0] dq_out;
assign SDRAM_DQ = dq_oen ? 32'bzzzz_zzzz_zzzz_zzzz_zzzz_zzzz_zzzz_zzzz : dq_out;
wire [DATA_WIDTH-1:0] dq_in = SDRAM_DQ;     // DQ input

reg off;          // byte offset
assign dout = off == 0 ? dq_in[15:0] : dq_in[31:16];
assign dout32 = dq_in;
assign SDRAM_CLK = clk_sdram;
assign SDRAM_CKE = 1'b1;
assign SDRAM_nCS = 1'b0;

reg [ROW_WIDTH-1:0]  FF_SDRAM_A;
reg [BANK_WIDTH-1:0] FF_SDRAM_BA;
reg        FF_SDRAM_nWE;
reg        FF_SDRAM_nRAS;
reg        FF_SDRAM_nCAS;
reg  [3:0] FF_SDRAM_DQM;
reg  ff_busy;
reg  ff_data_ready;
reg  ff_v_ready;
reg  v_dbl_q;
assign v_data_ready = ff_v_ready;
// operands of the V access, taken with the command: the access ends with
// what was accepted even if the client is reset in the middle
reg  [7:0]  v_col_q;
reg  [31:0] v_din0_q, v_din1_q;
reg  [3:0]  v_dqm0_q, v_dqm1_q;
wire [9:0] v_col0 = {2'b00, v_col_q};
wire [9:0] v_col1 = {2'b00, v_col_q[7:1], ~v_col_q[0]};

assign SDRAM_A = FF_SDRAM_A;
assign SDRAM_BA = FF_SDRAM_BA;
assign SDRAM_nWE = FF_SDRAM_nWE;
assign SDRAM_nRAS =FF_SDRAM_nRAS;
assign SDRAM_nCAS = FF_SDRAM_nCAS;
assign SDRAM_DQM = FF_SDRAM_DQM;
assign busy = ff_busy;
assign data_ready = ff_data_ready;

reg [2:0] state;
localparam INIT = 3'd0;
localparam CONFIG = 3'd1;
localparam IDLE = 3'd2;
localparam READ = 3'd3;
localparam WRITE = 3'd4;
localparam REFRESH = 3'd5;
localparam VREAD = 3'd6;
localparam VWRITE = 3'd7;

// RAS# CAS# WE#
localparam CMD_SetModeReg=3'b000;
localparam CMD_AutoRefresh=3'b001;
localparam CMD_PreCharge=3'b010;
localparam CMD_BankActivate=3'b011;
localparam CMD_Write=3'b100;
localparam CMD_Read=3'b101;
localparam CMD_NOP=3'b111;

localparam [2:0] BURST_LEN = 3'b0;      // burst length 1
localparam BURST_MODE = 1'b0;           // sequential
localparam [10:0] MODE_REG = {4'b0, CAS[2:0], BURST_MODE, BURST_LEN};

reg cfg_now;            // pulse for configuration
reg [4:0] cycle;

//
// SDRAM state machine
//
always @(posedge clk or negedge resetn) begin

    if (~resetn) begin
        ff_busy <= 1'b1;
        ff_data_ready <= 1'b0;
        ff_v_ready <= 1'b0;
        v_dbl_q <= 1'b0;
        v_col_q <= 8'd0;
        v_din0_q <= 32'd0; v_din1_q <= 32'd0;
        v_dqm0_q <= 4'b1111; v_dqm1_q <= 4'b1111;
        dq_oen <= 1'b1;         // turn off DQ output
        dq_out <= {DATA_WIDTH{1'b0}};
        off <= 1'b0;
        FF_SDRAM_DQM <= 4'b0;
        FF_SDRAM_A <= {ROW_WIDTH{1'b0}};
        FF_SDRAM_BA <= {BANK_WIDTH{1'b0}};
        {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_NOP;
        state <= INIT;
        cycle <= 5'd0;
    end else
    begin
        cycle <= cycle == 5'd31 ? 5'd31 : cycle + 5'd1;
        // defaults
        {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_NOP; 
        casex ({state, cycle})
            // wait 200 us on power-on
            {INIT, 5'bxxxxx} : if (cfg_now) begin
                state <= CONFIG;
                cycle <= 0;
            end

            // configuration sequence
            //  cycle  / 0 \___/ 1 \___/ 2 \___/ ... __/ 6 \___/ ...___/10 \___/11 \___/ 12\___
            //  cmd            |PC_All |Refresh|       |Refresh|       |  MRD  |       | _next_
            //                 '-T_RP--`----  T_RC  ---'----  T_RC  ---'------T_MRD----'
            {CONFIG, 5'd0} : begin
                // precharge all
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_PreCharge;
                FF_SDRAM_A[10] <= 1'b1;
            end
            {CONFIG, T_RP} : begin
                // 1st AutoRefresh
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_AutoRefresh;
            end
            {CONFIG, T_RP+T_RC} : begin
                // 2nd AutoRefresh
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_AutoRefresh;
            end
            {CONFIG, T_RP+T_RC+T_RC} : begin
                // set register
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_SetModeReg;
                FF_SDRAM_A[10:0] <= MODE_REG;
            end
            {CONFIG, T_RP+T_RC+T_RC+T_MRD} : begin
                state <= IDLE;
                ff_busy <= 1'b0;              // init&config is done
            end
            
            // read/write/refresh
            {IDLE, 5'bxxxxx}: if (rd | wr) begin
                // bank activate
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_BankActivate;
                FF_SDRAM_BA <= addr[ROW_WIDTH+COL_WIDTH+BANK_WIDTH-1+1 : ROW_WIDTH+COL_WIDTH+1];    // bank id
                FF_SDRAM_A <= addr[ROW_WIDTH+COL_WIDTH-1+1:COL_WIDTH+1];      // 12-bit row address
                state <= rd ? READ : WRITE;
                cycle <= 5'd1;
                ff_busy <= 1'b1;
            end else if (v_rd | v_wr) begin
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_BankActivate;
                FF_SDRAM_BA <= v_addr[20:19];
                FF_SDRAM_A <= v_addr[18:8];
                v_dbl_q <= v_dbl;
                v_col_q <= v_addr[7:0];
                v_din0_q <= v_din0; v_dqm0_q <= v_dqm0;
                v_din1_q <= v_din1; v_dqm1_q <= v_dqm1;
                state <= v_rd ? VREAD : VWRITE;
                cycle <= 5'd1;
                ff_busy <= 1'b1;
            end else if (refresh) begin
                // auto-refresh
                // no need for precharge-all b/c all our r/w are done with auto-precharge.
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_AutoRefresh;
                state <= REFRESH;
                cycle <= 5'd1;
                ff_busy <= 1'b1;
            end

            // read sequence
            //  cycle  / 0 \___/ 1 \___/ 2 \___/ 3 \___/ 4 \___/ 5 \___
            //  rd     /       \_______________________________
            //  cmd            |Active | Read  |  NOP  |  NOP  | _Next_
            //  DQ                                     |  Dout |
            //  ff_data_ready ____________________________/       \_______   
            //  ff_busy   ________/                               \_______
            //                 `-T_RCD-'------CAS------'
            {READ, T_RCD}: begin
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_Read;
                FF_SDRAM_A[10] <= 1'b1;        // set auto precharge
                FF_SDRAM_A[9:0] <= {1'b0, addr[COL_WIDTH-1+1:1]};  // column address
                FF_SDRAM_DQM <= 4'b0;
                off <= addr[0];
            end
            {READ, T_RCD+CAS}: begin
                ff_data_ready <= 1'b1;
            end
            {READ, T_RCD+CAS+5'd1}: begin
                ff_data_ready <= 1'b0;
                ff_busy <= 0;
                state <= IDLE;
            end

            // write sequence
            //  cycle / 0 \___/ 1 \___/ 2 \___/ 3 \___/ 4 \___/ 5 \___
            //  wr    /       \_______________________________
            //  cmd           |Active | Write |  NOP  |  NOP  | _Next_
            //  DQ                    | Din   |
            //  ff_busy   _______/                               \_______
            //                `-T_RCD-'-------T_WR+T_RP-------'
            {WRITE, T_RCD}: begin
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_Write;
                FF_SDRAM_A[10] <= 1'b1;        // set auto precharge
                FF_SDRAM_A[9:0] <= {1'b0, addr[COL_WIDTH-1+1:1]};  // column address
                FF_SDRAM_DQM <= addr[0] == 1'd0 ? { 2'b11, wdm } : { wdm, 2'b11 } ;     // only write the correct byte
                off <= addr[0];
                dq_out <= {din,din};
                dq_oen <= 1'b0;                 // DQ output on
            end
            {WRITE, T_RCD+5'd1}: begin
                dq_oen <= 1'b1;
            end
            {WRITE, T_RCD+T_WR+T_RP}: begin  // 2+2+1
                ff_busy <= 0;
                state <= IDLE;
            end

            // V9990 read: READ col, then (v_dbl) two clocks later READ col^1;
            // auto precharge on the last one. The first word is on DQ at
            // T_RCD+CAS and the second two clocks later.
            {VREAD, T_RCD}: begin
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_Read;
                FF_SDRAM_A[10] <= ~v_dbl_q;
                FF_SDRAM_A[9:0] <= v_col0;
                FF_SDRAM_DQM <= 4'b0;
            end
            {VREAD, T_RCD+5'd2}: if (v_dbl_q) begin
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_Read;
                FF_SDRAM_A[10] <= 1'b1;
                FF_SDRAM_A[9:0] <= v_col1;
            end
            {VREAD, T_RCD+CAS}: begin
                ff_v_ready <= 1'b1;
            end
            {VREAD, T_RCD+CAS+5'd1}: begin
                ff_v_ready <= 1'b0;
                if (!v_dbl_q) begin
                    ff_busy <= 0;
                    state <= IDLE;
                end
            end
            {VREAD, T_RCD+CAS+5'd2}: begin
                ff_v_ready <= 1'b1;
            end
            {VREAD, T_RCD+CAS+5'd3}: begin
                ff_v_ready <= 1'b0;
                ff_busy <= 0;
                state <= IDLE;
            end

            // V9990 write: WRITE col, then (v_dbl) WRITE col^1; auto
            // precharge on the last one.
            {VWRITE, T_RCD}: begin
                {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_Write;
                FF_SDRAM_A[10] <= ~v_dbl_q;
                FF_SDRAM_A[9:0] <= v_col0;
                FF_SDRAM_DQM <= v_dqm0_q;
                dq_out <= v_din0_q;
                dq_oen <= 1'b0;
            end
            {VWRITE, T_RCD+5'd1}: begin
                if (v_dbl_q) begin
                    {FF_SDRAM_nRAS, FF_SDRAM_nCAS, FF_SDRAM_nWE} <= CMD_Write;
                    FF_SDRAM_A[10] <= 1'b1;
                    FF_SDRAM_A[9:0] <= v_col1;
                    FF_SDRAM_DQM <= v_dqm1_q;
                    dq_out <= v_din1_q;
                end else
                    dq_oen <= 1'b1;
            end
            {VWRITE, T_RCD+5'd2}: begin
                dq_oen <= 1'b1;
            end
            {VWRITE, T_RCD+T_WR+T_RP}: if (!v_dbl_q) begin
                ff_busy <= 0;
                state <= IDLE;
            end
            {VWRITE, T_RCD+T_WR+T_RP+5'd1}: begin
                ff_busy <= 0;
                state <= IDLE;
            end

            // refresh sequence
            //  cycle   / 0 \___/ 1 \___/ 2 \___/ 3 \___/ 4 \___/ 5 \___
            //  refresh /       \_______________________________
            //  cmd             |Refresh|  NOP  |  NOP  |  NOP  | _Next_
            //  ff_busy     _______/                               \_______
            //                  `------------- T_RC ------------'
            {REFRESH, T_RC}: begin
                state <= IDLE;
                ff_busy <= 0;
            end
        endcase
    end
end


//
// Generate cfg_now pulse after initialization delay (normally 200us)
//
reg  [14:0]   rst_cnt;
reg rst_done, rst_done_p1, cfg_busy;
assign enabled = rst_done && (state != INIT) && (state != CONFIG);

always @(posedge clk or negedge resetn) begin
    if (~resetn) begin
        rst_cnt  <= 15'd0;
        rst_done <= 1'b0;
        rst_done_p1 <= 1'b0;
        cfg_now <= 1'b0;
        cfg_busy <= 1'b1;
    end else
    begin
        rst_done_p1 <= rst_done;
        cfg_now     <= rst_done & ~rst_done_p1;// Rising Edge Detect

        if (rst_cnt != FREQ / 1000 * 200 / 1000) begin      // count to 200 us
            rst_cnt  <= rst_cnt[14:0] + 1;
            rst_done <= 1'b0;
            cfg_busy <= 1'b1;
        end else begin
            rst_done <= 1'b1;
            cfg_busy <= 1'b0;
        end
    end
end

endmodule
