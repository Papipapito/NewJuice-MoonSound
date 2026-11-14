// ============================================================================
// tb_varb.v - New Juice V9990 fork: el arbitro nj_v9990_arb con la cadena REAL.
//
//   Z80 sintetico -> cliente CPU -> sdram_command_adapter (New Juice)  = cliente A
//   modelo del core (protocolo de T9990_RAM de tiny9990)               = cliente V
//   ambos -> nj_v9990_arb -> sdram.v (New Juice + puerto V) -> modelo de SDRAM
//
// Cliente V: EXEC = v_timing retrasado un ciclo; en cada ranura, con
//   probabilidad LOAD, una operacion al azar (lectura / escritura / RFSH) de
//   tamano 8, 16, 32, 32_E o 32_O. Estados WAIT_REQ / WAIT_ACK / WAIT_BUSY de
//   T9990_RAM. Un EXEC con el estado != WAIT_REQ es una ranura perdida.
//   La semantica de datos (que bytes se escriben, que devuelve DOUT) sale del
//   controlador de tnCart (V9990TANG/fpga/src/peripheral/ram/sdram.sv), no del
//   RTL del arbitro: memoria sombra de la VRAM a nivel de byte, nacida a X.
//   La VRAM vive en los bytes 0x780000-0x7FFFFF de la SDRAM (palabras
//   0x1E0000-0x1FFFFF).
// Cliente A: Z80 sintetico como en tb_arb.v, direcciones < 0x700000, memoria
//   sombra de palabras.
//
// MODE 0: trafico (mide latencias, ph, refrescos).
// MODE 1: la CPU se PARA STOP_MS ms (sin RFSH): el refresco propio mantiene la
//         retencion; despues la CPU barre su pool.
// Controles negativos: NEG (sin refresco propio; el modelo TIENE que dar filas
//   caducadas), NEGV (un bit de v_dout), NEGA (un bit de la lectura de A),
//   NEGM (se corrompe la SDRAM antes de la comparacion final), ACK_DLY (el
//   core ve el ACK tarde: tiene que haber ranuras perdidas).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_varb;
    parameter integer MODE     = 0;
    parameter integer LOAD     = 100;        // % de ranuras de V con operacion
    parameter integer NEG      = 0;          // 1 = refresco propio desactivado
    parameter integer NOREFV   = 0;          // 1 = V no emite RFSH
    parameter integer NEGV     = 0;
    parameter integer NEGA     = 0;
    parameter integer NEGM     = 0;          // bit0: corromper VRAM, bit1: corromper pool de A
    parameter integer ACK_DLY  = 0;
    parameter integer CPU_ON   = 1;
    parameter integer NORFSH   = 0;          // 1 = el Z80 no da RFSH (el refresco propio convive con trafico de CPU)
    parameter integer PATTERN  = 0;          // 0 = M1,MR,MW  1 = M1,MR,MR
    parameter integer SEED     = 1;
    parameter real    TZ       = 279.365;
    parameter real    FE_NS    = 120.0;
    parameter integer MEAS_US  = 6000;
    parameter integer STOP_MS  = 70;

    reg clk = 1'b0;
    always #4.6296 clk = ~clk;               // 108 MHz
    wire clk_sdram = ~clk;
    reg por_n = 1'b0;

    // ------------------------------------------------------------------
    //  SDRAM: modelo + controlador de New Juice (con el puerto V)
    // ------------------------------------------------------------------
    wire [31:0] sd_dq; wire [10:0] sd_a; wire [1:0] sd_ba; wire [3:0] sd_dqm;
    wire sd_ncs, sd_nwe, sd_nras, sd_ncas, sd_clk, sd_cke;
    sdram_model #(.RET_CHECK(1)) mdl (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_ncs), .ras_n(sd_nras),
        .cas_n(sd_ncas), .we_n(sd_nwe), .addr(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq));

    wire        a_rd, a_wr, a_ref; wire [22:0] a_addr; wire [15:0] a_din; wire [1:0] a_wdm;
    wire        a_busy, aux_cap, own_ref;
    wire        s_ref, s_v_rd, s_v_wr, s_v_dbl; wire [20:0] s_v_addr;
    wire [31:0] s_v_din0, s_v_din1; wire [3:0] s_v_dqm0, s_v_dqm1;
    wire [31:0] s_dout32; wire s_dr, s_busy, s_en, s_vdr;
    sdram #(.FREQ(108_000_000), .CAS(5'd3), .T_WR(5'd3), .T_MRD(5'd2), .T_RP(5'd2), .T_RCD(5'd2), .T_RC(5'd7)) u_sd (
        .SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_nCS(sd_ncs), .SDRAM_nWE(sd_nwe),
        .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_CLK(sd_clk), .SDRAM_CKE(sd_cke), .SDRAM_DQM(sd_dqm),
        .clk(clk), .clk_sdram(clk_sdram), .resetn(por_n),
        .rd(a_rd), .wr(a_wr), .refresh(s_ref), .addr(a_addr), .din(a_din), .wdm(a_wdm),
        .dout(), .dout32(s_dout32), .data_ready(s_dr), .busy(s_busy), .enabled(s_en),
        .v_rd(s_v_rd), .v_wr(s_v_wr), .v_dbl(s_v_dbl), .v_addr(s_v_addr),
        .v_din0(s_v_din0), .v_dqm0(s_v_dqm0), .v_din1(s_v_din1), .v_dqm1(s_v_dqm1), .v_data_ready(s_vdr));

    // ------------------------------------------------------------------
    //  Cliente A: el adaptador real
    // ------------------------------------------------------------------
    reg rfsh_n = 1, m1_n = 1, mreq_n = 1, rd_n_b = 1, wr_n_b = 1;
    reg z_rfsh = 1, z_m1 = 1, z_mreq = 1, z_rd = 1, z_wr = 1;
    reg cmd_en = 0; reg [2:0] cmd = 3'b101; reg [20:0] cmd_addr = 0; reg [3:0] cmd_dqm = 4'b1110; reg [31:0] cmd_data = 0;
    wire [31:0] a_rdata; wire a_init, a_ack;
    sdram_command_adapter u_ad (
        .clk(clk), .reset_n(por_n), .debug_wait_n(1'b1),
        .rfsh_n(rfsh_n), .m1_n(m1_n), .merq_n(mreq_n), .iorq_n(1'b1), .rd_n(rd_n_b), .wr_n(wr_n_b),
        .cmd_en(cmd_en), .cmd(cmd), .cmd_addr(cmd_addr), .cmd_dqm(cmd_dqm), .cmd_data(cmd_data),
        .read_data(a_rdata), .init_done(a_init), .cmd_ack(a_ack),
        .rd(a_rd), .wr(a_wr), .refresh(a_ref), .addr(a_addr), .din(a_din), .wdm(a_wdm),
        .dout32(s_dout32), .data_ready(s_dr), .busy(a_busy), .enabled(s_en),
        .ctrl_busy(s_busy), .aux_capture(aux_cap));

    // pines crudos /SLTSL y /RD (cada ciclo de memoria sintetico es de este cartucho)
    wire pin_sltsl_n, pin_rd_n;
    assign #15 pin_sltsl_n = z_mreq | ~z_rfsh;
    assign #15 pin_rd_n    = z_rd;

    // ------------------------------------------------------------------
    //  El arbitro y el core
    // ------------------------------------------------------------------
    wire        v_timing, clk21m_en, clk14m_en, clk25m_en;
    wire [31:0] v_dout_arb; wire v_ack_n_arb;
    reg         r_oe_n = 1, r_we_n = 1, r_rfsh_n = 1;
    reg  [18:0] r_addr = 19'd0;
    reg  [31:0] r_din = 32'd0;
    reg  [2:0]  r_size = 3'b010;
    nj_v9990_arb #(.REFRESH_CYCLES(NEG ? 2047 : 842), .URGENT_CYCLES(NEG ? 2047 : 1350)) u_arb (
        .clk(clk), .rst_n(por_n),
        .a_rd(a_rd), .a_wr(a_wr), .a_refresh(a_ref), .a_busy(a_busy),
        .cpu_sltsl_n(pin_sltsl_n), .cpu_rd_n(pin_rd_n),
        .v_en(s_en), .v_timing(v_timing), .clk21m_en(clk21m_en), .clk14m_en(clk14m_en), .clk25m_en(clk25m_en),
        .v_oe_n(r_oe_n), .v_we_n(r_we_n), .v_rfsh_n(r_rfsh_n), .v_addr(r_addr), .v_din(r_din),
        .v_din_size(r_size), .v_dout(v_dout_arb), .v_ack_n(v_ack_n_arb),
        .s_refresh(s_ref), .s_v_rd(s_v_rd), .s_v_wr(s_v_wr), .s_v_dbl(s_v_dbl), .s_v_addr(s_v_addr),
        .s_v_din0(s_v_din0), .s_v_dqm0(s_v_dqm0), .s_v_din1(s_v_din1), .s_v_dqm1(s_v_dqm1),
        .s_busy(s_busy), .s_v_data_ready(s_vdr),
        .aux_capture(aux_cap), .rd_q(a_rdata), .own_refresh(own_ref));
    // control negativo: sin refresco propio (el contador se queda en 0)
    initial if (NEG) begin
        #1; force u_arb.r_cnt = 11'd0;
    end

    // ------------------------------------------------------------------
    //  Contenido inicial: palabra de la CPU = pat(w); la VRAM nace a X
    // ------------------------------------------------------------------
    function [31:0] pat(input [20:0] w);
        pat = ({11'd0, w} * 32'h9E3779B1) ^ 32'h5A5A00FF;
    endfunction
    // pool de la CPU: 2048 palabras en la zona del mapper y 2048 en la de MegaRAM
    reg [31:0] shadow [0:4095];
    function [20:0] pool_addr(input [11:0] i);
        pool_addr = i[11] ? (21'h100000 + {i[10:0], 8'h00} + {10'd0, i[10:0]} % 21'd251)
                          : (21'h000000 + {i[10:0], 8'h00} + {10'd0, i[10:0]} % 21'd241);
    endfunction

    // generador pseudoaleatorio (xorshift32), determinista
    reg [31:0] rs;
    function [31:0] rnd32(input integer dummy);
        begin
            rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5);
            rnd32 = rs;
        end
    endfunction

    reg [18:0] hot [0:255];
    function [18:0] edge_addr(input integer i);
        case (i)
            0: edge_addr = 19'h00000;  1: edge_addr = 19'h7FFFC;  2: edge_addr = 19'h7FFFF;
            3: edge_addr = 19'h003FC;  4: edge_addr = 19'h003FF;  5: edge_addr = 19'h00400;
            6: edge_addr = 19'h00004;  7: edge_addr = 19'h7FC00;  8: edge_addr = 19'h7FBFC;
            9: edge_addr = 19'h00014; 10: edge_addr = 19'h001FC; 11: edge_addr = 19'h7FFF8;
           12: edge_addr = 19'h00001; 13: edge_addr = 19'h7FFFE; 14: edge_addr = 19'h00007;
           default: edge_addr = 19'h20004;
        endcase
    endfunction

    integer k;
    reg [31:0] tmp32;
    initial begin
        rs = 32'h2545F491 ^ (SEED * 32'h9E3779B1);
        for (k = 0; k < 4096; k = k + 1) shadow[k] = pat(pool_addr(k[11:0]));
        for (k = 0; k < 256; k = k + 1) begin
            tmp32 = rnd32(0);
            if (k % 4 == 0) hot[k] = edge_addr(k / 4 % 16) ^ {17'd0, tmp32[1:0]};
            else            hot[k] = tmp32[31:13];
        end
        for (k = 0; k < 32'h1E0000; k = k + 1) mdl.mem[k] = pat(k[20:0]);
    end

    // ------------------------------------------------------------------
    //  Z80 sintetico (pines en tiempo real, vistos FE_NS despues en main_clk)
    // ------------------------------------------------------------------
    reg cpu_run = 1'b0;
    reg d_rfsh = 1, d_m1 = 1, d_mreq = 1, d_rd = 1, d_wr = 1;
    always @(z_rfsh) d_rfsh <= #(FE_NS) z_rfsh;
    always @(z_m1)   d_m1   <= #(FE_NS) z_m1;
    always @(z_mreq) d_mreq <= #(FE_NS) z_mreq;
    always @(z_rd)   d_rd   <= #(FE_NS) z_rd;
    always @(z_wr)   d_wr   <= #(FE_NS) z_wr;
    always @(posedge clk) begin
        rfsh_n <= d_rfsh; m1_n <= d_m1; mreq_n <= d_mreq; rd_n_b <= d_rd; wr_n_b <= d_wr;
    end
    task m1cyc; begin    // T1 T2 TW T3 T4 (el MSX anade una espera en M1)
        z_m1 = 0;
        #(0.5*TZ) begin z_mreq = 0; z_rd = 0; end
        #(2.5*TZ) begin z_mreq = 1; z_rd = 1; z_m1 = 1; z_rfsh = (NORFSH != 0); end
        #(0.5*TZ) z_mreq = 0;
        #(1.0*TZ) z_mreq = 1;
        #(0.5*TZ) z_rfsh = 1;
    end endtask
    task mrcyc; begin
        #(0.5*TZ) begin z_mreq = 0; z_rd = 0; end
        #(2.0*TZ) begin z_mreq = 1; z_rd = 1; end
        #(0.5*TZ);
    end endtask
    task mwcyc; begin
        #(0.5*TZ) z_mreq = 0;
        #(1.0*TZ) z_wr = 0;
        #(1.0*TZ) begin z_mreq = 1; z_wr = 1; end
        #(0.5*TZ);
    end endtask
    initial begin
        wait (cpu_run);
        forever begin
            if (!cpu_run) wait (cpu_run);
            m1cyc;
            if (PATTERN == 0) begin mrcyc; mwcyc; end
            else if (PATTERN == 1) begin mrcyc; mrcyc; end
        end
    end

    // ------------------------------------------------------------------
    //  Cliente de CPU (una orden por ciclo de memoria) + comprobaciones de A
    // ------------------------------------------------------------------
    reg seen = 1'b0, waiting = 1'b0, is_rd = 1'b0;
    reg [11:0] cur_i = 12'd0;
    reg [20:0] cur_w = 21'd0;
    reg [31:0] cur_d = 32'd0;
    reg [1:0]  cur_lane = 2'd0;
    integer n_drop = 0, n_bad_a = 0, n_chk_a = 0, n_xa = 0, n_wcpu = 0;
    reg [11:0] lfsr = 12'hACE;
    reg [31:0] dlfsr = 32'h12345678;
    reg meas = 1'b0;
    reg force_rd = 1'b0;
    reg [11:0] sweep_i = 12'd0;
    reg sweep = 1'b0;
    integer lat_c = 0;
    integer rl_n = 0, rl_sum = 0, rl_max = 0, rl_min = 1<<30;
    integer wl_n = 0, wl_sum = 0, wl_max = 0, wl_min = 1<<30;
    wire [31:0] a_rdata_chk = a_rdata ^ ((NEGA != 0) ? 32'h1 : 32'h0);

    always @(posedge clk) if (cmd_en && (u_ad.request_queued || u_ad.command_pending)) n_drop = n_drop + 1;

    always @(posedge clk) begin
        cmd_en <= 1'b0;
        if (mreq_n) seen <= 1'b0;
        if (cpu_run && !mreq_n && rfsh_n && (!rd_n_b || !wr_n_b) && !seen && a_init) begin
            seen <= 1'b1; cmd_en <= 1'b1;
            is_rd <= !rd_n_b || force_rd;
            cmd <= (!rd_n_b || force_rd) ? 3'b101 : 3'b100;
            lfsr <= {lfsr[10:0], lfsr[11] ^ lfsr[10] ^ lfsr[9] ^ lfsr[3]};
            dlfsr <= {dlfsr[30:0], dlfsr[31] ^ dlfsr[21] ^ dlfsr[1] ^ dlfsr[0]};
            cur_i <= sweep ? sweep_i : lfsr;
            if (sweep) sweep_i <= sweep_i + 12'd1;
            cur_w <= pool_addr(sweep ? sweep_i : lfsr);
            cmd_addr <= pool_addr(sweep ? sweep_i : lfsr);
            cur_lane <= lfsr[1:0];
            cmd_dqm <= ~(4'b0001 << lfsr[1:0]);
            cmd_data <= {4{dlfsr[7:0]}};
            cur_d <= {4{dlfsr[7:0]}};
            waiting <= 1'b1; lat_c <= 0;
        end else if (waiting) begin
            lat_c <= lat_c + 1;
            if (a_ack) begin
                waiting <= 1'b0;
                if (is_rd) begin
                    n_chk_a = n_chk_a + 1;
                    if (^a_rdata === 1'bx) n_xa = n_xa + 1;
                    if (a_rdata_chk !== shadow[cur_i]) begin
                        n_bad_a = n_bad_a + 1;
                        if (n_bad_a <= 5) $display("  BAD_A t=%0t word=%h got=%h exp=%h", $time, cur_w, a_rdata_chk, shadow[cur_i]);
                    end
                end else begin
                    n_wcpu = n_wcpu + 1;
                    shadow[cur_i][8*cur_lane +: 8] = cur_d[7:0];
                end
                if (meas) begin
                    if (is_rd) begin
                        rl_n = rl_n + 1; rl_sum = rl_sum + lat_c + 1;
                        if (lat_c + 1 > rl_max) rl_max = lat_c + 1;
                        if (lat_c + 1 < rl_min) rl_min = lat_c + 1;
                    end else begin
                        wl_n = wl_n + 1; wl_sum = wl_sum + lat_c + 1;
                        if (lat_c + 1 > wl_max) wl_max = lat_c + 1;
                        if (lat_c + 1 < wl_min) wl_min = lat_c + 1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    //  Memoria sombra de la VRAM (por bytes, nace a X) y su semantica (tnCart)
    // ------------------------------------------------------------------
    reg [7:0] vsh [0:524287];
    reg [18:0] last_vw_byte = 19'd0;
    reg        any_vw = 1'b0;

    // que bytes escribe cada tamano (sdram.sv de tnCart, STATE_SETUP_WDATA_1/2)
    task v_shadow_write(input [18:0] a, input [31:0] d, input [2:0] sz);
        reg [18:0] b0, b1;
        begin
            b0 = {a[18:2], 2'b00};
            b1 = {a[18:3], ~a[2], 2'b00};
            case (sz)
                3'b000: begin vsh[b0 + a[1:0]] = d[7:0]; last_vw_byte = b0 + a[1:0]; end
                3'b001: begin
                    vsh[b0 + {a[1], 1'b0}] = d[7:0]; vsh[b0 + {a[1], 1'b1}] = d[15:8];
                    last_vw_byte = b0 + {a[1], 1'b0};
                end
                3'b010: begin
                    vsh[b0] = d[7:0]; vsh[b0 + 1] = d[15:8]; vsh[b0 + 2] = d[23:16]; vsh[b0 + 3] = d[31:24];
                    last_vw_byte = b0;
                end
                3'b011: begin   // 32_E: bytes 0 y 2 de la palabra col y de la col^1
                    vsh[b0] = d[7:0];   vsh[b0 + 2] = d[15:8];
                    vsh[b1] = d[23:16]; vsh[b1 + 2] = d[31:24];
                    last_vw_byte = b0;
                end
                default: begin  // 32_O: bytes 1 y 3
                    vsh[b0 + 1] = d[7:0];   vsh[b0 + 3] = d[15:8];
                    vsh[b1 + 1] = d[23:16]; vsh[b1 + 3] = d[31:24];
                    last_vw_byte = b0 + 1;
                end
            endcase
            any_vw = 1'b1;
        end
    endtask

    // que devuelve DOUT (sdram.sv de tnCart, STATE_FETCH_RDATA_1/2); m[j] = 0 si
    // el byte j depende de un byte de la VRAM aun sin escribir (X)
    task v_expect(input [18:0] a, input [2:0] sz, output [31:0] e, output [3:0] m);
        reg [18:0] b0, b1;
        reg [7:0]  t;
        integer j;
        begin
            b0 = {a[18:2], 2'b00};
            b1 = {a[18:3], ~a[2], 2'b00};
            e = 32'd0; m = 4'b1111;
            for (j = 0; j < 4; j = j + 1) begin
                if (sz == 3'b011)
                    t = (j == 0) ? vsh[b0] : (j == 1) ? vsh[b0 + 2] : (j == 2) ? vsh[b1] : vsh[b1 + 2];
                else if (sz == 3'b111)
                    t = (j == 0) ? vsh[b0 + 1] : (j == 1) ? vsh[b0 + 3] : (j == 2) ? vsh[b1 + 1] : vsh[b1 + 3];
                else if (j + a[1:0] <= 3)
                    t = vsh[b0 + a[1:0] + j];
                else
                    t = 8'h00;
                e[8*j +: 8] = t;
                if (^t === 1'bx) m[j] = 1'b0;
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  Modelo del core: T9990_RAM (WAIT_REQ / WAIT_ACK / WAIT_BUSY)
    // ------------------------------------------------------------------
    localparam [1:0] ST_REQ = 2'd0, ST_ACK = 2'd1, ST_BUSY = 2'd2;
    function [2:0] sz_of(input integer i);
        case (i) 0: sz_of = 3'b000; 1: sz_of = 3'b001; 2: sz_of = 3'b010; 3: sz_of = 3'b011; default: sz_of = 3'b111; endcase
    endfunction

    reg        core_run = 1'b0;
    reg        exec_q = 1'b0;
    reg [1:0]  cst = ST_REQ;
    reg [31:0] cap = 32'd0;
    reg [15:0] ack_sr = 16'hFFFF;
    always @(posedge clk) ack_sr <= {ack_sr[14:0], v_ack_n_arb};
    wire       ack_n_core  = (ACK_DLY == 0) ? v_ack_n_arb : ack_sr[ACK_DLY - 1];
    wire [31:0] dout_core  = v_dout_arb ^ ((NEGV != 0) ? 32'h1 : 32'h0);

    // ph: ciclos desde v_timing (el v_timing visible es el ph 0; kc el del RTL)
    reg [7:0] kc = 8'd255;
    always @(posedge clk) kc <= v_timing ? 8'd1 : (kc == 8'd255 ? 8'd255 : kc + 8'd1);

    integer n_lost = 0, n_slots = 0, n_vops = 0, n_chk_v = 0, n_bad_v = 0, n_xv = 0, n_lanes_v = 0;
    integer n_idle = 0;
    integer cnt_kind [0:10];
    integer maxph [0:65];        // [culpa*11 + clase]
    integer cntph [0:65];
    integer ph_hist [0:31];
    integer worst_ph = 0, worst_cul = 0, worst_kind = 0;
    integer cur_kind = 0, cur_op = 0, cul_cur = 0;
    reg [31:0] exp_v = 32'd0; reg [3:0] exp_m = 4'd0;
    reg [18:0] cur_a = 19'd0; reg [2:0] cur_sz = 3'd0;
    integer ii;
    initial begin
        for (ii = 0; ii < 11; ii = ii + 1) cnt_kind[ii] = 0;
        for (ii = 0; ii < 66; ii = ii + 1) begin maxph[ii] = 0; cntph[ii] = 0; end
        for (ii = 0; ii < 32; ii = ii + 1) ph_hist[ii] = 0;
    end

    always @(posedge clk or negedge por_n) begin : core
        reg        pick;
        integer    o, szi, sel, phn, j;
        reg [18:0] a;
        reg [31:0] d;
        reg [2:0]  sz;
        reg [31:0] r1, r2;
        if (!por_n) begin
            cst <= ST_REQ; exec_q <= 1'b0;
            r_oe_n <= 1'b1; r_we_n <= 1'b1; r_rfsh_n <= 1'b1;
            r_addr <= 19'd0; r_din <= 32'd0; r_size <= 3'b010;
        end else begin
            exec_q <= v_timing;
            phn = v_timing ? 1 : kc + 1;
            if (exec_q && cst != ST_REQ) begin
                n_lost = n_lost + 1;
                if (n_lost <= 5) $display("  RANURA PERDIDA t=%0t: EXEC con estado=%0d (ph=%0d)", $time, cst, phn);
            end
            case (cst)
            ST_REQ: begin
                if (exec_q) begin
                    n_slots = n_slots + 1;
                    pick = core_run && (((rnd32(0) >> 8) % 100) < LOAD);
                    // direccion: 40 % del conjunto caliente, 15 % de casos de borde, 45 % al azar
                    sel = (rnd32(0) >> 8) % 100;
                    r1 = rnd32(0); r2 = rnd32(0);
                    if (sel < 40)      a = {hot[(r1 >> 8) % 256][18:2], r2[1:0]};
                    else if (sel < 55) a = edge_addr((r1 >> 8) % 16) ^ {17'd0, r2[1:0]};
                    else               a = r2[31:13];
                    d  = rnd32(0);
                    szi = (rnd32(0) >> 8) % 5;
                    sz = sz_of(szi);
                    o = (rnd32(0) >> 8) % 100;
                    if (NOREFV != 0) o = (o < 50) ? 0 : 50;       // solo lectura (0) / escritura (50)
                    r_addr <= a; r_din <= d; r_size <= sz;
                    if (pick) begin
                        n_vops = n_vops + 1;
                        cst <= ST_ACK;
                        cul_cur = 0;
                        cur_a = a; cur_sz = sz;
                        if (o < 45) begin                                       // lectura
                            cur_op = 0; cur_kind = szi;
                            r_oe_n <= 1'b0; r_we_n <= 1'b1; r_rfsh_n <= 1'b1;
                            v_expect(a, sz, exp_v, exp_m);
                        end else if (o < 90) begin                              // escritura
                            cur_op = 1; cur_kind = 5 + szi;
                            r_oe_n <= 1'b1; r_we_n <= 1'b0; r_rfsh_n <= 1'b1;
                            v_shadow_write(a, d, sz);
                        end else begin                                          // RFSH
                            cur_op = 2; cur_kind = 10;
                            r_oe_n <= 1'b1; r_we_n <= 1'b1; r_rfsh_n <= 1'b0;
                        end
                        cnt_kind[cur_kind] = cnt_kind[cur_kind] + 1;
                    end else begin
                        n_idle = n_idle + 1;
                        r_oe_n <= 1'b1; r_we_n <= 1'b1; r_rfsh_n <= 1'b1;
                    end
                end else begin
                    r_oe_n <= 1'b1; r_we_n <= 1'b1; r_rfsh_n <= 1'b1;
                end
            end
            ST_ACK: if (!ack_n_core) begin
                cst <= ST_BUSY;
                r_oe_n <= 1'b1; r_we_n <= 1'b1; r_rfsh_n <= 1'b1;
            end
            ST_BUSY: if (ack_n_core) begin
                cst <= ST_REQ;
                r_oe_n <= 1'b1; r_we_n <= 1'b1; r_rfsh_n <= 1'b1;
                cap <= dout_core;
                // el peor ph en que el core vuelve a WAIT_REQ y con que combinacion
                ph_hist[phn > 31 ? 31 : phn] = ph_hist[phn > 31 ? 31 : phn] + 1;
                cntph[cul_cur*11 + cur_kind] = cntph[cul_cur*11 + cur_kind] + 1;
                if (phn > maxph[cul_cur*11 + cur_kind]) maxph[cul_cur*11 + cur_kind] = phn;
                if (phn > worst_ph) begin worst_ph = phn; worst_cul = cul_cur; worst_kind = cur_kind; end
                if (cur_op == 0) begin
                    n_chk_v = n_chk_v + 1;
                    n_lanes_v = n_lanes_v + exp_m[0] + exp_m[1] + exp_m[2] + exp_m[3];
                    for (j = 0; j < 4; j = j + 1)
                        if (exp_m[j] && dout_core[8*j +: 8] !== exp_v[8*j +: 8]) begin
                            if (j == 0 || !(exp_m[j-1] && dout_core[8*(j-1) +: 8] !== exp_v[8*(j-1) +: 8])) begin
                                n_bad_v = n_bad_v + 1;
                                if (n_bad_v <= 8)
                                    $display("  BAD_V t=%0t addr=%h size=%b lane=%0d got=%h exp=%h mask=%b", $time, cur_a, cur_sz, j, dout_core, exp_v, exp_m);
                            end
                        end
                    if (^dout_core === 1'bx) n_xv = n_xv + 1;
                end
            end
            default: cst <= ST_REQ;
            endcase
        end
    end

    // que operacion de A (o refresco propio) se colo delante de V
    integer cyc = 0, a_last_t = -100, a_last_type = 0;
    integer n_aref = 0, n_own = 0, n_aops = 0, n_vtake = 0;
    always @(posedge clk) begin : culprit
        integer phi;
        cyc = cyc + 1;
        phi = v_timing ? 0 : kc;
        if (a_rd)    begin a_last_t = cyc; a_last_type = 1; n_aops = n_aops + 1; end
        if (a_wr)    begin a_last_t = cyc; a_last_type = 2; n_aops = n_aops + 1; end
        if (a_ref)   begin a_last_t = cyc; a_last_type = 3; n_aref = n_aref + 1; end
        if (own_ref) begin a_last_t = cyc; a_last_type = 4; n_own = n_own + 1; end
        if (s_v_rd || s_v_wr) begin
            n_vtake = n_vtake + 1;
            if (phi > 2) cul_cur = (cyc - a_last_t <= 12) ? a_last_type : 5;
            else         cul_cur = 0;
        end
    end

    // ------------------------------------------------------------------
    //  Habilitaciones y v_timing
    // ------------------------------------------------------------------
    reg [29:0] h21 = 30'd0, h14 = 30'd0, h25 = 30'd0;
    integer n21 = 0, n14 = 0, n25 = 0, t21, t14, t25;
    integer ecyc = 0, bad_en21 = 0, bad_en14 = 0, bad_en25 = 0, bad_vt = 0, bad_vt21 = 0, n_vt = 0, last_vt = -1;
    integer vt_period = 0;
    always @(posedge clk) if (por_n) begin
        ecyc <= ecyc + 1;
        h21 <= {h21[28:0], clk21m_en}; h14 <= {h14[28:0], clk14m_en}; h25 <= {h25[28:0], clk25m_en};
        // pulsos en los ultimos 30 ciclos (este incluido), de forma incremental
        t21 = n21 + clk21m_en - h21[29]; n21 <= t21;
        t14 = n14 + clk14m_en - h14[29]; n14 <= t14;
        t25 = n25 + clk25m_en - h25[29]; n25 <= t25;
        if (ecyc >= 40) begin
            if (t21 != 6) bad_en21 = bad_en21 + 1;
            if (t14 != 4) bad_en14 = bad_en14 + 1;
            if (t25 != 7) bad_en25 = bad_en25 + 1;
        end
        if (v_timing) begin
            n_vt = n_vt + 1;
            if (last_vt >= 0) begin
                if (cyc - last_vt != 20) begin
                    bad_vt = bad_vt + 1;
                    if (bad_vt <= 3) $display("  v_timing: intervalo %0d en t=%0t", cyc - last_vt, $time);
                end
                vt_period = cyc - last_vt;
            end
            last_vt = cyc;
            if (!h21[1]) begin
                bad_vt21 = bad_vt21 + 1;
                if (bad_vt21 <= 3) $display("  v_timing sin clk21m_en 2 ciclos antes, t=%0t", $time);
            end
        end
    end

    // ------------------------------------------------------------------
    //  Comparacion final de toda la SDRAM con las sombras
    // ------------------------------------------------------------------
    integer fin_bad_a = 0, fin_stray_a = 0, fin_bad_v = 0, fin_x_v = 0;
    task final_compare;
        integer i, w, l;
        reg [31:0] wd;
        reg [18:0] ba;
        begin
            // corrupcion deliberada (controles negativos)
            if (NEGM & 1) mdl.mem[21'h1E0000 + last_vw_byte[18:2]] = mdl.mem[21'h1E0000 + last_vw_byte[18:2]] ^ (32'h1 << (8 * last_vw_byte[1:0]));
            if (NEGM & 2) mdl.mem[pool_addr(12'd7)] = mdl.mem[pool_addr(12'd7)] ^ 32'h1;
            // pool de la CPU contra su sombra
            for (i = 0; i < 4096; i = i + 1)
                if (mdl.mem[pool_addr(i[11:0])] !== shadow[i]) fin_bad_a = fin_bad_a + 1;
            // el resto de palabras por debajo de 0x780000 deben seguir como nacieron
            for (i = 0; i < 4096; i = i + 1) mdl.mem[pool_addr(i[11:0])] = pat(pool_addr(i[11:0]));
            for (w = 0; w < 32'h1E0000; w = w + 1)
                if (mdl.mem[w] !== pat(w[20:0])) begin
                    fin_stray_a = fin_stray_a + 1;
                    if (fin_stray_a <= 5) $display("  PALABRA AJENA t=%0t word=%h val=%h", $time, w, mdl.mem[w]);
                end
            // VRAM: byte a byte contra la sombra (X contra X: nunca escrito)
            for (w = 0; w < 32'h20000; w = w + 1) begin
                wd = mdl.mem[21'h1E0000 + w];
                for (l = 0; l < 4; l = l + 1) begin
                    ba = {w[16:0], 2'b00} + l;
                    if (wd[8*l +: 8] !== vsh[ba]) begin
                        fin_bad_v = fin_bad_v + 1;
                        if (fin_bad_v <= 5) $display("  VRAM DISTINTA t=%0t byte=%h sdram=%h sombra=%h", $time, ba, wd[8*l +: 8], vsh[ba]);
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  Informe
    // ------------------------------------------------------------------
    integer errors = 0;
    task chk(input cond, input [1023:0] what);
        begin
            if (cond !== 1'b1) begin errors = errors + 1; $display("  [FAIL] %0s", what); end
            else $display("  [ok]   %0s", what);
        end
    endtask
    function [39:0] kname(input integer i);
        case (i)
            0: kname = "rd8  "; 1: kname = "rd16 "; 2: kname = "rd32 "; 3: kname = "rdE  "; 4: kname = "rdO  ";
            5: kname = "wr8  "; 6: kname = "wr16 "; 7: kname = "wr32 "; 8: kname = "wrE  "; 9: kname = "wrO  ";
            default: kname = "rfsh ";
        endcase
    endfunction
    function [47:0] cname(input integer i);
        case (i)
            0: cname = "nada  "; 1: cname = "A-rd  "; 2: cname = "A-wr  "; 3: cname = "A-ref ";
            4: cname = "R-prop"; default: cname = "otra  ";
        endcase
    endfunction

    task report_v;
        integer c, q, h;
        begin
            $display("SLOTS : ranuras=%0d con operacion=%0d (%0d vacias) | ranuras PERDIDAS=%0d | v_timing n=%0d periodo=%0d",
                     n_slots, n_vops, n_idle, n_lost, n_vt, vt_period);
            $write("OPS V : "); for (q = 0; q < 11; q = q + 1) $write("%0s=%0d ", kname(q), cnt_kind[q]); $write("\n");
            $display("DATOS V: lecturas comprobadas=%0d (%0d bytes) malas=%0d (con X en DOUT=%0d) | final: VRAM distinta=%0d  palabras ajenas=%0d  pool CPU distinto=%0d",
                     n_chk_v, n_lanes_v, n_bad_v, n_xv, fin_bad_v, fin_stray_a, fin_bad_a);
            $display("PH    : peor ph de vuelta del core a WAIT_REQ = %0d con (A=%0s, V=%0s)", worst_ph, cname(worst_cul), kname(worst_kind));
            $write("PHHIST:"); for (h = 0; h < 32; h = h + 1) if (ph_hist[h] != 0) $write(" %0d:%0d", h, ph_hist[h]); $write("\n");
            $write("COMBO : ph max (fila = lo que se colo, columna = op de V)  ");
            for (q = 0; q < 11; q = q + 1) $write("%0s", kname(q)); $write("\n");
            for (c = 0; c < 6; c = c + 1) begin
                $write("COMBO : %0s                                    ", cname(c));
                for (q = 0; q < 11; q = q + 1)
                    if (cntph[c*11 + q] == 0) $write("  -  ");
                    else $write("%3d  ", maxph[c*11 + q]);
                $write("\n");
            end
            $display("EN    : ventanas de 30 ciclos mal: clk21m_en=%0d clk14m_en=%0d clk25m_en=%0d | v_timing mal=%0d sin clk21m_en-2=%0d",
                     bad_en21, bad_en14, bad_en25, bad_vt, bad_vt21);
        end
    endtask

    task report_cpu;
        begin
            $display("CPU   : lecturas n=%0d cmd_en->ack min/media/max = %0d / %.2f / %0d ciclos = %.0f / %.0f / %.0f ns",
                rl_n, rl_min, 1.0*rl_sum/(rl_n>0?rl_n:1), rl_max, rl_min*9.259, 9.259*rl_sum/(rl_n>0?rl_n:1), rl_max*9.259);
            $display("CPU   : escrituras n=%0d cmd_en->ack min/media/max = %0d / %.2f / %0d ciclos = %.0f / %.0f / %.0f ns",
                wl_n, wl_min, 1.0*wl_sum/(wl_n>0?wl_n:1), wl_max, wl_min*9.259, 9.259*wl_sum/(wl_n>0?wl_n:1), wl_max*9.259);
            $display("DATOS A: ordenes CPU perdidas=%0d lecturas=%0d (malas %0d, X %0d) escrituras=%0d",
                n_drop, n_chk_a, n_bad_a, n_xa, n_wcpu);
        end
    endtask

    // ------------------------------------------------------------------
    //  Test
    // ------------------------------------------------------------------
    integer n_ref0, n_own0, n_aref0, n_stale0;
    real t0, t1, us;
    wire negrun = (NEG != 0) || (NEGV != 0) || (NEGA != 0) || (NEGM != 0) || (ACK_DLY != 0);
    initial begin
        #200 por_n = 1'b1;
        wait (s_en);
        repeat (30) @(posedge clk);
        core_run = 1'b1;
        $display("CONFIG: MODE=%0d LOAD=%0d NEG=%0d NOREFV=%0d NEGV=%0d NEGA=%0d NEGM=%0d ACK_DLY=%0d TZ=%.2f (%.3f MHz) FE=%.0f PAT=%0d CPU_ON=%0d NORFSH=%0d",
                 MODE, LOAD, NEG, NOREFV, NEGV, NEGA, NEGM, ACK_DLY, TZ, 1000.0/TZ, FE_NS, PATTERN, CPU_ON, NORFSH);

        if (MODE == 1) begin
            // ------------- CPU parada: el refresco propio mantiene la SDRAM -------------
            cpu_run = 1'b1; #200000;
            cpu_run = 1'b0; #5000;
            mdl.max_ref_gap = 0.0;
            n_ref0 = mdl.n_ref; n_own0 = n_own; n_aref0 = n_aref; n_stale0 = mdl.n_stale;
            t0 = $realtime;
            $display("  CPU parada durante %0d ms (V con carga %0d %%)", STOP_MS, LOAD);
            #(STOP_MS * 1.0e6);
            t1 = $realtime;
            $display("REFRESH: durante la parada refrescos=%0d (propios %0d, de A %0d), media %0.2f us, hueco maximo entre refrescos %0.2f us",
                     mdl.n_ref - n_ref0, n_own - n_own0, n_aref - n_aref0,
                     (t1 - t0) / 1000.0 / ((mdl.n_ref - n_ref0) > 0 ? (mdl.n_ref - n_ref0) : 1), mdl.max_ref_gap / 1000.0);
            // la CPU vuelve y lee todo su pool, fila tras fila
            force_rd = 1'b1; sweep = 1'b1; sweep_i = 12'd0;
            cpu_run = 1'b1;
            wait (sweep_i == 12'hFFF);
            #20000;
            cpu_run = 1'b0; core_run = 1'b0; #40000;
            $display("  filas caducadas (modelo): %0d | lecturas CPU %0d, erroneas %0d", mdl.n_stale, n_chk_a, n_bad_a);
            final_compare;
            report_v;
            $display("DATOS A: ordenes CPU perdidas=%0d lecturas=%0d (malas %0d, X %0d) escrituras=%0d", n_drop, n_chk_a, n_bad_a, n_xa, n_wcpu);
            $display("SDRAM : n_err=%0d n_stale=%0d refrescos totales=%0d (propios %0d, de A %0d) max_ref_gap=%.2f us",
                     mdl.n_err, mdl.n_stale, mdl.n_ref, n_own, n_aref, mdl.max_ref_gap / 1000.0);
            if (NEG) begin
                chk(mdl.n_stale > 0, "CONTROL NEGATIVO: sin refresco propio el modelo detecta filas caducadas");
            end else begin
                chk(mdl.n_stale == 0, "con la CPU parada la SDRAM se sigue refrescando (ninguna fila caducada)");
                chk(mdl.max_ref_gap < 15600.0, "nunca pasan 15,6 us sin refresco");
                chk(n_bad_a == 0 && n_xa == 0, "las lecturas de la CPU tras la parada son correctas");
                chk(n_lost == 0, "ninguna ranura perdida");
                chk(n_bad_v == 0, "ninguna lectura de V erronea");
                chk(fin_bad_a == 0 && fin_stray_a == 0 && fin_bad_v == 0, "la SDRAM final coincide con las sombras");
                chk(worst_ph <= 18, "el core vuelve a WAIT_REQ como tarde en ph 18 (cabecera del arbitro)");
                chk(bad_en21 == 0 && bad_en14 == 0 && bad_en25 == 0 && bad_vt == 0 && bad_vt21 == 0, "habilitaciones y v_timing correctos");
                if (LOAD > 0) chk(n_vops > 1000 && n_chk_v > 100, "hay trafico de V medido");
            end
            chk(mdl.n_err == 0, "el modelo de SDRAM no vio ordenes ilegales");
            $display("RESULTADO: %s (%0d errores)", errors == 0 ? "PASS" : "FAIL", errors);
            $finish;
        end

        // ---------------- MODE 0: trafico ----------------
        if (CPU_ON) cpu_run = 1'b1;
        #200000;
        mdl.max_ref_gap = 0.0;
        n_ref0 = mdl.n_ref; n_own0 = n_own; n_aref0 = n_aref;
        t0 = $realtime; meas = 1'b1;
        #(MEAS_US * 1000.0);
        meas = 1'b0; t1 = $realtime;
        us = (t1 - t0) / 1000.0;
        $display("REFRESH: en %0.0f us refrescos=%0d (propios %0d, de A %0d), hueco maximo entre refrescos %0.2f us",
                 us, mdl.n_ref - n_ref0, n_own - n_own0, n_aref - n_aref0, mdl.max_ref_gap / 1000.0);
        cpu_run = 1'b0; core_run = 1'b0; #40000;
        final_compare;
        report_v;
        report_cpu;
        $display("SDRAM : n_err=%0d n_stale=%0d ops A=%0d  ops V=%0d", mdl.n_err, mdl.n_stale, n_aops, n_vtake);

        if (NEGV != 0)   chk(n_bad_v > 0, "CONTROL NEGATIVO: un bit de v_dout forzado -> el banco ve lecturas de V erroneas");
        else if (NEGA != 0) chk(n_bad_a > 0, "CONTROL NEGATIVO: un bit de la lectura de A forzado -> el banco ve lecturas de A erroneas");
        else if (NEGM != 0) begin
            if (NEGM & 1) chk(fin_bad_v > 0, "CONTROL NEGATIVO: byte de VRAM corrompido -> la comparacion final lo ve");
            if (NEGM & 2) chk(fin_bad_a > 0, "CONTROL NEGATIVO: palabra de A corrompida -> la comparacion final la ve");
        end else if (ACK_DLY != 0)
            chk(n_lost > 0, "CONTROL NEGATIVO: ACK visto 8 ciclos tarde -> el banco cuenta ranuras perdidas");
        else begin
            chk(n_lost == 0, "ninguna ranura perdida");
            chk(n_bad_v == 0 && n_xv >= 0, "cada lectura de V devuelve lo escrito segun la semantica de tnCart");
            chk(n_drop == 0, "ninguna orden de la CPU se pierde");
            chk(n_bad_a == 0 && n_xa == 0, "cada lectura de la CPU devuelve lo ultimo escrito en esa palabra");
            chk(mdl.n_err == 0 && mdl.n_stale == 0, "SDRAM sin ordenes ilegales ni filas caducadas");
            chk(fin_bad_a == 0 && fin_stray_a == 0 && fin_bad_v == 0, "la SDRAM final coincide con las sombras (nada de V fuera de la VRAM, nada de A dentro)");
            chk(worst_ph <= 18, "el core vuelve a WAIT_REQ como tarde en ph 18 (cabecera del arbitro)");
            chk(mdl.max_ref_gap < 15600.0, "nunca pasan 15,6 us sin refresco");
            chk(bad_en21 == 0 && bad_en14 == 0 && bad_en25 == 0 && bad_vt == 0 && bad_vt21 == 0, "habilitaciones (6/4/7 en 30 ciclos) y v_timing (cada 20, 2 tras clk21m_en) correctos");
            if (LOAD > 0) chk(n_vops > 1000 && n_chk_v > 500, "hay trafico de V medido");
            if (CPU_ON) chk(rl_n > 100 && (wl_n > 100 || PATTERN == 1), "hay trafico de CPU medido");
        end
        $display("RESULTADO: %s (%0d errores)", errors == 0 ? "PASS" : "FAIL", errors);
        $finish;
    end

    // perro guardian
    initial begin
        #((MODE == 1 ? STOP_MS + 40 : 60) * 1.0e6);
        $display("RESULTADO: FAIL (timeout)");
        $finish;
    end
endmodule
`default_nettype wire
