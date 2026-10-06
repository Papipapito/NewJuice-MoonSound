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
- HDMI picture: when the debugger is off, a VU meter (`vu_screen.v` and
  `font8x8.v` from MoonTANG, `vu_meter_nj.v`) instead of the black picture
  left by the Franky removal; the debugger keeps priority. The meter takes
  the FM and wave halves of the OPL4 mix (54 MHz, taps of `moonsound_nj`)
  and the two samples HDMI plays (main_clk, through its input register), and
  changes its outputs once per frame in the vertical blanking; the screen
  draws from the HDMI coordinates at 27 MHz, with no framebuffer. See
  [FORK.md](FORK.md#the-vu-meter-on-hdmi).

## Resources and timing

Resource usage is in [FORK.md](FORK.md#resources-and-timing). Timing of the
sources before the VU meter (`16a9664`) was measured with both tool versions and every place-and-route
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
| **1 / 2** (also 2 / 2), the project setting then | **+0.779 ns, 0 / 0** | +0.578 ns, 0 / 0 |

Every build closes: 0 setup and 0 hold violated endpoints, worst hold slack
+0.074 ns, no clock-domain crossing among the 25 worst setup paths. That
covers only what the SDC constrains: the SDRAM pins are not constrained (as
in New Juice), so these reports say nothing about them; they were measured
apart from the SDF (see below). Those
sources were built with `Place_Option = 1`, `Route_Option = 2`
(`impl/new-juice_process_config.json`), the best of that sweep with both
versions; with the VU meter the project uses Place 0 / Route 1 (below).
With 1.9.12 P1/R2 the other clocks have, as Fmax against the
constraint: opl4_clk54 95.2 / 54 MHz, PCM engine (opl4_clk_eng) 41.5 / 36 MHz,
clkin (OPM, OPLL, HDMI pixels) 53.9 / 27 MHz, cpu_clk 67.4 / 3.58 MHz.

The table above is the sources of `16a9664`, before the VU meter. With the
meter, worst setup slack (main_clk) and violated setup / hold endpoints:

| Place / Route | X2 (`437b716`) | X3 (`aa2c2eb`) |
|---|---|---|
| 0 / 0 (also 3 / 0, 4 / 0) | -0.747 ns, **38** / 0 | -0.156 ns, **11** / 0 |
| **0 / 1** (also 3 / 1, 4 / 1), project setting (X3) | -0.343 ns, **15** / 0 | **+0.027 ns, 0 / 0** |
| 0 / 2 | +0.020 ns, 0 / 0 | +0.006 ns, 0 / 0 |
| 1 / 0 (also 2 / 0) | +0.017 ns, 0 / 0 | -0.098 ns, **8** / 0 |
| 1 / 1 (also 2 / 1) | +0.212 ns, 0 / 0 | +0.004 ns, 0 / 0 |
| 1 / 2 (also 2 / 2), X2's setting | +0.088 ns, 0 / 0 | +0.025 ns, 0 / 0 |
| 1.9.11.03 Education, 1 / 2 | +0.469 ns, 0 / 0 | +0.605 ns, 0 / 0 |

X3 is X2 with one more stage in the meter's frame-tick synchronizer; it is
the only variant tried that closes every Place 0-1 / Route 1-2 combination
and 1.9.11.03 (the others, and why this is placement luck and not a fix, are
in [FORK.md](FORK.md#resources-and-timing)). The project is now set to
Place 0 / Route 1 (+0.027 ns). Logic 86-88 %, CLS 97-98 %. In every build
the 25 worst setup paths are New Juice's own (`mp_debouncer` through the
slot decode to `flash_roms`, `linear_rom`, `super_megaram`, `sdram_mapper`
and the debugger, and the tone counters of `jt49`); none touches the meter,
its screen or HDMI. Worst hold slack +0.074 ns in all of them. With 1.9.12
P0 / R1 the other clocks reach: opl4_clk54 80.4 / 54 MHz, PCM engine 44.6 /
36 MHz, clkin 55.6 / 27 MHz, cpu_clk 55.9 / 3.58 MHz.

The tightest paths are still New Juice's own: from the bus snapshot
(`mp_debouncer`) through the slot decode to the SDRAM request of the memory
clients, or the SD register read-back. Their slack moves by up to 1 ns from
one place-and-route option to another; with the chip at 96 % CLS, expect to
check the timing report after any change. After every build read "Numbers
of Setup Violated Endpoints" and "Numbers of Hold Violated Endpoints" in the
timing report (`impl/pnr/new-juice_tr_content.html`): the summary table of
the IDE can show no TNS while a clock-domain crossing fails.

A register stage on all of New Juice's bus inputs (`24a99df`, build X4: the
`mp_debouncer` snapshot, the `input_debouncer` outputs, the fast /RD and /WR
and the synchronized CPU clock, each one 108 MHz clock later) was tried to
take those paths' first route out, and reverted (`2bbd313`). It did not cut
the paths, only moved their start to the new registers, which fan out to
15-25 clients across the chip; in the same six 1.9.12.03 builds the worst
slacks were +0.057, +0.060, +0.007, -0.328 (12 endpoints), -0.157 (3) and
+0.019 ns (X3: -0.156 (11), +0.027, +0.006, -0.098 (8), +0.004, +0.025),
and 1.9.11.03 Education +0.239 (X3 +0.605). It also cost one clock at the
slot: data of reads without /WAIT 9.3 ns later, the IN 7Fh /WAIT 18.5 ns
later (missed at 5.37 MHz), and an IN C4h status bit changing inside the
Z80's sample window (board bench FAIL). Signal table, figures and what
could work instead: [FORK.md](FORK.md#tried-and-reverted-a-register-stage-on-the-bus-inputs-x4).

## SDRAM interface timing

Measured on the eight builds tried on the board and on the two with the VU
meter (X2, X3), from their post-PnR SDF
(the method, the table and the proposed SDC are in
[FORK.md](FORK.md#the-sdram-interface)). In short:

- Read capture (`sdram_command_adapter` `read_data_reg`), command, BA and
  DQM are packed in the I/O cells in every build: setup +1.488 / hold
  +1.555 ns for reads, +2.866 ns for commands, the same in all builds, with
  the die timing assumed (tAC 6.0, tOH 2.5, tIS 1.5, tIH 1.0 ns, 0.2 ns of
  bond-wire mismatch).
- The write data and its output enable cannot go in the I/O cells
  (`dq_out` feeds two pins per bit) and move with the placement: from
  -1.624 to +0.626 ns in the slow corner. The arbiter's own capture of the
  pins (`wv_dout`, OPL4 wave reads only) is negative in every build, -0.98
  to -1.47 ns, slow corner. X3, with the VU meter: write data +0.548 ns,
  address +1.367, `wv_dout` -1.176 (X2: -0.777, +1.290, -1.467).
- None of these numbers separates the builds that boot from those that
  fail, so the SDRAM interface is not the cause of the MSXBOOK boot
  failures. The arbiter could still take a wrong wave word in a slow
  corner; the fix (per-pin write and output-enable registers, I/O-cell
  capture, one clock more of read latency) is described in FORK.md and not
  applied.

## Simulation

See `tools/sim/README.md`.

Results on this branch (WSL Ubuntu-24.04, Icarus 12, sv2v):

| Bench | Result |
|---|---|
| Arbiter with the real chain, Z80 at 3.58 / 5.37 / 7.16 MHz, 24 voices (`blocks/run_blocks.sh arb`, 12 runs) | 12/12 PASS: no CPU command lost, no wrong data on either side. CPU read `cmd_en`->ack 93 ns without the MoonSound; with it at most 102 ns (3.58 MHz) and 139 ns (5.37 / 7.16 MHz); without the CPU-read hint it was 167-176 ns. PCM output rate 1.000 in all normal cases; 0.71-0.72 with 24 voices of 16-bit samples at high pitch |
| Refresh with the Z80 stopped 70 ms (`refresh`) | PASS: one refresh every 7.8 us, no decayed row; negative control (own refresh off) PASS: the model reports 6838 decayed rows |
| Memory map (`map`) | 16/16 PASS (also the read-back of FCh-FFh: the register as written) |
| I2S transmitter (`i2s`) | PASS: every word exact through an I2S receiver, both halves equal, a left-justified receiver does not decode it, DIN/WS 315 ns setup / 333 ns hold around the rising BCLK edge, 48.2 kHz. The previous `audio_drive` fails three of the four checks (8/64 words, 9.26 ns hold) |
| New Juice's OPLL without sv2v (`opll`) | PASS (+-4085) |
| Whole board (`board/run_board.sh`) | 76/76 PASS: boot with New Juice's start-up test and ROM copy through the arbiter, YRW801 copy (synthetic 4 KB) and checksum, FM status/register read-back/timer /INT, wave ID and memory through 7Eh/7Fh with /WAIT, wave RAM at SDRAM 0x700000, nothing above 1 MB, 2 MB mapper, Super-MegaRAM, Nextor ROM, LINEAR mode, OPLL writes, PCM and FM to the I2S amplifier at 48.2 kHz decoded as I2S with both halves of every frame equal and every word exactly the mix sample, the mono mix saturating at 7FFFh/8000h, the OPL4 releasing the bus at the same time as New Juice's own ports (10 ns after the design's /RD, both), YRW801 kept across an MSX /RESET, no illegal SDRAM command, no decayed row; section O: bus timing at the slot pins with the Z80's timing at 3.58 / 5.37 / 7.16 MHz (checked at 3.58 MHz, measured at the others, figures under Known limits) |
| Whole board against another revision (`run_board.sh diff`, REF = a git revision, default `4730f9c`) | 2/2 PASS on `2bbd313` against X3 (`4730f9c`): 1941 bus cycles each, every byte, wait state and bus event (DATADIR, /BUSDIR, data at the slot, /WAIT) at the same time, shift 0.0 ns. Against X4 (`cd044ab`) it reported the IN 7Fh wait states lost at 5.37 MHz and every event one or two 108 MHz clocks later |
| Whole board, flash without YRW801 (`run_board.sh blank`) | 12/12 PASS: the checksum flags the image and the LED flashes |
| Whole board with HDMI (`run_board.sh hdmi`, three simulations, about 36 minutes) | 5/5 PASS (32/32 checks): New Juice starts the video PLL after the MSX /RESET; through the verification receiver, 1036800 of 1036800 pixels are the ones sent; the two VU frames are, pixel for pixel, `vu_check.py`'s picture (FM 17/0, wave 16/24 with the wave panned 12 dB down on the left, out 20/24 segments), and the levels and peak marks drawn are the ones an independent model of the meter gives from each bar's own source, in both frames; with the FM muted near the end of the first frame, the model and the meter agree in the second that the FM L bar goes down to 16 and OUT L to 19 with their peak marks held at 17 and 20 (on the screen the two frames are the same picture: each bar's top segment is under its own peak mark); the debugger frame is its terminal, pixel for pixel (10318 white pixels, nothing of the meter); 2880 audio samples equal to the transmitted ones, left and right apart; 720x480p geometry, ACR (N 6272, CTS 29988), channel status (44.1 kHz, 16 bits), AVI (VIC 2), Audio InfoFrame, no protocol error. Negative controls: the FM R bar fed from wave R, and the wave L and wave R bars swapped, each fail on the meter check alone; `vu_check.py` rejects a level one segment off |
| VU meter (`vu/run_vu.sh`) | 13/13 PASS: `vu_meter_nj` gives MoonTANG's `vu_meter` levels and peak marks in 1400 of 1400 random frames, with the reference's frame toggle one clock late for the fork's extra synchronizer stage (and a HOLD 44 mutant fails); the screen with the fork's texts, through `hdmi.sv`, is pixel for pixel `vu_check.py`'s picture (and a level one segment off is rejected), with YRW801 OK and MSX OK and also with YRW801 `...`, `ERROR`, `NO VALIDA` and MSX `--`. With `VG=` the X3 netlist: its three block-RAM ROMs hold what the simulation holds (512 + 128 + 512 entries, and a flipped bit is caught); with `GL=` a 1.9.12.03 synthesis netlist of the screen alone (`vu/syn/run_syn.sh`) draws the same frame, pixel for pixel (and with no netlist both netlist checks fail) |

## Known limits

- On the board only the boot has been tried, on one MSXBOOK: the versioned
  bitstream (X1, sources of `f3e4a2c`) boots, the build of `16a9664` does
  not; X3, with the VU meter, has not been tried; see
  [FORK.md](FORK.md#board-results). Everything else above comes from
  simulation and from the Gowin reports.
- Franky is gone: SMS games and the sound scope no longer work. The mapper is
  2 MB, not 4 MB. The wave RAM is 1 MB (the free SDRAM is 1.84 MB, not 2).
- New Juice serves the Z80 without /WAIT. In the board bench a mapper read
  has its data settled on the slot pins 226 ns after /MREQ (236 ns counting
  8 ns of board delay), with or without 24
  MoonSound voices playing (the arbiter keeps wave fetches out of the way of
  a starting CPU read): 200/200 reads right at 3.58 MHz (needed by 459 ns)
  and at 5.37 MHz (needed by 282 ns, 47 ns to spare); at 7.16 MHz (needed by
  199 ns) about half fail, 99/200 without the MoonSound and 97/200 with it:
  New Juice does not reach a 7.16 MHz Z80 without /WAIT by itself.
- IN 7Fh holds the Z80 with /WAIT. /WAIT reaches the slot at most 190.0 ns
  after /IORQ at 3.58 MHz (sampled at 349 ns: 89 ns to spare with the Z80's
  70 ns setup), 201.9 ns at 5.37 MHz (sampled at 219.4 ns) and 204.1 ns at
  7.16 MHz (sampled at 159.5 ns): in time at 3.58 MHz, too late for a Z80 at
  5.37 MHz or above
  (MoonTANG behaves the same on the WonderTANG). A turbo machine could read
  a stale byte from 7Fh; `RD_MIRROR = 1` in `moonsound_nj.sv` would serve
  the two registers that software reads from the bus side instead.
- With 24 voices of 16-bit samples at high pitch the wavetable engine keeps
  up at about 72 % of its rate (MoonTANG: 80 %); ordinary music runs at
  100 %.
- The OPL4 joins the mix at the level of the OPLL; the balance against the
  other New Juice sources has to be set by ear on real hardware.
- HDMI drops with every MSX /RESET and is off with the MSX off: New Juice
  resets its video PLL and the transmitter with the MSX (unchanged). The VU
  meter has been simulated with the whole design and an HDMI receiver, not
  seen on a screen yet.
- The build with the VU meter (X3) closes timing by 4 to 27 ps with
  1.9.12.03; any rebuild has to be checked.
- Unchanged New Juice behaviour, seen in the bench at the slot pins: the
  debugger's /WAIT on a held M1 fetch comes 13.4 / 55.1 / 65.4 ns after
  /MREQ at 3.58 / 5.37 / 7.16 MHz (126 ns, 1 ns and -46 ns to spare with
  70 ns of setup); SCC wave RAM reads, 2 of 16 wrong at 7.16 MHz with the
  slot clock equal to the CPU clock, none at 3.58 and 5.37 MHz.
- Unchanged New Juice behaviour, seen in the bench: with the MSX off (all
  slot lines at 0) New Juice holds /WAIT and turns the data transceiver
  towards the slot, although it drives nothing.
