# Message to lfantoniosi (draft, not sent)

> **Draft.** Albert sends it himself, by the channel he chooses, once the fork
> works on a board. Before sending:
>
> - fill in the two `[...]` with the board results;
> - keep the I2S point only if the board confirms it;
> - check the figures against [FORK.md](../FORK.md) and confirm the license
>   offer (it covers only our own files).

---

**Subject:** A MoonSound (OPL4) for New Juice, in place of Franky

Hi,

I'm Albert, Papipapito on GitHub. Thank you for the WonderTANG and for New
Juice.

I have put a MoonSound into New Juice for the WonderTANG 2.0b / 2.02b. It is
the OPL4 of MoonTANG, my MoonSound for the WonderTANG (written with Claude, as
the file headers say). It lives in a private fork of new-juice, starting at
your commit 306ca0e, and on my 2.02b [board test: what was tried and how it
went].

What it does:

- Franky is out (SMS VDP, SN76489, the framebuffer and the sound scope that
  drew into it): that is what makes room. The rest of New Juice stays as it
  is: Nextor and SD, Super-MegaRAM SCC, PSG, OPLL, SFG-01, the debugger and
  its HDMI terminal.
- MoonSound: FM at C4h-C7h and the wavetable at 7Eh-7Fh, stereo, with 1 MB of
  wave RAM. The user writes the YRW801 to the flash at 0x200000, and it is
  copied to the SDRAM in the background after your ROMs.
- The mapper goes from 4 MB to 2 MB to leave room in the SDRAM.
- A small arbiter sits in front of your sdram.v, with a refresh timer of its
  own: yours follows the Z80 RFSH cycles, and the wave ROM has to survive a
  held /RESET. Your commands are never refused; in simulation a CPU read goes
  from 93 ns to at most 139 ns.
- 83 % logic, 96 % CLS, 31 of 46 BSRAM. Timing closes in all 18 builds I
  tried (Gowin 1.9.12 and 1.9.11, every place-and-route option): no setup or
  hold violation, and +0.78 ns of worst setup slack at 108 MHz with the
  project's settings (as in New Juice, the SDRAM pins are not part of that;
  see below).

A few of the changes may be useful to New Juice even without the MoonSound.
Each one is a small commit of its own:

- I2S framing: `audio_drive` changes WS together with the MSB, which is
  left-justified. The MAX98357A of the Tang Nano 20K expects I2S, so it reads
  every word one bit late: twice the level, wrapping around above half scale
  [confirmed on the board: ...].
- The audio mix can overflow and wrap around; it now saturates.
- The tightest path (`mp_debouncer` to the SDRAM requests of the memory
  clients) had only a few tens of picoseconds to spare in some builds. The
  memory clients now load their request registers in every idle cycle, with
  the same values and in the same cycle as before.
- `top.sdc` leaves the SDRAM pins unconstrained (the SDRAM clock line is
  commented out), so Gowin never times that interface. Reads and commands
  sit in the I/O cells and have margin, but the write data cannot (each bit
  drives two pins) and lands wherever the placer puts it: measured from the
  SDF on New Juice's sources built with 1.9.12, -0.37 ns in the slow corner
  with typical SDR timing for the die. It boots, so it is unchecked margin,
  not a known bug. FORK.md has an SDC that times it and what it takes to
  close it.

It is your project, so it is your decision. Nothing has been published, and
the fork stays private unless you say otherwise. Any of these is fine with
me:

1. You take it into New Juice, all of it or only some parts. I can send it
   however suits you: a branch, a patch series or read access to the fork.
2. You give the fork a license, or your permission to publish it. It would
   always be open source and free, and it would say clearly that New Juice is
   yours.
3. Nothing. Then it stays private, and that is fine too.

About licenses: I can give you my own files (the New Juice glue, the SDRAM
arbiter, the PCM glue and the YRW801 loader) under whatever license you
choose for New Juice. The third-party parts keep theirs: Greg Taylor's OPL3
core is LGPL-3, srg320's YMF278B engine (from MAME) and Jokin Miragaia's FM
wrapper are BSD-3, and the flash reader comes from your own BSD-2 `flash.v`.
The only third-party GPL-3 piece is the FIFO of the OPL3 core (`afifo.v`),
and I can replace it if that is a problem.

FORK.md in the fork has the details: the changes, memory maps, timing,
licenses and simulation benches.

Thanks again,

Albert (Papipapito)
