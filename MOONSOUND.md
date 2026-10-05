# New Juice + MoonSound (OPL4): technical notes

How the MoonSound is built into New Juice, the place-and-route sweep, the
simulation results and the known limits. What the fork is, its status, why it
is private, the memory maps, clocks, resources, how to flash it and the
licenses are in [FORK.md](FORK.md).

## How it is built in

- `src/moonsound/moonsound_nj.sv`: the MoonSound. The bus comes from New
  Juice's debounced signals; reads of C4h-C7h / 7Eh-7Fh join New Juice's data
  mux and /BUSDIR; IN 7Fh holds the Z80 with /WAIT until the engine answers
  (as in MoonTANG on the WonderTANG); the FM timers join /INT. The bus is only
  touched while the slot clock runs and /RESET is high.
- `src/moonsound/nj_sdram_arb.v`: an arbiter between New Juice's
  `sdram_command_adapter` and its `sdram.v`. New Juice is never refused a
  command: it waits at most one MoonSound operation. /SLTSL and /RD, taken
  straight from the pins, announce a CPU read some 8-13 clocks before New
  Juice issues it, and no new wave operation starts meanwhile (simulated: CPU
  read latency 93 ns without the MoonSound, at most 102-139 ns with it;
  167-176 ns without that hint). The arbiter also refreshes the SDRAM on its
  own every 7.8 us when nothing else did, because New Juice only refreshes
  after Z80 RFSH cycles and the wave ROM must survive a held /RESET or a /WAIT
  from another cartridge.
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
- I2S framing: New Juice's `audio_drive` changed WS together with the MSB,
  which is left-justified framing (MAX98357B). The Tang Nano 20K has a
  MAX98357A (I2S), which therefore read every word one bit late: twice the
  level, wrapping around above half scale. WS now changes one BCLK before the
  MSB and BCLK goes out inverted, so DIN/WS change on its falling edge (the
  108 MHz serializer otherwise gave 9.3 ns of hold, the amplifier needs 10).
  The amplifier now gets the whole mix saturated, which is the level the
  old framing produced (New Juice's sources were balanced by ear at it);
  HDMI keeps its own x2.

## Resources and timing

Resource usage is in [FORK.md](FORK.md#resources-and-timing). Timing was
measured on this branch with both tool versions and every place-and-route
option the tools accept for this device (Gowin silently turns Place 3 and 4
into Place 0 here, and Place 2 gives exactly the same placement as Place 1, so
the 18 builds below are 10 different implementations, 5 per tool version).

Worst setup slack (all in main_clk, 108 MHz) and violated endpoints:

| Place / Route | 1.9.12.03 | 1.9.11.03 Edu |
|---|---|---|
| 0 / 1 (also 3 / 1, 4 / 1) | +0.094 ns, 0 / 0 | +1.014 ns, 0 / 0 |
| 0 / 2 | +0.406 ns, 0 / 0 | +0.451 ns, 0 / 0 |
| 1 / 0 | +0.019 ns, 0 / 0 | +0.300 ns, 0 / 0 |
| 1 / 1 (also 2 / 1) | +0.202 ns, 0 / 0 | +0.060 ns, 0 / 0 |
| **1 / 2** (also 2 / 2), project setting | **+0.779 ns, 0 / 0** | +0.578 ns, 0 / 0 |

Every build closes: 0 setup and 0 hold violated endpoints, worst hold slack
+0.074 ns, no clock-domain crossing among the 25 worst setup paths. The
project uses `Place_Option = 1`, `Route_Option = 2`
(`impl/new-juice_process_config.json`), the best of the sweep with both
versions. With 1.9.12 P1/R2 the other clocks have, as Fmax against the
constraint: opl4_clk54 95.2 / 54 MHz, PCM engine (opl4_clk_eng) 41.5 / 36 MHz,
clkin (OPM, OPLL, HDMI pixels) 53.9 / 27 MHz, cpu_clk 67.4 / 3.58 MHz.

The tightest paths are still New Juice's own: from the bus snapshot
(`mp_debouncer`) through the slot decode to the SDRAM request of the memory
clients, or the SD register read-back. Their slack moves by up to 1 ns from
one place-and-route option to another; with the chip at 96 % CLS, expect to
check the timing report after any change. After every build read "Numbers
of Setup Violated Endpoints" and "Numbers of Hold Violated Endpoints" in the
timing report (`impl/pnr/new-juice_tr_content.html`): the summary table of
the IDE can show no TNS while a clock-domain crossing fails.

## Simulation

See `tools/sim/README.md`.

Results on this branch (WSL Ubuntu-24.04, Icarus 12, sv2v):

| Bench | Result |
|---|---|
| Arbiter with the real chain, Z80 at 3.58 / 5.37 / 7.16 MHz, 24 voices (`blocks/run_blocks.sh arb`, 12 runs) | 12/12 PASS: no CPU command lost, no wrong data on either side. CPU read `cmd_en`->ack 93 ns without the MoonSound; with it at most 102 ns (3.58 MHz) and 139 ns (5.37 / 7.16 MHz); without the CPU-read hint it was 167-176 ns. PCM output rate 1.000 in all normal cases; 0.71-0.72 with 24 voices of 16-bit samples at high pitch |
| Refresh with the Z80 stopped 70 ms (`refresh`) | PASS: one refresh every 7.8 us, no decayed row; negative control (own refresh off) PASS: the model reports 6838 decayed rows |
| Memory map (`map`) | 16/16 PASS (now also the read-back of FCh-FFh with bit 7 at 1) |
| I2S transmitter (`i2s`) | PASS: every word exact through an I2S receiver, both halves equal, a left-justified receiver does not decode it, DIN/WS 315 ns setup / 333 ns hold around the rising BCLK edge, 48.2 kHz. The previous `audio_drive` fails three of the four checks (8/64 words, 9.26 ns hold) |
| New Juice's OPLL without sv2v (`opll`) | PASS (+-4085) |
| Whole board (`board/run_board.sh`) | 68/68 PASS: boot with New Juice's start-up test and ROM copy through the arbiter, YRW801 copy (synthetic 4 KB) and checksum, FM status/register read-back/timer /INT, wave ID and memory through 7Eh/7Fh with /WAIT, wave RAM at SDRAM 0x700000, nothing above 1 MB, 2 MB mapper, Super-MegaRAM, Nextor ROM, LINEAR mode, OPLL writes, PCM and FM to the I2S amplifier at 48.2 kHz decoded as I2S with both halves of every frame equal and every word exactly the mix sample, the mono mix saturating at 7FFFh/8000h, the OPL4 releasing the bus at the same time as New Juice's own ports (10 ns after the design's /RD, both), YRW801 kept across an MSX /RESET, no illegal SDRAM command, no decayed row |
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
