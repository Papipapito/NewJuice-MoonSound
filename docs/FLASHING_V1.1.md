# NewJuice-MoonSound v1.1 — flashing guide / guía de flasheo

> **Experimental hardware firmware.** This image has passed synthesis,
> place-and-route and simulation, but it has not been tried on a board yet
> (only an earlier build of this branch, X1, has booted on one).
> Flash it only if you accept the risk of having to recover the board. Do not
> interrupt power while the external flash is being written.

## English

**Upgrading from v1.0: only the FPGA configuration changes.** Write
`NewJuice-MoonSound-v1.1.fs` at `0x000000` (step 2 below) and leave the ROMs
and the YRW801 as they are.

v1.1 is for the **WonderTANG 2.0b / 2.02b** (Tang Nano 20K,
GW2AR-18). It replaces New Juice's Franky/SMS block with MoonSound: OPL3 FM
and OPL4 wavetable audio. The mapper is 2 MiB rather than 4 MiB.

Files: the v1.1 bitstream is `impl/pnr/new-juice.fs` in the repository (md5
`0bdb119e17487b38da281214b942aec1`; the `.bin`, `398a6472735ed769b44e93df92691943`),
called `NewJuice-MoonSound-v1.1.fs` / `.bin` below; the ROMs and `yrw801.bin`
are those of the v1.0 private release, unchanged:

| Asset | External-flash start address | Purpose |
| --- | ---: | --- |
| `NewJuice-MoonSound-v1.1.fs` | `0x000000` | FPGA configuration. This is the file to select in Gowin Programmer. |
| `Nextor-2.1.1.WonderTANG.ROM.bin` | `0x100000` | Nextor / microSD ROM. |
| `combined.bin` | `0x120000` | FM-PAC at `0x120000` plus SFG-01 at `0x124000`; keep these together. |
| `yrw801.bin` | `0x200000` | 2 MiB OPL4 wave ROM, supplied with the v1.0 private release by the repository owner. |
| `NewJuice-MoonSound-v1.1.bin` | — | Raw FPGA bitstream for tools that explicitly request a `.bin`; do not select it instead of the `.fs` in Gowin Programmer. |

### Gowin Programmer

1. Disconnect the WonderTANG from the MSX (or turn the MSX off). Power the
   board by USB. For a board that requires it, hold **S1** while connecting
   USB and during programming.
2. Add an **External Flash Mode** operation for `NewJuice-MoonSound-v1.1.fs`.
   Choose an erase/program/verify operation, select **Generic Flash**, and
   use start address **`0x000000`**.
3. Add a separate external-flash operation for
   `Nextor-2.1.1.WonderTANG.ROM.bin` at **`0x100000`**.
4. Add a separate external-flash operation for `combined.bin` at
   **`0x120000`**. Do not split it into two independent writes: the two ROMs
   share an erase sector.
5. Add a separate external-flash operation for `yrw801.bin` at
   **`0x200000`**.
6. Program and verify every operation. Then fully power-cycle the board
   before inserting it in the MSX.

Do **not** use **Bulk Erase** after the ROMs have been installed: it erases
the FPGA configuration, Nextor, FM-PAC/SFG-01 and the optional wave ROM.
Normal file-range erase/program/verify at the addresses above is the intended
operation.

### YRW801 wave ROM

The MoonSound wavetable uses the 2 MiB `yrw801.bin` image at
**`0x200000`–`0x3FFFFF`**. It is included in the v1.0 private release at the explicit
request and under the responsibility of the repository owner. Without it,
OPL3 FM and the rest of New Juice work, but OPL4 wavetable playback cannot be
used.

## Español

Esta versión es para **WonderTANG 2.0b / 2.02b** (Tang Nano 20K,
GW2AR-18). Sustituye el bloque Franky/SMS de New Juice por MoonSound: FM OPL3
y wavetable OPL4. El mapper pasa de 4 MiB a 2 MiB.

**Si vienes de la v1.0, solo cambia la configuración de la FPGA:** graba
`NewJuice-MoonSound-v1.1.fs` en `0x000000` (paso 2) y deja las ROMs y la YRW801
como están.

Archivos y direcciones: el bitstream de la v1.1 es `impl/pnr/new-juice.fs` del
repositorio (md5 `0bdb119e17487b38da281214b942aec1`; el `.bin`,
`398a6472735ed769b44e93df92691943`), que abajo se llama `NewJuice-MoonSound-v1.1.fs` /
`.bin`; las ROMs y `yrw801.bin` son las de la release privada v1.0, sin cambios:

| Archivo | Dirección inicial de flash externa | Uso |
| --- | ---: | --- |
| `NewJuice-MoonSound-v1.1.fs` | `0x000000` | Configuración FPGA. Es el fichero que se selecciona en Gowin Programmer. |
| `Nextor-2.1.1.WonderTANG.ROM.bin` | `0x100000` | ROM de Nextor / microSD. |
| `combined.bin` | `0x120000` | FM-PAC en `0x120000` y SFG-01 en `0x124000`; se graban juntos. |
| `yrw801.bin` | `0x200000` | ROM de ondas OPL4 de 2 MiB, aportada con la release privada v1.0 por el propietario del repositorio. |
| `NewJuice-MoonSound-v1.1.bin` | — | Bitstream FPGA en bruto para herramientas que pidan expresamente `.bin`; no sustituye al `.fs` en Gowin Programmer. |

### Gowin Programmer

1. Desconecta la WonderTANG del MSX (o apaga el MSX) y alimenta la placa por
   USB. Si tu placa lo requiere, mantén pulsado **S1** al conectar el USB y
   durante toda la programación.
2. Añade una operación en **External Flash Mode** para
   `NewJuice-MoonSound-v1.1.fs`. Selecciona borrar/programar/verificar,
   **Generic Flash** y la dirección inicial **`0x000000`**.
3. Añade otra operación para `Nextor-2.1.1.WonderTANG.ROM.bin` en
   **`0x100000`**.
4. Añade otra operación para `combined.bin` en **`0x120000`**. No dividas
   este fichero en dos escrituras independientes: ambas ROM comparten sector
   de borrado.
5. Añade otra operación para `yrw801.bin` en **`0x200000`**.
6. Programa y verifica todas las operaciones. Apaga y vuelve a encender por
   completo la placa antes de insertarla en el MSX.

No uses **Bulk Erase** después de instalar las ROM: borra la configuración
FPGA, Nextor, FM-PAC/SFG-01 y la ROM de ondas opcional. Usa únicamente las
operaciones de borrar/programar/verificar por rango de fichero en las
direcciones indicadas.

### ROM de ondas YRW801

El wavetable de MoonSound usa la imagen de 2 MiB `yrw801.bin` en
**`0x200000`–`0x3FFFFF`**. Se incluye en la release privada v1.0 por petición expresa y
bajo responsabilidad del propietario del repositorio. Sin ella funcionan el
FM OPL3 y el resto de New Juice, pero no se puede usar la reproducción
wavetable del OPL4.
