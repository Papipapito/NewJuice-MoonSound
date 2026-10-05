# NewJuice-MoonSound

New Juice for the WonderTANG 2.0b / 2.02b with a **MoonSound** (Yamaha
YMF278B / OPL4: OPL3 FM plus the 24-voice wavetable) in place of **Franky**.

- New Juice is the work of **lfantoniosi**
  (<https://github.com/lfantoniosi/new-juice>). This fork starts at its commit
  `306ca0e` (24 Aug 2026).
- The MoonSound comes from **MoonTANG** (Albert "Papipapito", with Claude),
  commit `5400f15`, which in turn builds on the open cores listed under
  [Licenses](#licenses).
- Branches: `master` is New Juice exactly as upstream; all the work is on
  `moonsound`.

## Status

Experimental. **It has not run on a board yet.** It builds without timing
violations with Gowin 1.9.12.03 and 1.9.11.03 Education, and every simulation
bench passes (`tools/sim/README.md`; results in [MOONSOUND.md](MOONSOUND.md)).
Next step: the board test on a WonderTANG 2.02b (MoonBlaster / MBWave and
their wave RAM detection, Nextor and the microSD, SCC, OPLL, SFG-01, the
debugger, HDMI) and setting the OPL4 level in the mix by ear.

## Why this repository is private

New Juice has no license, so all its rights stay with its author and a fork
of it cannot be published without his permission. This repository is
therefore private and nothing built from it is distributed. Once the fork
works on a board, lfantoniosi will be told about it, and he decides:

- to take the MoonSound into New Juice, whole or in part; or
- to give a license, or a permission, under which this fork can be published;
- or neither, and then it stays private.

Whatever the outcome, the fork will always be open source and free of
charge. The message to him is drafted in
[docs/message_to_lfantoniosi.md](docs/message_to_lfantoniosi.md) and has not
been sent.

## What changes for the user

| | New Juice | This fork |
|---|---|---|
| MoonSound FM (ports C4h-C7h) | — | **yes**, OPL3, stereo |
| MoonSound wavetable (ports 7Eh-7Fh) | — | **yes**, 24 voices, YRW801 + 1 MB wave RAM, F8h/F9h mix registers |
| Franky: SMS VDP and SN76489 (ports 48h/49h, 88h/89h) | yes | **removed** |
| Sound scope on HDMI | yes | **removed** (it drew into Franky's framebuffer) |
| Memory mapper | 4 MB | **2 MB** |
| Nextor + microSD, Super-MegaRAM SCC, PSG, OPLL, SFG-01 (OPM), Z80 debugger with its HDMI terminal | yes | yes, unchanged |
| Audio to the MSX (I2S amplifier of the Tang Nano 20K, mono) | about 22 kHz | **48.2 kHz**, mix saturates instead of wrapping around |
| Audio on HDMI | mono, 44.1 kHz | **stereo**, 44.1 kHz |

### What is lost

- **Franky**: SMS games and anything else that uses its VDP or its SN76489.
- **The sound scope** on HDMI. The debugger terminal on HDMI stays.
- **Half of the mapper**: 2 MB (128 pages) instead of 4 MB. Pages 80h-FFh
  mirror 00h-7Fh, and IN FCh-FFh reads bit 7 as 1, like a real 2 MB
  mapper.

To go back to New Juice, write its own bitstream at flash 0x000000. Its ROMs
stay where they were, and the YRW801 at 0x200000 does not bother it.

## Changes against New Juice

`git diff master..moonsound` shows all of them. They are split into small
commits so that each one can be read on its own; New Juice's code is not
reformatted.

| Commit | What it does |
|---|---|
| `676457f` | Remove Franky (SMS VDP, SN76489, framebuffer) and the sound scope |
| `d268ba8` | Memory map: shrink the memory mapper to 2 MB |
| `cdb3d09` | Add the MoonSound (OPL4) sources from MoonTANG `5400f15` (`src/moonsound/`) |
| `8ebe679` | SDRAM: arbiter in front of the controller, with its own refresh timer |
| `b21e61c` | MoonSound: hook the OPL4 to the bus, the flash, the SDRAM and the clocks |
| `d48c9a4` | Audio: mix the OPL4 with saturation, I2S at 48.2 kHz, stereo HDMI |
| `fb323e5` | SDC: keep the HDMI serializer reset untimed after the Franky removal |
| `58636d1` | Timing: load the SDRAM request registers while idle, off the start decision |
| `1637932` | Documentation, `make yrw801` target and simulation benches (`tools/sim/`) |
| `c02d2a4` | Memory map: read the mapper registers back with bit 7 set |
| `b0045c0` | MoonSound: release the bus when /RD or /IORQ go up, like New Juice's ports |
| `5d6fcce` | Audio: I2S framing and mid-bit BCLK for the MAX98357A |
| `4f88f85` | Audio: send the whole saturated mix to the amplifier |
| `63eb5be` | Board bench: measure the bus release from the design's own /RD |
| `bb90bcc` | Docs: I2S framing, mapper read-back, place-and-route options, bench results |
| `16a9664` | Build: route option 2, from a place-and-route sweep with both tool versions |

New Juice files touched: `src/top.v`, `src/top.sdc`, `new-juice.gprj`,
`src/rpll/rpll_main.v` (CLKOUTD3 brought out), `src/sdram_mapper.v`,
`src/flash_roms.v`, `src/linear_rom.v`, `src/super_megaram.v`,
`src/audio_drive.v`, `Makefile` (new `yrw801` target),
`impl/new-juice_process_config.json` (Route option 2), `.gitignore` and a
three-line notice at the top of `README.md`. New: `src/moonsound/`,
`tools/sim/`, `MOONSOUND.md`, this file and `docs/`.

Some of these changes are useful to New Juice even without the MoonSound:
the I2S framing (`5d6fcce`), the saturating mix (`d48c9a4`, `4f88f85`) and the
timing change of the memory clients (`58636d1`). How the MoonSound is built
in, and why, is explained in [MOONSOUND.md](MOONSOUND.md).

## Memory maps

SPI flash (8 MB). Only the YRW801 area is new:

| Range | Contents |
|---|---|
| 0x000000-0x0DD899 | bitstream (907 418 bytes) |
| 0x100000-0x11FFFF | Nextor (New Juice, unchanged) |
| 0x120000-0x123FFF | FM-PAC BIOS (unchanged) |
| 0x124000-0x127FFF | SFG-01 BIOS (unchanged) |
| **0x200000-0x3FFFFF** | **YRW801 wave ROM, 2 MB, written by the user** |

SDRAM (8 MB):

| Range | Contents |
|---|---|
| 0x000000-0x1FFFFF | memory mapper, 2 MB (was 4 MB) |
| 0x200000-0x3FFFFF | YRW801 copy (MoonSound wave addresses 0x000000-0x1FFFFF), read-only for the MSX |
| 0x400000-0x5FFFFF | Super-MegaRAM (unchanged) |
| 0x600000-0x627FFF | ROM copies (unchanged) |
| 0x700000-0x7FFFFF | MoonSound wave RAM, 1 MB (wave addresses 0x200000-0x2FFFFF) |

Wave addresses 0x300000-0x3FFFFF have no memory behind them: reads return
FFh and writes are ignored, with no mirror, so a wave RAM size detection
finds 1 MB, the standard size (checked in simulation; MoonBlaster and MBWave
themselves are part of the board test). The free SDRAM is 1.84 MB, not
enough for the 2 MB option.

## Clocks

No new PLL: the MoonSound takes two more outputs of New Juice's main PLL,
`rpll_main`, which are phase-related to main_clk and timed together with it.

| Clock | Source | Frequency | Used by |
|---|---|---|---|
| clkin | board oscillator | 27 MHz | OPLL and OPM (with a 3.58 MHz clock enable), HDMI pixel clock (as in New Juice) |
| main_clk | rpll_main CLKOUT | 108 MHz | bus, SDRAM, PSG, the rest of New Juice, the arbiter, the I2S output (108 MHz / 70 / 32 = 48.2 kHz) |
| opl4_clk54 | rpll_main CLKOUTD | 54 MHz | MoonSound bus side |
| opl4_clk_eng | rpll_main CLKOUTD3 | 36 MHz | PCM engine (clock enable 588/625: 33.8688 MHz on average) and OPL3 FM (36 MHz / 727 = 49.52 kHz) |
| video_clk_135 | rpll_video | 135 MHz | HDMI serializer (as in New Juice) |
| cpu_clk | slot pin | 3.58 MHz | parts of New Juice's bus interface (as in New Juice) |

The OPL3 FM runs at 36 MHz instead of MoonTANG's 27 MHz: with 27 MHz made
by a CLKDIV, its crossing into the 54 MHz side failed hold (34 endpoints,
down to -3.0 ns), and this way it needs one global clock fewer. Its sample
rate and timers were retuned for 36 MHz (`src/moonsound/opl3/opl3_pkg.sv`).

## Resources and timing

GW2AR-LV18QN88C8/I7 (Tang Nano 20K).

| | New Juice (author's bitstream, Gowin 1.9.11) | This fork, 1.9.12.03 (bitstream for the board test) | This fork, 1.9.11.03 Education |
|---|---|---|---|
| Logic | 12546 / 20736 (61 %) | 17188 (83 %) | 17246 (83 %) |
| CLS | 9002 / 10368 (87 %) | 9907 (96 %) | 9825-9899 (95 %) |
| Registers (FF) | 8157 | 9523 | 9192 |
| BSRAM | 46 / 46 | 31 / 46 | 31 / 46 |
| DSP | 2 | 3.5 | 3.5 |
| PRIMARY / LW clocks | 3 / 8, 8 / 8 | 5 / 8, 8 / 8 | 5 / 8, 8 / 8 |
| rPLL | 2 / 2 | 2 / 2 | 2 / 2 |
| Worst setup slack (main_clk, 108 MHz) | +0.065 ns | **+0.779 ns** | +0.060 to +1.014 ns |

Timing was checked in 18 builds: both tool versions and every place-and-route
option Gowin accepts for this device (10 different implementations). All 18
have **0 setup and 0 hold violated endpoints**; the worst hold slack is
+0.074 ns. The project is set to Place option 1 / Route option 2, the best of
the sweep (+0.779 ns with 1.9.12.03, +0.578 ns with 1.9.11.03). In that build
the other clocks reach, against what they need: opl4_clk54 95.2 / 54 MHz, PCM
engine 41.5 / 36 MHz, clkin 53.9 / 27 MHz, cpu_clk 67.4 / 3.58 MHz. The
tightest paths are still New Juice's own (from `mp_debouncer` to the memory
clients). The full sweep is in [MOONSOUND.md](MOONSOUND.md).

The chip is full (96 % CLS), so slack moves by about 1 ns from build to
build. After any change, read "Numbers of Setup Violated Endpoints" and
"Numbers of Hold Violated Endpoints" in `impl/pnr/new-juice_tr_content.html`:
the summary of the IDE can show no TNS while a clock-domain crossing fails.

## Building and flashing

```
make init                                 # submodules (jt49, jt51, jtopl, Nextor)
make reprogram                            # the bitstream in the repository to flash 0x000000, no build
make                                      # Gowin gw_sh -> impl/pnr/new-juice.fs
make rebuild                              # always runs Gowin, even if nothing changed
make program                              # build if needed, then bitstream to flash 0x000000
make roms                                 # New Juice's Nextor and FM-PAC + SFG-01, as before
make yrw801 YRW801=/path/to/yrw801.rom    # your own YRW801 image to flash 0x200000
```

The repository carries a built bitstream, as New Juice does:
`impl/pnr/new-juice.fs` and `.bin` are this fork's bitstream for the board
test (Gowin 1.9.12.03, Place 1 / Route 2, sources of `bb90bcc` plus the route
option of `16a9664`; MD5 of the `.fs` `c2ef5122bdc7ca1033023a451b08b045`, of
the `.bin` `d7c70facd0137f651f9d25352f46c779`). `.gitattributes` keeps both
byte for byte, so a checkout gives exactly those checksums. The other files
under `impl/` (reports, synthesis netlist) are still New Juice's from
upstream until the next build overwrites them.

- `make reprogram` writes that file as it is, without building: only
  openFPGALoader is needed. This is what New Juice's README tells a new user
  to run, and in this fork it writes the MoonSound bitstream, not New Juice's.
- `make` and `make program` run Gowin only when a source file is newer than
  `impl/pnr/new-juice.fs` (after a clone the file dates decide), and they ask
  for the Gowin IDE even when nothing has to be built.
- `make rebuild` always runs Gowin and overwrites `impl/pnr/`, versioned
  bitstream included. A rebuild of the same sources gives a different `.fs`
  (its header carries the build time), and another Gowin version places and
  routes it differently, so check its timing (see above) before committing it.

`make` needs the Gowin IDE (`GOWIN_IDE=...` or `GW_SH=...`) and the
programming targets need openFPGALoader, as in New Juice. Without the
Makefile: write the bitstream with Gowin Programmer in *External Flash Mode*
or `openFPGALoader -b tangnano20k -f new-juice.fs`, and the YRW801 with
`openFPGALoader -b tangnano20k --external-flash -o 2097152 yrw801.rom`.

- Flash with the MSX off (or the WonderTANG out of the slot) and the Tang
  powered from USB. On a 2.0b the core uses the JTAG pins: hold **S1** while
  plugging the USB cable in, and during the whole programming, as the
  WonderTANG instructions say.
- After every flashing, check that the YRW801 is still there: some tools
  erase more than they write.
- If the YRW801 is missing, or 0x200000 holds something else, the FM works,
  the wavetable plays garbage and the LED gives a short flash every 1.2 s
  (it still shows SD activity, as before).
- At power-on New Juice copies its ROMs first, with the MSX held by /WAIT as
  before. Then the YRW801 is copied to the SDRAM in the background, about
  1.7 s, while the MSX runs; until then the wavetable is held in reset. The
  FM works at once.
- S1 restarts the whole board (ROMs and YRW801 are copied again); S2 is New
  Juice's debugger, as before.

### The YRW801

The MoonSound needs the Yamaha YRW801 wave ROM (2 MB). It is copyrighted by
Yamaha, so it is **not** in this repository and never goes into a release:
each user writes their own image to the flash at 0x200000 (`make yrw801`).
`roms/yrw801*` is in `.gitignore`. A checksum taken while it is copied tells
whether the image is a YRW801 (the LED warning above).

## Known limits

The details are in [MOONSOUND.md](MOONSOUND.md). In short:

- Not run on a board yet.
- IN 7Fh holds the Z80 with /WAIT, which reaches the slot about 194 ns after
  /IORQ: in time at 3.58 MHz, too late at 5.37 MHz or above, where a stale
  byte can be read (MoonTANG behaves the same). Register writes, which is
  what playing music mostly does, are not affected.
- New Juice serves the Z80 without /WAIT. In the board bench memory reads are
  right at 3.58 and 5.37 MHz with or without the MoonSound; at 7.16 MHz about
  half fail with or without it, so that limit is New Juice's own.
- The OPL4 joins the mix at the level of the OPLL; the balance has to be set
  by ear on the board.

## Licenses

New Juice is lfantoniosi's work and has **no license**: all rights are his.
Its submodules and third-party sources keep their own (jt49, jt51 and jtopl
by Jose Tejada: GPL-3.0; Nextor: `kernel/Nextor/LICENSE.md`; IKASCC: BSD-2).

The MoonSound (`src/moonsound/`, details and full texts in
[src/moonsound/NOTICE.md](src/moonsound/NOTICE.md)):

| Part | Files | Author | License |
|---|---|---|---|
| OPL3 FM core | `opl3/*.sv` | Greg Taylor (*opl3_fpga*), clock retune by Jokin Miragaia | LGPL-3.0 |
| FIFO of the OPL3 host interface | `opl3/afifo.v` | Dan Gisselquist | GPL-3.0 |
| YMF278B wavetable engine | `opl4wave/*` | srg320, from MAME's `ymf278b.cpp` (R. Belmont, O. Galibert, hap) | BSD-3-Clause |
| FM wrapper (ports C4h-C7h) | `opl4fm.v` | adapts `cartridge_opl3.sv` of Jokin Miragaia (MangOPL4); changes by Albert "Papipapito" with Claude | BSD-3-Clause + GPL-3.0 for the changes |
| SPI flash reader | `flash_rw.v` | derived from `flash.v` of lfantoniosi's WonderTANG (Copyright (c) 2023 lfantoniosi); changes by Albert "Papipapito" with Claude | BSD-2-Clause + GPL-3.0 for the changes |
| MoonTANG glue: PCM ports and wave cache, wave memory port, YRW801 loader | `opl4_pcm.v`, `wave_sdram.v`, `yrw801_loader.v` | Albert "Papipapito" with Claude | GPL-3.0 |
| New Juice glue: bus, clocks, flash hand-over, mix; SDRAM arbiter | `moonsound_nj.sv`, `nj_sdram_arb.v` | Albert "Papipapito" with Claude | GPL-3.0 |

Because `afifo.v` is GPL-3.0, `src/moonsound/` as a whole is GPL-3.0. The
simulation benches (`tools/sim/`) are by Albert "Papipapito" with Claude,
GPL-3.0 like the MoonTANG benches they come from. The YRW801 is not part of
any of this: the user supplies it.
