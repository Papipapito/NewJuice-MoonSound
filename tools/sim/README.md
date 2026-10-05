# Simulation benches (New Juice MoonSound fork)

Run them in a Linux shell (they were written for WSL Ubuntu-24.04) with
Icarus Verilog 12 and, for the board bench, `sv2v`. Nothing here is part of
the FPGA build.

| Bench | What it proves | How to run |
|---|---|---|
| `blocks/tb_arb.v` (MODE 0) | The SDRAM arbiter with the **real** New Juice adapter and controller, the **real** MoonSound wave chain (YMF278B engine, `opl4_pcm`, `wave_sdram`) and a synthetic Z80 at 3.58, 5.37 and 7.16 MHz: no CPU command lost, every CPU read returns the last value written, every wave read returns the word at its translated address, PCM output rate, CPU and wave latencies. | `bash blocks/run_blocks.sh arb` |
| `blocks/tb_arb.v` (MODE 1) | The Z80 stops for 70 ms (no RFSH): the arbiter's own refresh keeps every row alive (retention check of the SDRAM model). `NEG=1` disables that refresh and the model **must** report decayed rows. | `bash blocks/run_blocks.sh refresh` |
| `blocks/tb_map.v` | Memory map with the real `sdram_mapper` and the real 7Eh/7Fh register path: 2 MB mapper (128 pages, upper half mirrored, never above 0x1FFFFF), wave RAM at SDRAM 0x700000, nothing above 1 MB (reads FFh, no mirror), YRW801 read-only for the MSX, wave RAM size detection gives 1 MB, and the whole 8 MB SDRAM compared word by word at the end. | `bash blocks/run_blocks.sh map` |
| `blocks/tb_i2s.v` | New Juice's I2S transmitter (`audio_drive` + `clockdiv`, 108 MHz, as in `top.v`) against the MAX98357A of the Tang Nano 20K: every word comes out exact through a standard I2S receiver and both halves of a frame are equal, a left-justified receiver (MAX98357B) must not decode it, DIN/WS keep 10 ns of setup and hold around the rising BCLK edge, 48.2 kHz. | `bash blocks/run_blocks.sh i2s` |
| `blocks/tb_opll.v` | New Juice's OPLL (jt2413, unchanged) run directly with the board bench's register writes: it sounds. In the board bench, after sv2v, Icarus leaves its output at X, so there it is only checked that the writes reach it. | `bash blocks/run_blocks.sh opll` |
| `board/tb_nj_board.v` | The **whole** design (sv2v of every file in `new-juice.gprj`, Gowin simulation primitives) wired by pin number to a WonderTANG 2.0b/2.02b board model, with synthetic flash images (no copyrighted ROM): boot, ROM copy, YRW801 copy and checksum, FM and wave registers, /WAIT and /INT, mapper, Super-MegaRAM, OPLL, I2S output (decoded as I2S, each word checked against the mix, saturation of the mix), bus release after reads, memory reads without /WAIT at 3.58/5.37/7.16 MHz with 24 PCM voices playing. | `bash board/run_board.sh` (`blank`: flash without the YRW801; `all`: both at once). About 40 minutes. |

Both scripts compile every bench afresh (an old `build/*.vvp` is deleted
before compiling, never reused), print `run_blocks: n/n PASS` or
`run_board: n/n PASS`, and exit with a non-zero status when a bench does not
compile or its log does not end in `RESULTADO: PASS`.

`run_board.sh` shortens a few start-up delays in the **converted netlist**
(automatic S1 pulse, SDRAM start-up test length, ROM copy length); the RTL is
not modified. The video PLL is held in reset, so HDMI is not exercised. Some
New Juice sources (PSG, OPLL) stay at X in Icarus after sv2v; the bench pins
them to 0 before checking the OPL4 -> mix -> I2S path and says so.

Origin: `common/sdram_model.v`, `common/spi_flash_model.v` and
`board/wt20x_board.v` / `wt_official_pins.vh` come from MoonTANG
(`tools/sim`, commit 5400f15, GPL-3.0, Albert "Papipapito" with Claude); the
SDRAM model gained a retention check here. `blocks/tb_arb.v` grew out of the
bandwidth bench used to study the integration.
