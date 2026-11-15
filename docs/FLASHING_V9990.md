# NewJuice-V9990 v1.0 — flashing guide / guía de flasheo

> **Experimental hardware firmware.** It builds with no timing violations,
> passes the simulation benches and has been tested on a real MSX (MSX-DOS
> from the microSD and a V9990 game), but board testing is still limited.
> Do not interrupt power while the external flash is being written.

## English

This release is for the **WonderTANG 2.0b / 2.02b** (Tang Nano 20K,
GW2AR-18). It is New Juice with a **V9990 (GFX9000)** instead of MoonSound:
the V9990 is on I/O ports `60h-6Fh` and its picture comes out of the Tang's
HDMI connector (DVI, no audio over HDMI). It keeps Nextor from the microSD,
the Super-MegaRAM with SCC, FM-PAC and PSG, and the RAM mapper goes back to
4 MiB. MoonSound, SFG-01, the on-screen debugger and the VU meter are gone.

**MSX at 3.58 MHz only**: at higher CPU speeds memory reads can fail while
the V9990 is showing a picture.

| Asset | External-flash start address | Purpose |
| --- | ---: | --- |
| `NewJuice-V9990-v1.0.fs` | `0x000000` | FPGA configuration. This is the file to select in Gowin Programmer. |
| `Nextor-2.1.1.WonderTANG.ROM.bin` | `0x100000` | New Juice's Nextor / microSD ROM. |
| `16k_fm_opl.bin` | `0x120000` | FM-PAC ROM. |

A board that already runs New Juice or NewJuice-MoonSound only needs the
`.fs`: the ROMs are the same. **Do not use V9990TANG's Nextor pack**
(`v9990tang_nextor_pack_*.bin`): it is the MegaFlashROM SCC+ SD kernel and
stops with "Disk driver not found. System halted".

### Gowin Programmer

1. Disconnect the WonderTANG from the MSX (or turn the MSX off) and power the
   board by USB. For a board that requires it, hold **S1** while connecting
   USB and during programming.
2. Add an **External Flash Mode** operation for `NewJuice-V9990-v1.0.fs`:
   erase/program/verify, **Generic Flash**, start address **`0x000000`**.
3. If the board does not have New Juice's ROMs yet, add one operation for
   `Nextor-2.1.1.WonderTANG.ROM.bin` at **`0x100000`** and another for
   `16k_fm_opl.bin` at **`0x120000`**.
4. Program and verify, then fully power-cycle the board before inserting it
   in the MSX.

Do **not** use **Bulk Erase**: it also erases Nextor and the FM-PAC ROM.
To go back, flash the previous `.fs` the same way.

The Tang's RGB LED flickers with the MSX data bus (its pin is D3) and cannot
be turned off from the firmware; New Juice's README explains how to remove it.

## Español

Esta versión es para la **WonderTANG 2.0b / 2.02b** (Tang Nano 20K,
GW2AR-18). Es New Juice con un **V9990 (GFX9000)** en lugar de MoonSound: el
V9990 está en los puertos `60h-6Fh` y su imagen sale por el HDMI de la Tang
(DVI, sin audio por HDMI). Conserva Nextor desde la microSD, la
Super-MegaRAM con SCC, el FM-PAC y el PSG, y el mapper vuelve a tener 4 MiB.
Quedan fuera MoonSound, el SFG-01, el depurador en pantalla y el VU meter.

**Solo con el MSX a 3,58 MHz**: a más velocidad de CPU pueden fallar
lecturas de memoria mientras el V9990 muestra imagen.

| Archivo | Dirección inicial de flash externa | Uso |
| --- | ---: | --- |
| `NewJuice-V9990-v1.0.fs` | `0x000000` | Configuración FPGA. Es el fichero que se selecciona en Gowin Programmer. |
| `Nextor-2.1.1.WonderTANG.ROM.bin` | `0x100000` | ROM de Nextor / microSD de New Juice. |
| `16k_fm_opl.bin` | `0x120000` | ROM del FM-PAC. |

Una placa que ya lleva New Juice o NewJuice-MoonSound solo necesita el
`.fs`: las ROM son las mismas. **No uses el pack de Nextor de V9990TANG**
(`v9990tang_nextor_pack_*.bin`): es el kernel de la MegaFlashROM SCC+ SD y
se para con "Disk driver not found. System halted".

### Gowin Programmer

1. Desconecta la WonderTANG del MSX (o apaga el MSX) y alimenta la placa por
   USB. Si tu placa lo requiere, mantén pulsado **S1** al conectar el USB y
   durante toda la programación.
2. Añade una operación en **External Flash Mode** para
   `NewJuice-V9990-v1.0.fs`: borrar/programar/verificar, **Generic Flash**,
   dirección inicial **`0x000000`**.
3. Si la placa todavía no tiene las ROM de New Juice, añade una operación
   para `Nextor-2.1.1.WonderTANG.ROM.bin` en **`0x100000`** y otra para
   `16k_fm_opl.bin` en **`0x120000`**.
4. Programa y verifica, y apaga y enciende la placa por completo antes de
   insertarla en el MSX.

No uses **Bulk Erase**: borra también Nextor y la ROM del FM-PAC. Para volver
atrás se graba igual el `.fs` anterior.

El LED RGB de la Tang parpadea con el bus de datos del MSX (su pin es D3) y
no se puede apagar desde el firmware; el README de New Juice explica cómo
quitarlo.
