# New Juice + MoonSound (OPL4) — experimental fork

This branch (`moonsound`) adds a MoonSound — Yamaha YMF278B / OPL4: OPL3 FM
plus the 24-voice wavetable — to New Juice for the WonderTANG 2.0b / 2.02b, in
place of Franky. It is **private and experimental**: New Juice has no license,
so nothing here is published until its author, lfantoniosi, decides how (or
whether) it may be. It has been simulated, not yet run on a board.

The MoonSound comes from [MoonTANG](src/moonsound/NOTICE.md) (Albert
"Papipapito", with Claude): the OPL3 core of Greg Taylor (LGPL-3.0), the
YMF278B engine of srg320 / MAME (BSD-3) and MoonTANG's glue (GPL-3.0). See
`src/moonsound/NOTICE.md` for every component and license.

## What changes for the user

| | New Juice | This fork |
|---|---|---|
| Franky (SMS VDP + SN76489, ports 48h/49h, 88h/89h) | yes | **removed** |
| Sound scope on HDMI | yes | **removed** (it drew into Franky's framebuffer) |
| MoonSound FM (C4h-C7h) and wavetable (7Eh-7Fh) | — | **yes** |
| Memory mapper | 4 MB | **2 MB** |
| Nextor + microSD, Super-MegaRAM SCC, PSG, OPLL, SFG-01, debugger terminal on HDMI | yes | yes, unchanged |
| Audio to the slot (I2S amplifier, mono) | about 22 kHz | **48.2 kHz** |
| Audio on HDMI | mono, 44.1 kHz | **stereo**, 44.1 kHz |

The MoonSound has 1 MB of wave RAM (the standard 1 MB board size). Players see
the YRW801 GM samples as on the real cartridge.

## Flash and SDRAM maps

SPI flash (unchanged except the new 0x200000 area):

| Range | Contents |
|---|---|
| 0x000000-0x0DD89A | bitstream |
| 0x100000-0x11FFFF | Nextor |
| 0x120000-0x127FFF | FM-PAC + SFG-01 |
| **0x200000-0x3FFFFF** | **YRW801 wave ROM (2 MB, user supplied)** |

SDRAM (8 MB):

| Range | Contents |
|---|---|
| 0x000000-0x1FFFFF | memory mapper (2 MB; pages 80h-FFh mirror 00h-7Fh) |
| 0x200000-0x3FFFFF | YRW801 copy (MoonSound wave addresses 0x000000-0x1FFFFF) |
| 0x400000-0x5FFFFF | Super-MegaRAM (unchanged) |
| 0x600000-0x627FFF | ROM copies (unchanged) |
| 0x700000-0x7FFFFF | MoonSound wave RAM (wave addresses 0x200000-0x2FFFFF) |

Wave addresses 0x300000-0x3FFFFF have no memory: reads return FFh, writes are
ignored, nothing is mirrored, so size detection finds 1 MB.

## Programming

Build and flash the bitstream and New Juice's ROMs as usual (`make`,
`make program`, `make roms`). Then write **your own** YRW801 image (2 MB; it is
copyrighted by Yamaha and is not included) once:

```
make yrw801 YRW801=/path/to/yrw801.rom
```

That writes it at flash offset 0x200000, which nothing else uses.

At power-on New Juice first copies its ROMs (the MSX waits with /WAIT, as
before); then the YRW801 is copied to the SDRAM in the background while the MSX
runs (about 1.7 s: 0.8 us per byte in simulation). Until that copy ends the wavetable is held in reset; the FM
part works at once. A checksum tells whether the image is the YRW801: if the
copy fails or the image is not the YRW801, the LED gives a short flash every
1.2 s (it still shows SD activity as before).

## How it is built in

- `src/moonsound/moonsound_nj.sv`: the MoonSound. The bus comes from New
  Juice's debounced signals; reads of C4h-C7h / 7Eh-7Fh join New Juice's data
  mux and /BUSDIR; IN 7Fh holds the Z80 with /WAIT until the engine answers
  (as in MoonTANG on the WonderTANG); the FM timers join /INT. The bus is only
  touched while the slot clock runs and /RESET is high.
- `src/moonsound/nj_sdram_arb.v`: an arbiter between New Juice's
  `sdram_command_adapter` and its `sdram.v`. New Juice is never refused a
  command: it waits at most one MoonSound operation (simulated: CPU read
  latency 93 ns -> at most 167-176 ns). The arbiter also refreshes the SDRAM
  on its own every 7.8 us when nothing else did, because New Juice only
  refreshes after Z80 RFSH cycles and the wave ROM must survive a held /RESET
  or a /WAIT from another cartridge.
- Clocks, no new PLL: rpll_main's CLKOUTD (54 MHz, bus side of the OPL4) and
  CLKOUTD3 (36 MHz: the PCM engine, whose clock enable averages 33.8688 MHz,
  and the OPL3 FM, retuned from 27 to 36 MHz). Everything is timed together
  with main_clk.
- The SPI flash belongs to New Juice's ROM loader until its ROMs are copied,
  then to the YRW801 loader.
- Audio: the OPL4 (FM + wave, with the F8/F9 mix registers) joins New Juice's
  mix at the OPLL level; the sum now saturates instead of wrapping around. The
  I2S amplifier gets the mono mix at 48.2 kHz (108 MHz / 70 / 32); HDMI gets
  the stereo mix.

