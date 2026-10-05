# MoonSound (OPL4) for New Juice: sources and licenses

This folder holds the MoonSound (Yamaha YMF278B / OPL4) used by the New Juice
MoonSound fork. Except for two license headers (noted below) and the New Juice
glue (`moonsound_nj.sv`, `nj_sdram_arb.v`), every file is a verbatim copy of
MoonTANG commit `5400f15` (05/10/2026). Per-file headers are authoritative;
keep them intact.

| Component | Files | Author / project | License |
|---|---|---|---|
| OPL3 FM core | `opl3/*.sv` | Greg Taylor (`gtaylormb`, *OPL3 FPGA*), clock retune by Jokin Miragaia (`antxiko`, *MangOPL4*); algorithm origins R. Cozendey, S. Ohrendorf, Nuke.YKT | LGPL-3.0-or-later (`COPYING.LGPL-3`, on top of `COPYING.GPL-3`) |
| Asynchronous FIFO of the FM host interface | `opl3/afifo.v` | Dan Gisselquist, Gisselquist Technology LLC | GPL-3.0 (`COPYING.GPL-3`) |
| PCM / wavetable engine | `opl4wave/ymf278b_gowin.v` | srg320 (*Arcade-PsikyoSH2_MiSTer*, `rtl/PSH2/YMF278B.sv`), derived from MAME `ymf278b.cpp` (R. Belmont, Olivier Galibert, hap); Gowin RAM rework by the MSXimus project | BSD-3-Clause |
| FM wrapper (ports C4h-C7h, register shadows, IRQ) | `opl4fm.v` | Albert "Papipapito" with Claude; adapts `cartridge_opl3.sv` of MangOPL4 / tnCartWonder, Copyright (c) 2026 Jokin Miragaia | BSD-3-Clause (original wrapper) + GPL-3.0 (changes) |
| PCM glue (ports 7Eh-7Fh, engine clocking, wave cache) | `opl4_pcm.v` | Albert "Papipapito" with Claude | GPL-3.0 |
| Wave memory port (engine + loader on one SDRAM port) | `wave_sdram.v` | Albert "Papipapito" with Claude | GPL-3.0 |
| YRW801 loader (flash to SDRAM, checksum) | `yrw801_loader.v` | Albert "Papipapito" with Claude | GPL-3.0 |
| SPI flash reader | `flash_rw.v` | derived from `fpga/src/flash.v` of lfantoniosi/WonderTANG, Copyright (c) 2023 lfantoniosi; MoonTANG changes by Albert "Papipapito" with Claude | BSD-2-Clause (original) + GPL-3.0 (changes) |
| New Juice glue: bus, clocks, flash hand-over, mix | `moonsound_nj.sv` | Albert "Papipapito" with Claude | GPL-3.0 |
| SDRAM arbiter with its own refresh timer | `nj_sdram_arb.v` | Albert "Papipapito" with Claude | GPL-3.0 |

Changes in this fork: license headers added to `flash_rw.v` (the BSD-2
notice of the WonderTANG `flash.v` it derives from) and `opl4fm.v` (the BSD-3
notice of the MangOPL4 wrapper it adapts), with the code below them unchanged;
and `opl3/opl3_pkg.sv` retuned from 27 to 36 MHz (CLK_FREQ, CLK_DIV_COUNT and
the two timer tick counts; marked in the file).

Because `afifo.v` (GPL-3.0) is part of the FM core, this folder as a whole is
GPL-3.0. The rest of New Juice is lfantoniosi's work and keeps his terms; this
fork stays private until he decides how it may be shared.

**Not included, never distributed:** the YRW801 wave ROM (2 MB, copyright
Yamaha). The user writes it to the SPI flash at 0x200000.

---

## BSD-3-Clause (YMF278B engine, MAME; MangOPL4 wrapper)

YMF278B engine: Copyright the MAME team (R. Belmont, Olivier Galibert, hap) and
contributors; srg320. MangOPL4 wrapper: Copyright (c) 2026, Jokin Miragaia.

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.
  3. Neither the name of the copyright holder nor the names of its contributors
     may be used to endorse or promote products derived from this software
     without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## BSD-2-Clause (`flash_rw.v`, from lfantoniosi/WonderTANG)

```
BSD 2-Clause License

Copyright (c) 2023, lfantoniosi
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
