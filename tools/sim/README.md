# Simulation benches (New Juice V9990 fork)

Run them in a Linux shell (they were written for WSL Ubuntu-24.04) with
Icarus Verilog 12 and, for the board bench, `sv2v` (0.0.13), python3 and the
simulation library of Gowin 1.9.12.03 (`prim_sim.v`; `GOWIN_SIMLIB` gives
its path). Nothing here is part of the FPGA build. Results and what is not simulated:
`docs/V9990.md`.

| Bench | What it proves | How to run |
|---|---|---|
| `blocks/tb_varb.v` | The SDRAM arbiter (`src/v9990/nj_v9990_arb.v`) with the **real** New Juice adapter and controller, a synthetic V9990 asking for VRAM in every slot (single and double words, reads and writes) and a synthetic Z80 at 3.58, 5.37 and 7.16 MHz: no VRAM slot lost, the V9990 back in its idle state by clock 18 of 20, every read of either client returns the last value written, CPU latency, own refresh with the Z80 stopped 70 ms. Negative controls: no own refresh, a flipped data bit on either side, a corrupted SDRAM, a late ACK. | `bash blocks/run_varb.sh` (`traffic`, `stop`, `neg`, `all`) |
| `blocks/tb_i2s.v` | New Juice's I2S transmitter (`audio_drive` + `clockdiv`, 108 MHz, as in `top.v`) against the MAX98357A of the Tang Nano 20K: exact words, setup and hold, 48.2 kHz. | `bash blocks/run_blocks.sh i2s` |
| `blocks/tb_opll.v` | New Juice's OPLL (jt2413, unchanged) run directly: it sounds. | `bash blocks/run_blocks.sh opll` |
| `board/tb_nj_board.v` | The **whole** design (sv2v of every file in `new-juice.gprj`, Gowin simulation primitives) wired by pin number to a WonderTANG 2.0b/2.02b board model, with synthetic flash images (no copyrighted ROM): boot, ROM copy, the V9990 at ports 60h-6Fh (registers, VRAM by P#0 in B1 and P1 and where each byte lands in the SDRAM, /WAIT, /INT, reset), 4 MB mapper, Super-MegaRAM, Nextor ROM, LINEAR, OPLL writes, I2S, CPU traffic against a V9990 with its display on, memory reads without /WAIT (required at 3.58 MHz, measured at 5.37), bus timing at the slot pins, no illegal SDRAM command, no stale row. | `bash board/run_board.sh` (`main`) |
| `board/tb_nj_board.v` + `board/video_nj.vh` | The same with the video PLL running: the picture at the input of the DVI transmitter (stubbed), geometry of the frames, border colour from the palette, a B1 bitmap written by P#0. | `bash board/run_board.sh video` |
| negative controls of the board bench | A flipped bit of the V9990 read data, the arbiter not yielding to the V9990, the VRAM at another SDRAM address, `a_busy` forced to 0: each must FAIL. | `bash board/run_board.sh neg` (`all`: everything at once) |

`blocks/tb_arb.v`, `blocks/tb_map.v` (the `arb`, `refresh` and `map` modes of
`run_blocks.sh`) and `vu/` belong to the MoonSound of the `moonsound` branch,
which is not in this build: they are not maintained here. `run_blocks.sh`
without an argument still runs them: use `i2s` and `opll` only.

The three scripts compile every bench afresh (an old `build/*.vvp` is deleted
before compiling, never reused), print `run_varb: n/n PASS`,
`run_blocks: n/n PASS` or `run_board: n/n PASS`, and exit with a non-zero
status when a bench does not compile or its log has no `RESULTADO: PASS`.
The negative controls are the other way round: each must give
`RESULTADO: FAIL` (`run_board neg: n/n negative controls detected`).

`run_board.sh` shortens a few start-up delays in the **converted netlist**
(automatic S1 pulse, SDRAM start-up test length, ROM copy length) and works
around three things Icarus / sv2v do not take (the order of the interface
instances in `t9990.sv`, the unpacked union of the blitter, an untyped
localparam of the sprites: `fix_t9990.py`, `fix_union.py`); the RTL is not
modified. Gowin's encrypted DVI transmitter is replaced by
`common/dvi_tx_stub.v`. The VRAM area of the SDRAM model is zeroed by the back
door at start (it is born at X), and `STATUS.BD` / `STATUS.BX` of the blitter,
which have no reset, are set to 0 as the FPGA does at configuration.

Origin: `common/sdram_model.v`, `common/spi_flash_model.v` and
`board/wt20x_board.v` / `wt_official_pins.vh` come from MoonTANG
(`tools/sim`, commit 5400f15, GPL-3.0, Albert "Papipapito" with Claude); the
SDRAM model gained a retention check here. `common/hdmi_rx_check.v`,
`vu/moontang/vu_meter.v` and, adapted, `vu/vu_check.py` and
`vu/tb_vu_hdmi_nj.v` come from the same MoonTANG commit. `blocks/tb_arb.v`
grew out of the bandwidth bench used to study the integration.
`blocks/tb_varb.v` and the V9990 parts of the board bench were written for this
fork (2026, Albert "Papipapito", with Claude).
