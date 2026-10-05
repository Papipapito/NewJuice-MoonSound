// ============================================================================
// tb_map.v - New Juice MoonSound fork: SDRAM memory map.
//
// Real chain: sdram_mapper (New Juice) -> sdram_command_adapter -> nj_sdram_arb
// -> sdram.v -> SDRAM model, plus the MoonSound wave memory through the REAL
// register interface (ports 7Eh/7Fh of opl4_pcm + the YMF278B engine).
//
//  1. Mapper: the MSX-DOS style size detection (mark every page from FFh down
//     to 00h, read them back) must find 128 pages = 2 MB, and the mapper must
//     never write above SDRAM 0x1FFFFF (the YRW801 lives at 0x200000).
//  2. Wave memory map through 7Eh/7Fh: RAM 0x200000-0x2FFFFF lands in SDRAM
//     0x700000-0x7FFFFF; 0x300000+ is empty (reads FFh, writes vanish, no
//     mirror); the YRW801 area is read-only once loaded.
//  3. Wave RAM size detection like the MoonSound players (one mark per 64 KB
//     block from the top down, read back from the bottom up): 16 blocks = 1 MB.
//  4. At the end the WHOLE SDRAM is compared with the expected contents: no
//     write of either client landed anywhere else (mapper area, YRW801,
//     MegaRAM, ROM copies at 0x600000-0x627FFF, wave RAM).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_map;
    reg clk_108m = 1'b0, clk_54m = 1'b0, clk_eng = 1'b0;
    integer ph = 0;
    initial forever begin
        #(1.54321);
        ph = (ph + 1) % 36;
        if (ph % 3 == 0) clk_108m = ~clk_108m;
        if (ph % 6 == 0) clk_54m  = ~clk_54m;
        if (ph % 9 == 0) clk_eng  = ~clk_eng;
    end
    wire clk_sdram = ~clk_108m;
    reg por_n = 1'b0, bus_rst_n = 1'b0, eng_rst_n = 1'b0, map_rst_n = 1'b0;

    // ---------------- SDRAM ----------------
    wire [31:0] sd_dq; wire [10:0] sd_a; wire [1:0] sd_ba; wire [3:0] sd_dqm;
    wire sd_ncs, sd_nwe, sd_nras, sd_ncas, sd_clk, sd_cke;
    sdram_model #(.RET_CHECK(1)) sdram (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_ncs), .ras_n(sd_nras),
        .cas_n(sd_ncas), .we_n(sd_nwe), .addr(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq));
    wire s_rd, s_wr, s_ref; wire [22:0] s_addr; wire [15:0] s_din; wire [1:0] s_wdm;
    wire [15:0] s_dout; wire [31:0] s_dout32; wire s_dr, s_busy, s_en;
    sdram #(.FREQ(108_000_000), .CAS(5'd3), .T_WR(5'd3), .T_MRD(5'd2), .T_RP(5'd2), .T_RCD(5'd2), .T_RC(5'd7)) u_sd (
        .SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_nCS(sd_ncs), .SDRAM_nWE(sd_nwe),
        .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_CLK(sd_clk), .SDRAM_CKE(sd_cke), .SDRAM_DQM(sd_dqm),
        .clk(clk_108m), .clk_sdram(clk_sdram), .resetn(por_n),
        .rd(s_rd), .wr(s_wr), .refresh(s_ref), .addr(s_addr), .din(s_din), .wdm(s_wdm),
        .dout(s_dout), .dout32(s_dout32), .data_ready(s_dr), .busy(s_busy), .enabled(s_en));

    // ---------------- MSX bus as New Juice sees it (main_clk) ----------------
    reg [15:0] b_addr = 16'h0000;
    reg [7:0]  b_din = 8'h00;
    reg b_merq_n = 1, b_iorq_n = 1, b_rd_n = 1, b_wr_n = 1, b_rfsh_n = 1, b_m1_n = 1, b_sltsl_n = 1;

    // ---------------- mapper (client A) ----------------
    wire [7:0] map_dout; wire map_dout_en, map_wait_n;
    wire m_cmd_en; wire [2:0] m_cmd; wire [20:0] m_addr; wire [3:0] m_dqm; wire [31:0] m_data;
    wire [31:0] a_rdata; wire a_init, a_ack;
    sdram_mapper u_map (
        .clk(clk_108m), .cpu_clk_high(1'b1), .reset_n(map_rst_n),
        .addr(b_addr), .data_in(b_din), .merq_n(b_merq_n), .iorq_n(b_iorq_n), .rd_n(b_rd_n), .wr_n(b_wr_n),
        .rfsh_n(b_rfsh_n), .m1_n(b_m1_n), .sltsl_n(b_sltsl_n),
        .page0_subslot_en(4'b1000), .page1_subslot_en(4'b1000), .page2_subslot_en(4'b1000), .page3_subslot_en(4'b1000),
        .data_out(map_dout), .data_out_en(map_dout_en), .wait_n(map_wait_n),
        .debug_page0(), .debug_page1(), .debug_page2(), .debug_page3(),
        .sdrc_cmd_en(m_cmd_en), .sdrc_cmd(m_cmd), .sdrc_precharge_ctrl(), .sdram_power_down(), .sdram_selfrefresh(),
        .sdrc_addr(m_addr), .sdrc_dqm(m_dqm), .sdrc_data(m_data), .sdrc_data_len(),
        .sdrc_data_in(a_rdata), .sdrc_init_done(a_init), .sdrc_cmd_ack(a_ack));

    wire a_rd, a_wr, a_ref; wire [22:0] a_addr; wire [15:0] a_din; wire [1:0] a_wdm;
    wire a_busy, a_dr;
    sdram_command_adapter u_ad (
        .clk(clk_108m), .reset_n(por_n), .debug_wait_n(1'b1),
        .rfsh_n(b_rfsh_n), .m1_n(b_m1_n), .merq_n(b_merq_n), .iorq_n(b_iorq_n), .rd_n(b_rd_n), .wr_n(b_wr_n),
        .cmd_en(m_cmd_en), .cmd(m_cmd), .cmd_addr(m_addr), .cmd_dqm(m_dqm), .cmd_data(m_data),
        .read_data(a_rdata), .init_done(a_init), .cmd_ack(a_ack),
        .rd(a_rd), .wr(a_wr), .refresh(a_ref), .addr(a_addr), .din(a_din), .wdm(a_wdm),
        .dout32(s_dout32), .data_ready(a_dr), .busy(a_busy), .enabled(s_en));

    // ---------------- wave memory (client W) ----------------
    wire wv_req, wv_we, wv_done; wire [21:0] wv_addr; wire [7:0] wv_wdata; wire [15:0] wv_dout;
    reg  rom_we = 1'b0;
    nj_sdram_arb u_arb (
        .clk(clk_108m), .rst_n(por_n),
        .a_rd(a_rd), .a_wr(a_wr), .a_refresh(a_ref), .a_addr(a_addr), .a_din(a_din), .a_wdm(a_wdm),
        .a_busy(a_busy), .a_data_ready(a_dr),
        .cpu_sltsl_n(b_sltsl_n), .cpu_rd_n(b_rd_n),
        .wv_req(wv_req), .wv_we(wv_we), .wv_addr(wv_addr), .wv_wdata(wv_wdata), .wv_dout(wv_dout), .wv_done(wv_done),
        .rom_write_en(rom_we),
        .s_rd(s_rd), .s_wr(s_wr), .s_refresh(s_ref), .s_addr(s_addr), .s_din(s_din), .s_wdm(s_wdm),
        .s_dout32(s_dout32), .s_data_ready(s_dr), .s_busy(s_busy), .own_refresh());

    wire        e_req, e_we, e_done_t;
    wire [21:0] e_addr; wire [7:0] e_wdata, e_rdata; wire [15:0] e_rword;
    // host port of wave_sdram = the YRW801 loader's port, driven by the bench
    reg h_tgl = 1'b0, h_we = 1'b0; reg [21:0] h_addr = 22'd0; reg [7:0] h_wdata = 8'd0;
    wire h_done_t; wire [7:0] h_rdata;
    wave_sdram u_wave (
        .clk_host(clk_54m), .rst_n(por_n), .req_toggle(h_tgl), .we(h_we), .addr(h_addr), .wdata(h_wdata),
        .rdata(h_rdata), .done_toggle(h_done_t), .ready(),
        .clk_eng(clk_eng), .eng_req(e_req), .eng_we(e_we), .eng_addr(e_addr), .eng_wdata(e_wdata),
        .eng_rdata(e_rdata), .eng_rword(e_rword), .eng_done_t(e_done_t), .diag(),
        .clk_108m(clk_108m), .wv_req(wv_req), .wv_we(wv_we), .wv_addr(wv_addr), .wv_wdata(wv_wdata),
        .wv_dout(wv_dout), .wv_done(wv_done));

    reg        iorq_n = 1'b1, rd_n = 1'b1, wr_n = 1'b1;
    reg [7:0]  addr = 8'h00, din = 8'h00;
    wire       wave_rd_act, wave_wait_n;
    wire [7:0] wave_dout;
    opl4_pcm #(.CE_INC(24'd588), .CE_MOD(24'd625), .RD_MIRROR(0)) u_pcm (
        .rst_n(bus_rst_n), .clk_host(clk_54m),
        .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .m1_n(1'b1), .addr(addr), .din(din),
        .wave_rd(wave_rd_act), .wave_dout(wave_dout), .wave_wait_n(wave_wait_n), .wave_status(), .mix_fm(),
        .pcm_l(), .pcm_r(),
        .clk_eng(clk_eng), .eng_rst_n(eng_rst_n),
        .mem_req(e_req), .mem_we(e_we), .mem_addr(e_addr), .mem_wdata(e_wdata),
        .mem_rdata(e_rdata), .mem_rword(e_rword), .mem_done_t(e_done_t),
        .diag(), .dbg_tx(), .vid_diag(4'd0));
    integer ii_sl;
    initial begin
        #1;
        for (ii_sl = 0; ii_sl < 32; ii_sl = ii_sl + 1) begin
            u_pcm.sl_stride[ii_sl] = 3'd0; u_pcm.sl_hi[ii_sl] = 3'd0;
        end
    end

    // ---------------- expected SDRAM contents ----------------
    reg [31:0] expm [0:2097151];
    function [31:0] pat(input [20:0] w);
        pat = ({11'd0, w} * 32'h9E3779B1) ^ 32'h5A5A00FF;
    endfunction
    task exp_byte(input [22:0] sb, input [7:0] v);
        reg [31:0] w;
        begin w = expm[sb[22:2]]; w[8*sb[1:0] +: 8] = v; expm[sb[22:2]] = w; end
    endtask
    function [7:0] model_byte(input [22:0] sb);
        reg [31:0] w;
        begin w = sdram.mem[sb[22:2]]; model_byte = w[8*sb[1:0] +: 8]; end
    endfunction
    integer k;
    initial begin
        for (k = 0; k < (1<<21); k = k + 1) begin sdram.mem[k] = pat(k[20:0]); expm[k] = pat(k[20:0]); end
    end

    // ---------------- scoring ----------------
    integer errors = 0;
    task chk(input cond, input [1023:0] what);
        begin
            if (cond !== 1'b1) begin errors = errors + 1; $display("  [FAIL] %0s", what); end
            else $display("  [ok]   %0s", what);
        end
    endtask

    // ---------------- mapper bus cycles (main_clk) ----------------
    task io_out(input [7:0] p, input [7:0] v);
        begin
            @(posedge clk_108m); b_addr <= {8'h00, p}; b_din <= v;
            @(posedge clk_108m); b_iorq_n <= 1'b0; b_wr_n <= 1'b0;
            repeat (30) @(posedge clk_108m);
            b_iorq_n <= 1'b1; b_wr_n <= 1'b1;
            repeat (10) @(posedge clk_108m);
        end
    endtask
    task mem_wr(input [15:0] a, input [7:0] v);
        begin
            @(posedge clk_108m); b_addr <= a; b_din <= v; b_sltsl_n <= 1'b0;
            @(posedge clk_108m); b_merq_n <= 1'b0;
            repeat (8) @(posedge clk_108m); b_wr_n <= 1'b0;
            repeat (40) @(posedge clk_108m);
            b_merq_n <= 1'b1; b_wr_n <= 1'b1; b_sltsl_n <= 1'b1;
            repeat (10) @(posedge clk_108m);
        end
    endtask
    reg [7:0] mrd;
    reg       mrd_ok;
    task mem_rd(input [15:0] a);
        begin
            @(posedge clk_108m); b_addr <= a; b_sltsl_n <= 1'b0;
            @(posedge clk_108m); b_merq_n <= 1'b0; b_rd_n <= 1'b0;
            repeat (40) @(posedge clk_108m);
            mrd = map_dout; mrd_ok = map_dout_en;
            b_merq_n <= 1'b1; b_rd_n <= 1'b1; b_sltsl_n <= 1'b1;
            repeat (10) @(posedge clk_108m);
        end
    endtask

    // ---------------- OPL4 ports (clk_54m), IN 7Fh waits for /WAIT ----------------
    task wr(input [7:0] p, input [7:0] v);
        begin
            @(posedge clk_54m); addr <= p; din <= v;
            @(posedge clk_54m); iorq_n <= 1'b0; wr_n <= 1'b0;
            repeat (16) @(posedge clk_54m);
            iorq_n <= 1'b1; wr_n <= 1'b1;
            repeat (60) @(posedge clk_54m);
        end
    endtask
    reg [7:0] rdv;
    task rd(input [7:0] p);
        begin
            @(posedge clk_54m); addr <= p;
            @(posedge clk_54m); iorq_n <= 1'b0; rd_n <= 1'b0;
            repeat (12) @(posedge clk_54m);
            while (!wave_wait_n) @(posedge clk_54m);
            repeat (4) @(posedge clk_54m);
            rdv = wave_dout;
            iorq_n <= 1'b1; rd_n <= 1'b1;
            repeat (60) @(posedge clk_54m);
        end
    endtask
    task loader_wr(input [21:0] a, input [7:0] v);
        reg d0;
        begin
            @(posedge clk_54m); d0 = h_done_t; h_we <= 1'b1; h_addr <= a; h_wdata <= v; h_tgl <= ~h_tgl;
            wait (h_done_t !== d0);
            repeat (4) @(posedge clk_54m);
        end
    endtask
    task wv(input [7:0] r, input [7:0] v); begin wr(8'h7E, r); wr(8'h7F, v); end endtask
    task wave_addr(input [21:0] a); begin wv(8'h03, {2'b00, a[21:16]}); wv(8'h04, a[15:8]); wv(8'h05, a[7:0]); end endtask
    task wave_wr(input [21:0] a, input [7:0] v); begin wave_addr(a); wv(8'h06, v); end endtask
    task wave_rd(input [21:0] a); begin wave_addr(a); wr(8'h7E, 8'h06); rd(8'h7F); end endtask

    integer p, cnt, blk, bad;
    reg [22:0] sb;
    initial begin
        #200 por_n = 1'b1;
        wait (s_en);
        repeat (50) @(posedge clk_108m);
        map_rst_n = 1'b1; bus_rst_n = 1'b1; eng_rst_n = 1'b1;
        #5000;

        // ============ 1. mapper: 2 MB ============
        $display("== 1. mapper de 2 MB ==");
        for (p = 255; p >= 0; p = p - 1) begin
            io_out(8'hFE, p[7:0]);
            mem_wr(16'h8000, p[7:0]);
            mem_wr(16'h8001, ~p[7:0]);
            sb = {p[6:0], 14'h0000}; exp_byte(sb, p[7:0]); exp_byte(sb + 23'd1, ~p[7:0]);
        end
        cnt = 0; bad = 0;
        for (p = 0; p < 256; p = p + 1) begin
            io_out(8'hFE, p[7:0]);
            mem_rd(16'h8000);
            if (!mrd_ok) bad = bad + 1;
            if (mrd === p[7:0]) cnt = cnt + 1;
            else if (p < 128) bad = bad + 1;                 // pages 0-7Fh keep their mark
            else if (mrd !== (p[7:0] - 8'h80)) bad = bad + 1; // 80h-FFh mirror 00h-7Fh
        end
        $display("  paginas distintas: %0d (%0d KB), lecturas inesperadas %0d", cnt, cnt * 16, bad);
        chk(cnt == 128, "la deteccion de tamano del mapper da 128 paginas = 2 MB");
        chk(bad == 0, "las paginas 80h-FFh son el reflejo de 00h-7Fh, como un mapper de 2 MB real");
        io_out(8'hFE, 8'h01);  // pages back to something harmless

        // ============ 2. wave memory map ============
        $display("== 2. memoria de ondas por 7Eh/7Fh ==");
        wr(8'hC6, 8'h05); wr(8'hC7, 8'h03);                 // NEW2 (only the PCM part is here)
        wv(8'h02, 8'h01);                                   // memory access mode
        wave_wr(22'h200000, 8'hA5); wr(8'h7F, 8'h5A); wr(8'h7F, 8'hC3);
        exp_byte(23'h700000, 8'hA5); exp_byte(23'h700001, 8'h5A); exp_byte(23'h700002, 8'hC3);
        chk(model_byte(23'h700000) == 8'hA5 && model_byte(23'h700001) == 8'h5A && model_byte(23'h700002) == 8'hC3,
            "RAM de ondas 0x200000-02 -> SDRAM 0x700000-02");
        wave_rd(22'h200000);
        chk(rdv == 8'hA5, "y se relee por 7Fh");
        wave_wr(22'h2FFFFF, 8'h3C); exp_byte(23'h7FFFFF, 8'h3C);
        chk(model_byte(23'h7FFFFF) == 8'h3C, "RAM de ondas 0x2FFFFF -> SDRAM 0x7FFFFF (ultimo byte)");
        wave_wr(22'h300000, 8'h77);
        wave_rd(22'h300000);
        chk(rdv == 8'hFF, "0x300000 (fuera del 1 MB): se lee FFh");
        wave_wr(22'h3FFFFF, 8'h77);
        wave_rd(22'h3FFFFF);
        chk(rdv == 8'hFF, "0x3FFFFF: se lee FFh");
        wave_rd(22'h000010);
        chk(rdv == model_byte(23'h200010), "YRW801[000010] se lee de SDRAM 0x200010");
        wave_wr(22'h000010, ~model_byte(23'h200010));
        wave_rd(22'h000010);
        chk(rdv == expm[23'h200010 >> 2][7:0] && model_byte(23'h200010) == expm[23'h200010 >> 2][7:0],
            "la YRW801 es de solo lectura para el MSX (OUT a la zona ROM: sin efecto)");
        // the loader's port (host side of wave_sdram): only during the copy
        loader_wr(22'h000011, 8'h99);
        chk(model_byte(23'h200011) == expm[23'h200011 >> 2][15:8], "puerto del cargador sin rom_write_en: la zona de la YRW801 no se toca");
        rom_we = 1'b1;
        loader_wr(22'h000011, 8'h99); exp_byte(23'h200011, 8'h99);
        loader_wr(22'h1FFFFF, 8'h42); exp_byte(23'h3FFFFF, 8'h42);
        rom_we = 1'b0;
        chk(model_byte(23'h200011) == 8'h99 && model_byte(23'h3FFFFF) == 8'h42,
            "durante la carga (rom_write_en) el cargador escribe la YRW801 en SDRAM 0x200000-0x3FFFFF");

        // ============ 3. wave RAM size detection ============
        $display("== 3. deteccion del tamano de la RAM de ondas ==");
        for (blk = 31; blk >= 0; blk = blk - 1) begin
            wave_wr(22'h200000 + blk * 22'h010000, blk[7:0] ^ 8'hA5);
            if (blk < 16) exp_byte(23'h700000 + blk * 23'h010000, blk[7:0] ^ 8'hA5);
        end
        cnt = 0;
        for (blk = 0; blk < 32; blk = blk + 1) begin
            wave_rd(22'h200000 + blk * 22'h010000);
            if (rdv == (blk[7:0] ^ 8'hA5) && cnt == blk) cnt = cnt + 1;
        end
        $display("  bloques de 64 KB: %0d -> %0d KB", cnt, cnt * 64);
        chk(cnt == 16, "la RAM de ondas se detecta como 1 MB (16 bloques de 64 KB, sin reflejos)");
        // the classic alias test: write block 0, read block 16 (would mirror on a 1 MB board without decoding)
        wave_wr(22'h200000, 8'h11); exp_byte(23'h700000, 8'h11);
        wave_rd(22'h300000);
        chk(rdv == 8'hFF, "escribir en 0x200000 no aparece en 0x300000");
        wv(8'h02, 8'h00);

        // ============ 4. whole SDRAM ============
        $display("== 4. SDRAM entera contra lo esperado ==");
        repeat (200) @(posedge clk_108m);
        bad = 0;
        for (k = 0; k < (1<<21); k = k + 1)
            if (sdram.mem[k] !== expm[k]) begin
                bad = bad + 1;
                if (bad <= 8) $display("  palabra %06x (byte %06x): %08x, esperado %08x", k, k*4, sdram.mem[k], expm[k]);
            end
        chk(bad == 0, "ninguna escritura fuera de su sitio (mapper, YRW801, MegaRAM, ROMs, RAM de ondas)");
        chk(sdram.n_err == 0 && sdram.n_stale == 0, "SDRAM sin ordenes ilegales ni filas caducadas");
        $display("RESULTADO: %s (%0d errores)", errors == 0 ? "PASS" : "FAIL", errors);
        $finish;
    end
endmodule
`default_nettype wire