## Resources and timing

Measured with this branch (one place-and-route each, project options as in
`impl/new-juice_process_config.json`):

| | New Juice (author's bitstream, 1.9.11) | This fork, Gowin 1.9.12.03 | This fork, Gowin 1.9.11.03 Edu |
|---|---|---|---|
| Logic | 12546 / 20736 (61 %) | 17075 (83 %) | 17292 (84 %) |
| CLS | 9002 / 10368 (87 %) | 9886 (96 %) | 9877 (96 %) |
| BSRAM | 46 / 46 | 31 / 46 | 31 / 46 |
| DSP | 2 | 3.5 | 3.5 |
| Global clocks (PRIMARY) | 3 / 8 | 5 / 8 | 5 / 8 |
| rPLL | 2 / 2 | 2 / 2 (no new PLL) | 2 / 2 |
| Setup / hold violated endpoints | 0 / 0 | **0 / 0** | **0 / 0** |
| main_clk (108 MHz) worst setup slack | +0.065 ns | +0.22 ns | +1.51 ns |
| PCM engine clock (36 MHz) Fmax | — | 47.8 MHz | 42.6 MHz |

The tightest path is still New Juice's own: from the bus snapshot
(`mp_debouncer`) through the slot decode to the SDRAM request of the memory
clients. Its slack moves by about 1 ns from build to build; the last commit
before the docs takes the start decision off the enables of the request
registers, which is what made both tool versions close. With the chip at
96 % CLS, expect to check the timing report after any change.

## Simulation

See `tools/sim/README.md`.

Results on this branch (WSL Ubuntu-24.04, Icarus 12, sv2v):

| Bench | Result |
|---|---|
| Arbiter with the real chain, Z80 at 3.58 / 5.37 / 7.16 MHz, 24 voices (`blocks/run_blocks.sh arb`, 12 runs) | 12/12 PASS: no CPU command lost, no wrong data on either side. CPU read `cmd_en`->ack 93 ns without the MoonSound; with it at most 102 ns (3.58 MHz) and 139 ns (5.37 / 7.16 MHz); without the CPU-read hint it was 167-176 ns. PCM output rate 1.000 in all normal cases; 0.71-0.72 with 24 voices of 16-bit samples at high pitch |
| Refresh with the Z80 stopped 70 ms (`refresh`) | PASS: one refresh every 7.8 us, no decayed row; negative control (own refresh off) PASS: the model reports 6838 decayed rows |
| Memory map (`map`) | 15/15 PASS |
| New Juice's OPLL without sv2v (`opll`) | PASS (+-4085) |
| Whole board (`board/run_board.sh`) | 65/65 PASS: boot with New Juice's start-up test and ROM copy through the arbiter, YRW801 copy (synthetic 4 KB) and checksum, FM status/register read-back/timer /INT, wave ID and memory through 7Eh/7Fh with /WAIT, wave RAM at SDRAM 0x700000, nothing above 1 MB, 2 MB mapper, Super-MegaRAM, Nextor ROM, LINEAR mode, OPLL writes, PCM and FM to the I2S amplifier at 48.2 kHz with both halves of every frame equal, YRW801 kept across an MSX /RESET, no illegal SDRAM command, no decayed row |
| Whole board, flash without YRW801 (`run_board.sh blank`) | 12/12 PASS: the checksum flags the image and the LED flashes |

## Known limits

- Not run on a board yet. Everything above comes from simulation and from
  the Gowin reports.
- Franky is gone: SMS games and the sound scope no longer work. The mapper is
  2 MB, not 4 MB. The wave RAM is 1 MB (the free SDRAM is 1.84 MB, not 2).
- New Juice serves the Z80 without /WAIT. In the board bench a mapper read
  has its data on the slot at most 236 ns after /MREQ, with or without 24
  MoonSound voices playing (the arbiter keeps wave fetches out of the way of
  a starting CPU read): 200/200 reads right at 3.58 MHz (needed by 459 ns)
  and at 5.37 MHz (needed by 282 ns, 47 ns to spare); at 7.16 MHz (needed by
  199 ns) about half fail, 99/200 without the MoonSound and 97/200 with it:
  New Juice does not reach a 7.16 MHz Z80 without /WAIT by itself.
- IN 7Fh holds the Z80 with /WAIT. /WAIT reaches the slot about 194 ns after
  /IORQ: in time at 3.58 MHz, too late for a Z80 at 5.37 MHz or above
  (MoonTANG behaves the same on the WonderTANG). A turbo machine could read
  a stale byte from 7Fh; `RD_MIRROR = 1` in `moonsound_nj.sv` would serve
  the two registers that software reads from the bus side instead.
- With 24 voices of 16-bit samples at high pitch the wavetable engine keeps
  up at about 72 % of its rate (MoonTANG: 80 %); ordinary music runs at
  100 %.
- The OPL4 joins the mix at the level of the OPLL; the balance against the
  other New Juice sources has to be set by ear on real hardware.
- HDMI is not exercised by the board bench (its PLL is held in reset there).
- Unchanged New Juice behaviour, seen in the bench: with the MSX off (all
  slot lines at 0) New Juice holds /WAIT and turns the data transceiver
  towards the slot, although it drives nothing.
